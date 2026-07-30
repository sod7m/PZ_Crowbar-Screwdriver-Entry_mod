require "CSE_Utils"
require "CSE_Config"

CSE_ServerCommands = {}

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

local function boltCutterEnabled()
    return entryActionsEnabled() and sandbox().EnableBoltCutter ~= false
end

local function fenceCuttingEnabled()
    return boltCutterEnabled() and sandbox().EnableFenceCutting ~= false
end

local function sendResult(player, text)
    sendServerCommand(player, CSE_Config.MODULE_NAME, "ActionResult", {
        text = text,
        playerOnlineID = player and player.getOnlineID and player:getOnlineID() or nil,
        playerIndex = player and player.getPlayerNum and player:getPlayerNum() or 0,
    })
end

local function spriteName(obj)
    local sprite = obj and obj.getSprite and obj:getSprite() or nil
    return sprite and sprite.getName and sprite:getName() or nil
end

local function iterateSquareObjects(square, fn)
    if not square then return end
    local objects = square:getObjects()
    if objects then
        for i = 0, objects:size() - 1 do
            fn(objects:get(i))
        end
    end
    local specialObjects = square:getSpecialObjects()
    if specialObjects then
        for i = 0, specialObjects:size() - 1 do
            fn(specialObjects:get(i))
        end
    end
end

-- Resolves the (x, y, z, objectIndex, sprite) the client sent back into the
-- actual world object. objectIndex is the fast path; sprite name and a
-- distance-agnostic scan of the square are fallbacks for when the client's
-- object list shifted between the request and the server processing it.
local function isPryCandidate(obj, player)
    return CSE_Utils.isPryTarget(obj) and not CSE_Utils.isBarricadedForPlayer(obj, player)
end

local function isBoltCutCandidate(obj, player)
    return CSE_Utils.isBoltCutterTarget(obj) and not CSE_Utils.isBarricadedForPlayer(obj, player)
end

local function isFenceCutCandidate(obj)
    return CSE_Utils.isFenceCutTarget(obj)
end

local function resolveWorldObject(args, player, isCandidate)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end

    isCandidate = isCandidate or isPryCandidate

    local square = getSquare(args.x, args.y, args.z)
    if not square then return nil end

    if args.objectIndex ~= nil and args.objectIndex >= 0 then
        local objects = square:getObjects()
        if objects and args.objectIndex < objects:size() then
            local obj = objects:get(args.objectIndex)
            if obj and isCandidate(obj, player) then
                return obj
            end
        end
    end

    local selected, fallback = nil, nil
    iterateSquareObjects(square, function(obj)
        if isCandidate(obj, player) then
            if not fallback then fallback = obj end
            if not selected and args.sprite and args.sprite ~= "" and spriteName(obj) == args.sprite then
                selected = obj
            end
        end
    end)

    return selected or fallback
end

local function findInventoryItemById(player, itemId)
    return CSE_Utils.findInventoryItemById(player, itemId)
end

local function getVehicleByArgs(args)
    if not args or not args.vehicleId then return nil end
    return getVehicleById and getVehicleById(args.vehicleId) or nil
end

local function isNearPlayer(player, args)
    return math.abs(player:getX() - args.x) <= CSE_Config.MAX_WORLD_INTERACT_DISTANCE
        and math.abs(player:getY() - args.y) <= CSE_Config.MAX_WORLD_INTERACT_DISTANCE
        and math.abs(player:getZ() - args.z) <= 1
end

local function isNearVehiclePart(player, vehicle, part)
    if not player.DistToSquared or not vehicle.getX or not vehicle.getY then
        return true
    end

    local refX, refY = vehicle:getX(), vehicle:getY()
    if part.getArea and vehicle.getAreaCenter then
        local areaCenter = vehicle:getAreaCenter(part:getArea())
        if areaCenter and areaCenter.getX and areaCenter.getY then
            refX, refY = areaCenter:getX(), areaCenter:getY()
        end
    end

    local maxDistance = CSE_Config.MAX_VEHICLE_INTERACT_DISTANCE
    return player:DistToSquared(refX, refY) <= (maxDistance * maxDistance)
end

-- ============================================================
-- Request dedupe
--
-- The client resends its command if it doesn't hear back in time, and
-- players can spam the context menu option. requestId (unique per attempt)
-- plus a short time window stops the same swing from being resolved twice.
-- ============================================================

local recentRequests = {}

local function getNowMs()
    return getTimestampMs and getTimestampMs() or os.time() * 1000
end

local function pruneOldRequests(nowMs)
    local cutoff = nowMs - CSE_Config.REQUEST_DEDUPE_WINDOW_MS
    for key, entry in pairs(recentRequests) do
        if not entry or entry < cutoff then
            recentRequests[key] = nil
        end
    end
end

local function isDuplicateRequest(player, command, args)
    local requestId = args and args.requestId
    if not requestId or requestId == "" then return false end

    local nowMs = getNowMs()
    pruneOldRequests(nowMs)

    local key = tostring(player and player.getOnlineID and player:getOnlineID() or "local")
        .. ":" .. tostring(command) .. ":" .. tostring(requestId)
    if recentRequests[key] then
        return true
    end
    recentRequests[key] = nowMs
    return false
end

-- ============================================================
-- Command handlers
-- ============================================================

function CSE_ServerCommands.handlePry(player, args)
    if not player or not args or not pryEnabled() then return end
    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    local crowbar = findInventoryItemById(player, args.crowbarId) or player:getInventory():FindAndReturn("Crowbar")
    local target = resolveWorldObject(args, player)
    if not crowbar or not target or not CSE_Utils.canPryWorldTarget(target, player) then
        sendResult(player, "Nothing to pry")
        return
    end

    local _, message = CSE_Utils.resolvePryAttempt(player, target, crowbar)
    sendResult(player, message)
end

function CSE_ServerCommands.handleLockpick(player, args)
    if not player or not args or not lockpickEnabled() then return end
    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    local screwdriver = findInventoryItemById(player, args.screwdriverId)
    if not screwdriver then
        local inv = player:getInventory()
        screwdriver = inv:FindAndReturn("Screwdriver") or inv:FindAndReturn("Screwdriver_Old") or inv:FindAndReturn("Screwdriver_Improvised")
    end

    local target = resolveWorldObject(args, player)
    if not screwdriver or not target or not CSE_Utils.canLockpickWorldTarget(target, player) then
        sendResult(player, "Nothing to lockpick")
        return
    end

    local _, message = CSE_Utils.resolveLockpickAttempt(player, target, screwdriver)
    sendResult(player, message)
end

function CSE_ServerCommands.handleBoltCut(player, args)
    if not player or not args or not boltCutterEnabled() then return end
    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    local tool = findInventoryItemById(player, args.toolId) or CSE_Utils.hasBoltCutters(player)
    if not tool then
        sendResult(player, "Nothing to cut")
        return
    end

    if args.isFence == true then
        if not fenceCuttingEnabled() then return end

        local fence = resolveWorldObject(args, player, isFenceCutCandidate)
        if not fence or not CSE_Utils.canBoltCutFence(fence, player) then
            sendResult(player, "Nothing to cut")
            return
        end

        local _, message = CSE_Utils.resolveFenceCutAttempt(player, fence, tool)
        sendResult(player, message)
        return
    end

    local target = resolveWorldObject(args, player, isBoltCutCandidate)
    if not target or not CSE_Utils.canBoltCutWorldTarget(target, player) then
        sendResult(player, "Nothing to cut")
        return
    end

    local _, message = CSE_Utils.resolveBoltCutAttempt(player, target, tool)
    sendResult(player, message)
end

function CSE_ServerCommands.handlePryVehicleDoor(player, args)
    if not player or not args or not vehicleDoorPryEnabled() then return end

    local crowbar = findInventoryItemById(player, args.crowbarId) or player:getInventory():FindAndReturn("Crowbar")
    local vehicle = getVehicleByArgs(args)
    local part = vehicle and args.partId and vehicle:getPartById(args.partId) or nil
    if not crowbar or not vehicle or not part or not CSE_Utils.canPryVehiclePart(part) then
        sendResult(player, "Nothing to pry")
        return
    end
    if not isNearVehiclePart(player, vehicle, part) then
        sendResult(player, "Too far away")
        return
    end

    local _, message = CSE_Utils.resolvePryVehicleAttempt(player, vehicle, part, crowbar)
    sendResult(player, message)
end

function CSE_ServerCommands.handleLockpickVehicleDoor(player, args)
    if not player or not args or not lockpickEnabled() then return end

    local screwdriver = findInventoryItemById(player, args.screwdriverId)
    if not screwdriver then
        local inv = player:getInventory()
        screwdriver = inv:FindAndReturn("Screwdriver") or inv:FindAndReturn("Screwdriver_Old") or inv:FindAndReturn("Screwdriver_Improvised")
    end

    local vehicle = getVehicleByArgs(args)
    local part = vehicle and args.partId and vehicle:getPartById(args.partId) or nil
    if not screwdriver or not vehicle or not part or not CSE_Utils.canLockpickVehiclePart(part) then
        sendResult(player, "Nothing to lockpick")
        return
    end
    if not isNearVehiclePart(player, vehicle, part) then
        sendResult(player, "Too far away")
        return
    end

    local _, message = CSE_Utils.resolveLockpickVehicleAttempt(player, vehicle, part, screwdriver)
    sendResult(player, message)
end

local function onClientCommand(module, command, player, args)
    if module ~= CSE_Config.MODULE_NAME then return end

    if isDuplicateRequest(player, command, args) then return end

    if command == "PryTarget" then
        CSE_ServerCommands.handlePry(player, args)
    elseif command == "LockpickTarget" then
        CSE_ServerCommands.handleLockpick(player, args)
    elseif command == "BoltCutTarget" then
        CSE_ServerCommands.handleBoltCut(player, args)
    elseif command == "PryVehicleDoor" then
        CSE_ServerCommands.handlePryVehicleDoor(player, args)
    elseif command == "LockpickVehicleDoor" then
        CSE_ServerCommands.handleLockpickVehicleDoor(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)

return CSE_ServerCommands
