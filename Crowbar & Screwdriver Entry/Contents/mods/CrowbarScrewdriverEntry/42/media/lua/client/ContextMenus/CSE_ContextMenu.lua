require "CSE_Utils"
require "TimedActions/CSE_PryOpenAction"
require "TimedActions/CSE_PryVehicleDoorAction"
require "TimedActions/CSE_LockpickOpenAction"
require "TimedActions/CSE_LockpickVehicleDoorAction"
require "TimedActions/CSE_BoltCutAction"

CSE_ContextMenu = {}

local function sandbox()
    return SandboxVars and SandboxVars.CrowbarScrewdriverEntry or {}
end

local function entryActionsEnabled()
    return sandbox().EnableEntryActions ~= false
end

local function pryEnabled()
    return entryActionsEnabled() and sandbox().EnablePrySystem ~= false
end

local function lockpickEnabled()
    return entryActionsEnabled() and sandbox().EnableScrewdriverLockpick ~= false
end

local function vehicleDoorPryEnabled()
    return pryEnabled() and sandbox().EnableVehicleDoorPry ~= false
end

local function vehicleDoorLockpickEnabled()
    return lockpickEnabled() and sandbox().EnableVehicleDoorLockpick ~= false
end

-- Bolt cutters hang off the master switch only, not off EnablePrySystem:
-- an admin who turns off crowbar prying hasn't said anything about cutters.
local function boltCutterEnabled()
    return entryActionsEnabled() and sandbox().EnableBoltCutter ~= false
end

local function fenceCuttingEnabled()
    return boltCutterEnabled() and sandbox().EnableFenceCutting ~= false
end

local function createTooltip(text)
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip.description = text
    return tooltip
end

local function setTooltip(option, lines)
    if not option or not lines or #lines == 0 then return end
    option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
end

local function findClickedVehicle(worldobjects)
    local fetch = ISWorldObjectContextMenu.fetchVars
    if fetch and fetch.clickedSquare and fetch.clickedSquare.getVehicleContainer then
        local vehicle = fetch.clickedSquare:getVehicleContainer()
        if vehicle then return vehicle end
    end

    for _, obj in ipairs(worldobjects) do
        if instanceof(obj, "BaseVehicle") then
            return obj
        elseif obj.getSquare and obj:getSquare() and obj:getSquare().getVehicleContainer then
            local vehicle = obj:getSquare():getVehicleContainer()
            if vehicle then return vehicle end
        end
    end

    return nil
end

local function addVehicleEntryOptions(context, worldobjects, player, vehicle)
    if not vehicleDoorPryEnabled() and not vehicleDoorLockpickEnabled() then return end

    local crowbar = CSE_Utils.hasCrowbar(player)
    if crowbar and vehicleDoorPryEnabled() then
        local part = CSE_Utils.findVehicleActionPart(player, vehicle, CSE_Utils.canPryVehiclePart)
        if part then
            local option = context:addOption(getText("ContextMenu_CSE_PryVehicleDoor"), worldobjects, CSE_ContextMenu.onPryVehicleDoor, player, vehicle, part, crowbar)
            option.iconTexture = crowbar:getTexture()
            setTooltip(option, {
                "Force this vehicle door or hatch open with a crowbar.",
                "Loud, and may shatter a nearby window on a bad miss.",
            })
        end
    end

    local screwdriver = CSE_Utils.hasScrewdriver(player)
    if screwdriver and vehicleDoorLockpickEnabled() then
        local part = CSE_Utils.findVehicleActionPart(player, vehicle, CSE_Utils.canLockpickVehiclePart)
        if part then
            local option = context:addOption(getText("ContextMenu_CSE_LockpickVehicleDoor"), worldobjects, CSE_ContextMenu.onLockpickVehicleDoor, player, vehicle, part, screwdriver)
            option.iconTexture = screwdriver:getTexture()
            setTooltip(option, {
                "Quietly unlock this vehicle door or hatch with a screwdriver.",
            })
        end
    end
end

function CSE_ContextMenu.addWorldObjectOptions(playerNum, context, worldobjects, test)
    if test then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    if not entryActionsEnabled() then return end

    local crowbar = CSE_Utils.hasCrowbar(player)
    if crowbar and pryEnabled() then
        local retryTarget = CSE_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSE_Utils.isPryRetryTarget(obj) == true
                and CSE_Utils.canPryWorldTarget(obj, player) == true
        end)
        if retryTarget then
            local option = context:addOption(getText("ContextMenu_CSE_ForceOpenAgain"), worldobjects, CSE_ContextMenu.onPryOpen, player, retryTarget, crowbar)
            option.iconTexture = crowbar:getTexture()
            setTooltip(option, {
                "Force open a security door (or one you already forced) that locked itself again.",
                "Success scales with Strength, Fitness, and crowbar condition.",
            })
        end

        local pryTarget = CSE_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSE_Utils.canPryWorldTarget(obj, player) == true
                and CSE_Utils.isPryRetryTarget(obj) ~= true
        end)
        if pryTarget then
            local option = context:addOption(getText("ContextMenu_CSE_PryOpen"), worldobjects, CSE_ContextMenu.onPryOpen, player, pryTarget, crowbar)
            option.iconTexture = crowbar:getTexture()
            setTooltip(option, {
                "Use a crowbar to force this open.",
                "Success scales with Strength, Fitness, and crowbar condition.",
                "Loud - failing damages the crowbar and risks a hand injury.",
            })
        end
    end

    local screwdriver = CSE_Utils.hasScrewdriver(player)
    if screwdriver and lockpickEnabled() then
        local lockpickTarget = CSE_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSE_Utils.canLockpickWorldTarget(obj, player) == true
        end)
        if lockpickTarget then
            local option = context:addOption(getText("ContextMenu_CSE_PickLockScrewdriver"), worldobjects, CSE_ContextMenu.onLockpickOpen, player, lockpickTarget, screwdriver)
            option.iconTexture = screwdriver:getTexture()
            setTooltip(option, {
                "Use a screwdriver to work the lock quietly.",
                "Success scales with Nimble, Mechanics, Fitness, and screwdriver condition.",
            })
        end
    end

    local boltCutters = CSE_Utils.hasBoltCutters(player)
    if boltCutters and boltCutterEnabled() then
        local lockTarget = CSE_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSE_Utils.canBoltCutWorldTarget(obj, player) == true
        end)
        if lockTarget then
            local option = context:addOption(getText("ContextMenu_CSE_CutLockBoltCutters"), worldobjects, CSE_ContextMenu.onBoltCut, player, lockTarget, boltCutters)
            option.iconTexture = boltCutters:getTexture()
            setTooltip(option, {
                "Cut straight through the lock mechanism with bolt cutters.",
                "Works on locked doors and gates, reinforced ones included where the server allows it.",
                "Success scales with Strength, Fitness, and tool condition.",
            })
        end

        if fenceCuttingEnabled() then
            local fenceTarget = CSE_Utils.findWorldTarget(worldobjects, player, function(obj)
                return CSE_Utils.canBoltCutFence(obj, player) == true
            end)
            if fenceTarget then
                local option = context:addOption(getText("ContextMenu_CSE_CutFenceBoltCutters"), worldobjects, CSE_ContextMenu.onBoltCutFence, player, fenceTarget, boltCutters)
                option.iconTexture = boltCutters:getTexture()
                setTooltip(option, {
                    "Cut a hole through a wire-mesh or barbed-wire fence panel.",
                    "Removes the panel and drops the salvaged wire at your feet.",
                    "Success scales with Strength, Fitness, and tool condition.",
                })
            end
        end
    end

    local clickedVehicle = findClickedVehicle(worldobjects)
    if clickedVehicle then
        addVehicleEntryOptions(context, worldobjects, player, clickedVehicle)
    end
end

function CSE_ContextMenu.onPryOpen(worldobjects, player, obj, crowbar)
    local square = obj and obj.getSquare and obj:getSquare() or nil
    if square and luautils.walkAdjWindowOrDoor(player, square, obj) then
        ISTimedActionQueue.add(CSE_PryOpenAction:new(player, obj, crowbar))
    end
end

function CSE_ContextMenu.onLockpickOpen(worldobjects, player, obj, screwdriver)
    local square = obj and obj.getSquare and obj:getSquare() or nil
    if square and luautils.walkAdjWindowOrDoor(player, square, obj) then
        ISTimedActionQueue.add(CSE_LockpickOpenAction:new(player, obj, screwdriver))
    end
end

function CSE_ContextMenu.onBoltCut(worldobjects, player, obj, boltCutters)
    local square = obj and obj.getSquare and obj:getSquare() or nil
    if square and luautils.walkAdjWindowOrDoor(player, square, obj) then
        ISTimedActionQueue.add(CSE_BoltCutAction:new(player, obj, boltCutters, false))
    end
end

function CSE_ContextMenu.onBoltCutFence(worldobjects, player, obj, boltCutters)
    local square = obj and obj.getSquare and obj:getSquare() or nil
    if not square then return end

    -- B42 fence panels carry an orientation like doors and windows do, so
    -- walkAdjWindowOrDoor lets the player walk up from either side the way
    -- vanilla "Climb Over" does. Plain walkAdj only paths to whichever side
    -- the engine picked, which makes the option look dead from the other one.
    local approached = false
    if luautils.walkAdjWindowOrDoor then
        approached = luautils.walkAdjWindowOrDoor(player, square, obj)
    end
    if not approached then
        approached = luautils.walkAdj(player, square)
    end

    if approached then
        ISTimedActionQueue.add(CSE_BoltCutAction:new(player, obj, boltCutters, true))
    end
end

function CSE_ContextMenu.onPryVehicleDoor(worldobjects, player, vehicle, part, crowbar)
    ISTimedActionQueue.add(CSE_PryVehicleDoorAction:new(player, vehicle, part, crowbar))
end

function CSE_ContextMenu.onLockpickVehicleDoor(worldobjects, player, vehicle, part, screwdriver)
    ISTimedActionQueue.add(CSE_LockpickVehicleDoorAction:new(player, vehicle, part, screwdriver))
end

Events.OnFillWorldObjectContextMenu.Add(CSE_ContextMenu.addWorldObjectOptions)

-- The right-click menu above only covers ISWorldObjectContextMenu. Standing
-- next to a vehicle and pressing the radial-menu key (V) opens a separate
-- vanilla wheel built by ISVehicleMenu.showRadialMenuOutside, which we have
-- to patch directly to add slices to it.
local function hookVehicleRadialMenu()
    if not ISVehicleMenu or not ISVehicleMenu.showRadialMenuOutside or ISVehicleMenu.__cseRadialPatched then
        return
    end
    ISVehicleMenu.__cseRadialPatched = true

    local originalShowRadialMenuOutside = ISVehicleMenu.showRadialMenuOutside
    ISVehicleMenu.showRadialMenuOutside = function(playerObj, ...)
        originalShowRadialMenuOutside(playerObj, ...)

        if not playerObj or not entryActionsEnabled() then return end

        local vehicle = ISVehicleMenu.getVehicleToInteractWith and ISVehicleMenu.getVehicleToInteractWith(playerObj) or nil
        if not vehicle then return end

        local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
        if not menu then return end

        local crowbar = CSE_Utils.hasCrowbar(playerObj)
        if crowbar and vehicleDoorPryEnabled() then
            local part = CSE_Utils.findVehicleActionPart(playerObj, vehicle, CSE_Utils.canPryVehiclePart)
            if part then
                menu:addSlice(getText("ContextMenu_CSE_PryVehicleDoor"), crowbar:getTexture(), function()
                    ISTimedActionQueue.add(CSE_PryVehicleDoorAction:new(playerObj, vehicle, part, crowbar))
                end)
            end
        end

        local screwdriver = CSE_Utils.hasScrewdriver(playerObj)
        if screwdriver and vehicleDoorLockpickEnabled() then
            local part = CSE_Utils.findVehicleActionPart(playerObj, vehicle, CSE_Utils.canLockpickVehiclePart)
            if part then
                menu:addSlice(getText("ContextMenu_CSE_LockpickVehicleDoor"), screwdriver:getTexture(), function()
                    ISTimedActionQueue.add(CSE_LockpickVehicleDoorAction:new(playerObj, vehicle, part, screwdriver))
                end)
            end
        end
    end
end

Events.OnGameStart.Add(hookVehicleRadialMenu)

return CSE_ContextMenu
