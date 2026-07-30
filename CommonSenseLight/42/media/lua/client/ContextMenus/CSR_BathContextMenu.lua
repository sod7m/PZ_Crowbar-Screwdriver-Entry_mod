--[[
    CSR_BathContextMenu
    --------------------
    Adds the "Take A Bath" context menu option on filled bathtubs. Sandbox-
    gated by EnableBathing. Walks the player adjacent, queues clothing
    removal per sandbox toggles, then queues CSR_BatheAction and a final
    CSR_DryOffAction (if a BathTowel is in inventory).
]]

require "TimedActions/CSR_BatheAction"
require "TimedActions/CSR_BathClothingAction"
require "TimedActions/CSR_DryOffAction"
require "TimedActions/CSR_FillTubAction"
require "TimedActions/CSR_EmptyTubAction"
require "CSR_BathWater"
require "CSR_BathClothingPlan"

local function sandbox()
    return (SandboxVars and SandboxVars.CommonSenseLight) or {}
end

local function isBathingEnabled()
    if CSR_FeatureFlags and CSR_FeatureFlags.isBathingEnabled then
        return CSR_FeatureFlags.isBathingEnabled()
    end
    return sandbox().EnableBathing ~= false
end

local function textOr(key, fallback)
    if getTextOrNull then
        local value = getTextOrNull(key)
        if value then return value end
    end
    if getText then
        local value = getText(key)
        if value and value ~= key then return value end
    end
    return fallback
end

-- Sprite -> orientation key mapping.
local SPRITE_TO_PART = {
    -- Side-style tubs (player stands beside, head-in)
    bathroom_01_25 = "Part1", bathroom_01_53 = "Part1",
    bathroom_01_24 = "Part2", bathroom_01_52 = "Part2",
    bathroom_01_26 = "Part3", bathroom_01_54 = "Part3",
    bathroom_01_27 = "Part4", bathroom_01_55 = "Part4",
    -- Lying-style tubs (player lies inside)
    bathroom_01_23 = "Part5",
    bathroom_01_33 = "Part6", bathroom_01_31 = "Part6",
    bathroom_01_22 = "Part7",
    bathroom_01_32 = "Part8", bathroom_01_30 = "Part8",
}

local function getTubPart(sprite)
    if not sprite then return nil end
    for spritePrefix, part in pairs(SPRITE_TO_PART) do
        if string.find(sprite, spritePrefix, 1, true) then
            return part
        end
    end
    return nil
end

-- Body-location category sets. Used to decide which worn items to skip
-- per the BathingTakeOff* sandbox toggles -- everything *not* in a skipped
-- category is unequipped before the bath.
local HEADWEAR_SET = {
    MaskFull=true, Hat=true, FullHat=true, Ears=true, EarTop=true, Nose=true,
    Eyes=true, LeftEye=true, RightEye=true, MaskEyes=true, Mask=true,
}
local UNDERWEAR_SET = {
    Underwear=true, UnderwearBottom=true, UnderwearTop=true,
    UnderwearExtra1=true, UnderwearExtra2=true,
}
local BACKPACK_SET = {
    Back=true, FannyPackFront=true, FannyPackBack=true, Webbing=true,
}

-- Walk getWornItems() once and return every worn InventoryItem the player
-- should unequip before bathing. Source-mod parity: defaults to stripping
-- everything; sandbox toggles let users keep headwear / underwear /
-- backpacks on.  Previous implementation filtered by a positive location
-- list which silently skipped any body slot not enumerated (ShortPants,
-- LongDress, Calf_*, Thigh_*, etc.).
local function collectWornForBath(player, sb)
    local out = {}
    if not player or not player.getWornItems then return out end
    local worn = player:getWornItems()
    if not worn or not worn.size then return out end

    local skipHeadwear  = sb.BathingTakeOffHeadwear  == false
    local skipClothes   = sb.BathingTakeOffClothes   == false
    local skipUnderwear = sb.BathingTakeOffUnderwear ~= true  -- default OFF (keep on)
    local skipBackpack  = sb.BathingTakeOffBackpack  == false

    for i = 0, worn:size() - 1 do
        local entry = worn:get(i)
        local item = entry and entry.getItem and entry:getItem() or nil
        if item then
            local loc = item.getBodyLocation and item:getBodyLocation() or nil
            if (not loc) and entry and entry.getLocation then
                local l = entry:getLocation()
                if l then loc = tostring(l) end
            end
            local locStr = type(loc) == "string" and loc or (loc and tostring(loc) or "")

            local skip = false
            if skipHeadwear  and HEADWEAR_SET[locStr]  then skip = true end
            if skipUnderwear and UNDERWEAR_SET[locStr] then skip = true end
            if skipBackpack  and BACKPACK_SET[locStr]  then skip = true end
            if skipClothes
               and not HEADWEAR_SET[locStr]
               and not UNDERWEAR_SET[locStr]
               and not BACKPACK_SET[locStr] then
                skip = true
            end

            if not skip then
                out[#out + 1] = item
            end
        end
    end
    return out
end

local TOWEL_TYPES = { "BathTowel", "DishCloth" }

local function getTowelAmount(item)
    if not item then return 0 end
    if item.getCurrentUsesFloat then
        local amount = item:getCurrentUsesFloat()
        if amount and amount > 0 then return amount end
    end
    if item.getUsedDelta then
        local amount = item:getUsedDelta()
        if amount and amount > 0 then return amount end
    end
    if item.getDelta then
        local amount = item:getDelta()
        if amount and amount > 0 then return amount end
    end
    return 0
end

local function findTowel(player)
    local inv = player:getInventory()
    for i = 1, #TOWEL_TYPES do
        local items = inv:getAllTypeRecurse(TOWEL_TYPES[i])
        if items and items:size() > 0 then
            for j = 0, items:size() - 1 do
                local it = items:get(j)
                if getTowelAmount(it) > 0 then return it end
            end
        end
    end
    return nil
end

local function startBath(tub, consumeWater, player)
    if not tub or not tub:getSquare() then return end
    if not luautils.walkAdj(player, tub:getSquare()) then return end

    local sb = sandbox()
    local takenOff = {}
    local worn = collectWornForBath(player, sb)
    local mpClothingPlan = ""
    if isClient and isClient() then
        mpClothingPlan = CSR_BathClothingPlan.encode(worn)
        if mpClothingPlan ~= "" then
            ISTimedActionQueue.add(CSR_BathClothingAction:new(player, "undress", tub, mpClothingPlan, 35))
        end
    else
        for i = 1, #worn do
            local cloth = worn[i]
            ISTimedActionQueue.add(ISUnequipAction:new(player, cloth, 50))
            takenOff[#takenOff + 1] = cloth
        end
    end

    local part = getTubPart(tub:getSprite() and tub:getSprite():getName())
    if not part then return end
    ISTimedActionQueue.add(CSR_BatheAction:new(player, tub, part, consumeWater))

    local towel = findTowel(player)
    if towel then
        ISTimedActionQueue.add(CSR_DryOffAction:new(player, towel, 110, takenOff, true))
        if mpClothingPlan ~= "" then
            ISTimedActionQueue.add(CSR_BathClothingAction:new(player, "redress", tub, mpClothingPlan, 35))
        end
    elseif mpClothingPlan ~= "" then
        ISTimedActionQueue.add(CSR_BathClothingAction:new(player, "redress", tub, mpClothingPlan, 35))
    elseif #takenOff > 0 then
        for i = 1, #takenOff do
            ISTimedActionQueue.add(ISWearClothing:new(player, takenOff[i], 50))
        end
    end
end

-- Fill Tub from plumbing. Gated on the tub's square having an active
-- water source (or, defensively, the player's current square -- some
-- bathrooms register water on the room rather than the tile).
local function squareHasRunningWater(sq)
    if not sq then return false end
    if sq.getRoom and sq:getRoom() and sq:getRoom().def then
        -- B42: Room.def is a RoomDef; piped buildings set isHydroPowered.
        if sq:getRoom().isHydroPowered then
            local ok, on = pcall(function() return sq:getRoom():isHydroPowered() end)
            if ok and on then return true end
        end
    end
    -- Building-level fallback: vanilla helper used by sinks.
    if SandboxVars and SandboxVars.WaterShutModifier then
        -- Simple proxy: the world hasn't past the shut-off day yet.
        local gt = GameTime and GameTime.getInstance and GameTime.getInstance() or nil
        local day = gt and gt.getNightsSurvived and gt:getNightsSurvived() or 0
        local shut = tonumber(SandboxVars.WaterShutModifier) or 14
        if day < shut then return true end
    end
    return false
end

local function startFillTub(tub, player)
    if not tub or not tub:getSquare() then return end
    if not luautils.walkAdj(player, tub:getSquare()) then return end
    ISTimedActionQueue.add(CSR_FillTubAction:new(player, tub))
end

local function startEmptyTub(tub, player)
    if not tub or not tub:getSquare() then return end
    if not luautils.walkAdj(player, tub:getSquare()) then return end
    ISTimedActionQueue.add(CSR_EmptyTubAction:new(player, tub))
end

local function onFillContextMenu(playerNum, context, worldobjects, test)
    if not isBathingEnabled() then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local tub
    for _, obj in ipairs(worldobjects) do
        local spr = obj.getSprite and obj:getSprite()
        local sprName = spr and spr.getName and spr:getName()
        if sprName and getTubPart(sprName) then
            tub = obj
            break
        end
    end
    if not tub then return end

    local sb = sandbox()
    local consumeWater = tonumber(sb.BathingWaterCost) or 40

    local opt = context:addOption(getText("ContextMenu_CSR_TakeABath"), tub, startBath, consumeWater, player)

    -- Disable if not enough water.
    local getTubFluidAmount = CSR_BathWater and CSR_BathWater.getAmount or function() return 0 end
    local getTubFluidCapacity = CSR_BathWater and CSR_BathWater.getCapacity or function() return 100 end

    local hasEnough = (consumeWater <= 0)
    if not hasEnough then
        hasEnough = (getTubFluidAmount(tub) >= consumeWater)
    end
    if not hasEnough then
        opt.notAvailable = true
        local tt = ISWorldObjectContextMenu.addToolTip()
        tt.description = getText("Tooltip_CSR_NotEnoughWaterToBathe")
        opt.toolTip = tt
    end

    -- Fill Tub option: only offer if the tub isn't already full and the
    -- area has running water. We always show the option (so the player
    -- can see why it's unavailable) but grey it out when conditions fail.
    local curWater = getTubFluidAmount(tub)
    local maxWater = getTubFluidCapacity(tub)
    local hasRunningWater = CSR_BathWater and CSR_BathWater.squareHasRunningWater or squareHasRunningWater
    local canFill = hasRunningWater(tub:getSquare())
        or hasRunningWater(player:getCurrentSquare())
    local isFull = (maxWater > 0 and curWater >= maxWater)
    local fillOpt = context:addOption(
        textOr("ContextMenu_CSR_FillTub", "Fill Tub"),
        tub, startFillTub, player
    )
    if isFull then
        fillOpt.notAvailable = true
        local tt = ISWorldObjectContextMenu.addToolTip()
        tt.description = textOr("Tooltip_CSR_TubAlreadyFull", "The tub is already full.")
        fillOpt.toolTip = tt
    elseif not canFill then
        fillOpt.notAvailable = true
        local tt = ISWorldObjectContextMenu.addToolTip()
        tt.description = textOr("Tooltip_CSR_NoRunningWater", "There's no running water here.")
        fillOpt.toolTip = tt
    end

    local emptyOpt = context:addOption(
        textOr("ContextMenu_CSR_EmptyTub", "Empty Tub"),
        tub, startEmptyTub, player
    )
    if curWater <= 0 then
        emptyOpt.notAvailable = true
        local tt = ISWorldObjectContextMenu.addToolTip()
        tt.description = textOr("Tooltip_CSR_TubAlreadyEmpty", "The tub is already empty.")
        emptyOpt.toolTip = tt
    end
end

if Events and Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(onFillContextMenu)
end
