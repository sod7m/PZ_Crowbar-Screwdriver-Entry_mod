-- Shared bathtub water state for CSR bathing.
-- B42 plumbing can report a faucet/tub sprite as full because it is piped;
-- CSR tracks the actual bath water separately on flat object modData.

CSR_BathWater = CSR_BathWater or {}

local DEFAULT_CAPACITY = 100

local VANILLA_TUB_SPRITES = {
    bathroom_01_22 = true, bathroom_01_23 = true,
    bathroom_01_24 = true, bathroom_01_25 = true,
    bathroom_01_26 = true, bathroom_01_27 = true,
    bathroom_01_30 = true, bathroom_01_31 = true,
    bathroom_01_32 = true, bathroom_01_33 = true,
    bathroom_01_52 = true, bathroom_01_53 = true,
    bathroom_01_54 = true, bathroom_01_55 = true,
}

local function clamp(value, low, high)
    value = tonumber(value) or 0
    if value < low then return low end
    if value > high then return high end
    return value
end

local function spriteNameOf(obj)
    local spr = obj and obj.getSprite and obj:getSprite() or nil
    return spr and spr.getName and spr:getName() or nil
end

function CSR_BathWater.isTubSprite(spriteName)
    if not spriteName then return false end
    for key in pairs(VANILLA_TUB_SPRITES) do
        if string.find(spriteName, key, 1, true) then return true end
    end
    return false
end

function CSR_BathWater.isTubObject(obj)
    return obj ~= nil and CSR_BathWater.isTubSprite(spriteNameOf(obj))
end

function CSR_BathWater.getCapacity(tub)
    if not tub or not tub.getModData then return DEFAULT_CAPACITY end
    local md = tub:getModData()
    local cap = md and tonumber(md.csrBathCapacity) or nil
    if cap and cap > 0 then return cap end
    return DEFAULT_CAPACITY
end

function CSR_BathWater.getAmount(tub)
    if not tub or not tub.getModData then return 0 end
    local md = tub:getModData()
    if not md then return 0 end
    return clamp(md.csrBathWater or 0, 0, CSR_BathWater.getCapacity(tub))
end

local function transmitBathState(tub)
    if not tub then return end
    if tub.transmitModData then
        pcall(function() tub:transmitModData() end)
    end
    local sq = tub.getSquare and tub:getSquare() or nil
    if sq and sq.transmitModdataToClients then
        pcall(function() sq:transmitModdataToClients() end)
    end
end

function CSR_BathWater.applyLocal(tub, amount)
    if not tub or not tub.getModData then return 0 end
    local capacity = CSR_BathWater.getCapacity(tub)
    local nextAmount = clamp(amount, 0, capacity)
    local md = tub:getModData()
    md.csrBathCapacity = capacity
    md.csrBathWater = nextAmount
    transmitBathState(tub)
    return nextAmount
end

local function sendSetWaterCommand(tub, amount, player, reason)
    if not (isClient and isClient()) then return end
    if not player or not sendClientCommand then return end
    local sq = tub and tub.getSquare and tub:getSquare() or nil
    if not sq then return end
    sendClientCommand(player, "CommonSenseLight", "BathSetWater", {
        x = sq:getX(),
        y = sq:getY(),
        z = sq:getZ(),
        sprite = spriteNameOf(tub) or "",
        amount = amount,
        reason = tostring(reason or ""),
    })
end

function CSR_BathWater.setAmount(tub, amount, player, reason)
    local nextAmount = CSR_BathWater.applyLocal(tub, amount)
    sendSetWaterCommand(tub, nextAmount, player, reason)
    return nextAmount
end

function CSR_BathWater.add(tub, delta, player, reason)
    return CSR_BathWater.setAmount(tub, CSR_BathWater.getAmount(tub) + (tonumber(delta) or 0), player, reason)
end

function CSR_BathWater.consume(tub, amount, player, reason)
    return CSR_BathWater.add(tub, -(tonumber(amount) or 0), player, reason)
end

function CSR_BathWater.isFull(tub)
    return CSR_BathWater.getAmount(tub) >= CSR_BathWater.getCapacity(tub)
end

local function propsHas(props, key)
    if not props or key == nil then return false end
    -- B42 SpriteProperties exposes both Is() (boolean accessor) and has()
    -- (key-presence check).  TABAS-style detection uses :Is() because
    -- :has() can return true for the *presence* of the flag without it
    -- being set.  We try :Is() first, fall back to :has().
    if props.Is then
        local ok, result = pcall(function() return props:Is(key) end)
        if ok and result == true then return true end
    end
    if props.has then
        local ok2, r2 = pcall(function() return props:has(key) end)
        if ok2 and r2 == true then return true end
    end
    return false
end

local function worldWaterStillOn()
    local opts = getSandboxOptions and getSandboxOptions() or nil
    local gt = getGameTime and getGameTime() or nil
    if opts and gt and gt.getWorldAgeHours then
        local elapsedDays = gt:getWorldAgeHours() / 24
        local apoOpt = opts.getOptionByName and opts:getOptionByName("TimeSinceApo") or nil
        local apo = apoOpt and apoOpt.getValue and apoOpt:getValue() or 1
        local shut = opts.getWaterShutModifier and opts:getWaterShutModifier() or 14
        return (elapsedDays + ((apo - 1) * 30)) < shut
    end
    return true
end

-- TABAS-style infinite-water check: piped + square not flagged no-water
-- + the world water shutoff hasn't elapsed yet.
local function isWaterInfinite(obj)
    if not obj then return false end
    local sq = obj.getSquare and obj:getSquare() or nil
    if not sq then return false end
    if sq.isNoWater and sq:isNoWater() then return false end
    local spr = obj.getSprite and obj:getSprite() or nil
    local props = spr and spr.getProperties and spr:getProperties() or nil
    if not props then return false end
    if not (IsoFlagType and propsHas(props, IsoFlagType.waterPiped)) then return false end
    return worldWaterStillOn()
end

-- TABAS verbatim: an "external" water source is an IsoThumpable that
-- holds fluid on its own (rain barrel, water bottle on a counter, etc.).
local function isExternalWaterSourceObject(obj)
    if not obj then return false end
    if not (instanceof and instanceof(obj, "IsoThumpable")) then return false end
    if obj.getFluidCapacity then
        local cap = obj:getFluidCapacity()
        if not cap or (tonumber(cap) or 0) <= 0 then return false end
    else
        return false
    end
    if obj.getUsesExternalWaterSource and obj:getUsesExternalWaterSource() then
        return false
    end
    local spr = obj.getSprite and obj:getSprite() or nil
    local props = spr and spr.getProperties and spr:getProperties() or nil
    if props and propsHas(props, IsoFlagType and IsoFlagType.solidfloor or nil) then
        return false
    end
    if obj.getFluidContainer then
        local fc = obj:getFluidContainer()
        if fc then
            local ok, amount = pcall(function() return fc:getAmount() end)
            if ok and (tonumber(amount) or 0) > 0 then return true end
        end
    end
    if obj.getWaterAmount then
        local amount = obj:getWaterAmount()
        if (tonumber(amount) or 0) > 0 then return true end
    end
    return false
end

-- TABAS verbatim: scan the 3x3 block of squares one tile up from the
-- given (x, y, z) for any IsoThumpable holding water.  This is what lets
-- rain barrels / sinks on the floor above feed a downstairs tub.
local function findExternalWaterSource(x, y, z)
    local cell = getCell and getCell() or nil
    if not cell or not cell.getGridSquare then return nil end
    for i = -1, 1 do
        for j = -1, 1 do
            local sq = cell:getGridSquare(x + i, y + j, z + 1)
            if sq then
                local objs = sq.getObjects and sq:getObjects() or nil
                if objs then
                    for k = 0, objs:size() - 1 do
                        local o = objs:get(k)
                        if isExternalWaterSourceObject(o) then
                            return o
                        end
                    end
                end
            end
        end
    end
    return nil
end

function CSR_BathWater.findExternalWaterSource(x, y, z)
    return findExternalWaterSource(x, y, z)
end

function CSR_BathWater.objectHasRunningWater(obj)
    if not obj then return false end
    -- Piped + water-still-on path (faucets, sinks, tubs).
    if isWaterInfinite(obj) then return true end
    -- External source linked on the object itself.
    if obj.getUsesExternalWaterSource and obj:getUsesExternalWaterSource() then
        if worldWaterStillOn() then return true end
    end
    if obj.getWaterAmount then
        local amount = obj:getWaterAmount()
        if (tonumber(amount) or 0) > 0 then return true end
    end
    return false
end

function CSR_BathWater.squareHasRunningWater(square)
    if not square then return false end
    local objects = square.getObjects and square:getObjects() or nil
    if objects then
        for i = 0, objects:size() - 1 do
            if CSR_BathWater.objectHasRunningWater(objects:get(i)) then
                return true
            end
        end
    end
    -- TABAS upstairs scan: water sources on the floor above feed this tile.
    local x = square.getX and square:getX() or nil
    local y = square.getY and square:getY() or nil
    local z = square.getZ and square:getZ() or nil
    if x and y and z and findExternalWaterSource(x, y, z) then
        return true
    end
    local room = square.getRoom and square:getRoom() or nil
    if room and room.isHydroPowered and room:isHydroPowered() then
        return true
    end
    return false
end

return CSR_BathWater
