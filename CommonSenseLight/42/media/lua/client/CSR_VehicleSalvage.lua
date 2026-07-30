require "CSR_FeatureFlags"

--[[
    CSR_VehicleSalvage.lua
    Adds "Salvage Vehicle" context menu option to right-clicking vehicles.
    Salvaging requires a blowtorch + welding mask, Mechanics >= 3, MetalWelding >= 3.
    The vehicle is destroyed after salvaging and materials drop on the ground.
    Higher MetalWelding = more loot rolls + better odds per roll.
    Sandbox-togglable via EnableVehicleSalvage.
]]

CSR_VehicleSalvage = CSR_VehicleSalvage or {}

-- Vanilla-matching predicates (same pattern as ISVehicleMenu.lua)
local function predicateWeldingMask(item)
    return (ItemTag and ItemTag.WELDING_MASK and item:hasTag(ItemTag.WELDING_MASK)) or item:getType() == "WeldingMask"
end

local function comparatorDrainableUsesInt(item1, item2)
    return item1:getCurrentUses() - item2:getCurrentUses()
end

local function hasBlowTorch(player, minUses)
    local inv = player:getInventory()
    if not inv then return nil end
    local torch = inv:getBestTypeEvalRecurse("Base.BlowTorch", comparatorDrainableUsesInt)
    if torch and torch:getCurrentUses() >= minUses then
        return torch
    end
    return nil
end

local function hasWeldingMask(player)
    local inv = player:getInventory()
    if not inv then return false, nil end
    local mask = inv:getFirstEvalRecurse(predicateWeldingMask)
    if mask then return true, mask end
    return false, nil
end

local TORCH_USES = 1

local function canDestroyClaimedVehicle(player, vehicle)
    if not player or not vehicle then return false end
    if not (CSR_VehicleClaim and CSR_VehicleClaim.getOwner) then return true end
    local owner = CSR_VehicleClaim.getOwner(vehicle)
    if not owner or owner == "" then return true end
    if player.getUsername and owner == player:getUsername() then return true end
    local access = player.getAccessLevel and player:getAccessLevel() or ""
    return access == "admin" or access == "Admin"
end

local function showHalo(player, text, r, g, b)
    if player and player.setHaloNote and text then
        player:setHaloNote(text, r or 255, g or 190, b or 90, 250)
    end
end

local function getSalvageBlockReason(player, vehicle)
    if not player or not vehicle then return "No vehicle nearby" end
    if not CSR_FeatureFlags.isVehicleSalvageEnabled() then return "Vehicle salvage is disabled" end
    if vehicle.isBurnt and vehicle:isBurnt() then return "Burnt vehicles cannot be salvaged" end
    if not canDestroyClaimedVehicle(player, vehicle) then return "Only the owner or an admin can salvage this claimed vehicle" end

    local torch = hasBlowTorch(player, TORCH_USES)
    if not torch then return "Need a propane torch" end

    local hasMask = hasWeldingMask(player)
    if not hasMask then return "Need a welding mask" end

    local mechLvl = player:getPerkLevel(Perks.Mechanics)
    if mechLvl < 1 then return "Need Mechanics 1+" end

    local weldLvl = player:getPerkLevel(Perks.MetalWelding)
    if weldLvl < 1 then return "Need Metal Welding 1+" end

    return nil
end

local function onVehicleSalvage(worldobjects, player, vehicle)
    if not player or not vehicle then return end
    local reason = getSalvageBlockReason(player, vehicle)
    if reason then
        showHalo(player, reason, 255, 140, 80)
        return
    end

    local torch = hasBlowTorch(player, TORCH_USES)
    if not torch then return end

    local hasMask, maskItem = hasWeldingMask(player)
    if not hasMask then return end

    -- Walk to vehicle
    local sq = vehicle:getSquare()
    if sq then
        luautils.walkAdj(player, sq, true)
    end

    -- Equip torch
    if torch then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(player, torch, 50, true))
    end

    -- Wear mask if not worn
    if maskItem and not player:isEquippedClothing(maskItem) then
        ISTimedActionQueue.add(ISWearClothing:new(player, maskItem, 50))
    end

    -- Queue salvage action
    ISTimedActionQueue.add(CSR_ISVehicleSalvage:new(player, vehicle, torch))
end

local function patchVehicleMenu()
    if not ISVehicleMenu or ISVehicleMenu.__csr_salvage_patched then return end
    ISVehicleMenu.__csr_salvage_patched = true

    local origFill = ISVehicleMenu.FillMenuOutsideVehicle
    function ISVehicleMenu.FillMenuOutsideVehicle(player, context, vehicle, test)
        if origFill then origFill(player, context, vehicle, test) end

        if test or not CSR_FeatureFlags.isVehicleSalvageEnabled() then return end
        if CSR_FeatureFlags.isCSRRadialMenuEnabled
                and CSR_FeatureFlags.isCSRRadialMenuEnabled() then
            return
        end

        local playerObj = getSpecificPlayer(player)
        if not playerObj or not vehicle then return end

        -- Skip burnt vehicles
        if vehicle.isBurnt and vehicle:isBurnt() then return end

        -- Claimed vehicles can only be destroyed by the owner or an admin.
        if not canDestroyClaimedVehicle(playerObj, vehicle) then return end

        local mechLvl = playerObj:getPerkLevel(Perks.Mechanics)
        local weldLvl = playerObj:getPerkLevel(Perks.MetalWelding)
        local torch = hasBlowTorch(playerObj, TORCH_USES)
        local hasMask, _ = hasWeldingMask(playerObj)

        local option = context:addOption(getText("ContextMenu_CSR_SalvageVehicle"), worldobjects, onVehicleSalvage, playerObj, vehicle)
        option.iconTexture = getTexture("Item_BlowTorch")

        -- Tooltip
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)

        local lines = {}
        table.insert(lines, "Strip a vehicle for usable scrap materials.")
        table.insert(lines, "Higher Metal Welding = more & better materials.")
        table.insert(lines, " ")
        table.insert(lines, "Requirements:")

        if not torch then
            table.insert(lines, " <RGB:1,0,0> - Propane Torch (" .. TORCH_USES .. " uses)")
            option.notAvailable = true
        else
            table.insert(lines, " <RGB:1,1,1> - Propane Torch (" .. TORCH_USES .. " uses)")
        end

        if not hasMask then
            table.insert(lines, " <RGB:1,0,0> - Welding Mask (worn or inventory)")
            option.notAvailable = true
        else
            table.insert(lines, " <RGB:1,1,1> - Welding Mask (worn or inventory)")
        end

        if mechLvl < 1 then
            table.insert(lines, " <RGB:1,0,0> - Mechanics 1+ (current: " .. mechLvl .. ")")
            option.notAvailable = true
        else
            table.insert(lines, " <RGB:1,1,1> - Mechanics 1+ (current: " .. mechLvl .. ")")
        end

        if weldLvl < 1 then
            table.insert(lines, " <RGB:1,0,0> - Metal Welding 1+ (current: " .. weldLvl .. ")")
            option.notAvailable = true
        else
            table.insert(lines, " <RGB:1,1,1> - Metal Welding 1+ (current: " .. weldLvl .. ")")
        end

        table.insert(lines, " ")
        table.insert(lines, " <RGB:0.7,0.7,0.7> The vehicle will be permanently destroyed.")

        tooltip.description = table.concat(lines, " <LINE>")
        option.toolTip = tooltip
    end
end

local function canSalvageNow(playerObj, vehicle)
    return getSalvageBlockReason(playerObj, vehicle) == nil
end

local function addSalvageRadialSlice(playerObj, vehicle)
    if not playerObj or not vehicle or not CSR_FeatureFlags.isVehicleSalvageEnabled() then return end
    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if not menu then return end
    menu:addSlice(getText("ContextMenu_CSR_SalvageVehicle"),
        getTexture("Item_BlowTorch"),
        function()
            local reason = getSalvageBlockReason(playerObj, vehicle)
            if reason then
                showHalo(playerObj, reason, 255, 140, 80)
                return
            end
            onVehicleSalvage(nil, playerObj, vehicle)
        end)
end

local function patchVehicleRadial()
    if not ISVehicleMenu or not ISVehicleMenu.showRadialMenuOutside
            or ISVehicleMenu.__csr_salvage_radial then
        return
    end
    ISVehicleMenu.__csr_salvage_radial = true
    local originalShowRadialMenuOutside = ISVehicleMenu.showRadialMenuOutside
    ISVehicleMenu.showRadialMenuOutside = function(playerObj, ...)
        originalShowRadialMenuOutside(playerObj, ...)
        if not playerObj or playerObj:getVehicle() then return end
        local vehicle = ISVehicleMenu.getVehicleToInteractWith
            and ISVehicleMenu.getVehicleToInteractWith(playerObj) or nil
        if vehicle then
            addSalvageRadialSlice(playerObj, vehicle)
        end
    end
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(patchVehicleMenu)
    Events.OnGameStart.Add(patchVehicleRadial)
end

return CSR_VehicleSalvage
