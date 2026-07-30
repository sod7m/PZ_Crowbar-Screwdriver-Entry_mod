if isClient() then return end

require "CSR_FeatureFlags"

CSR_RVExitRescueServer = CSR_RVExitRescueServer or {}

local MODULE = "CommonSenseLight"
local CMD_REQUEST = "RVExitRescue"
local CMD_TELEPORT = "RVExitRescueTeleport"
local PROJECT_RV_MODDATA = "modPROJECTRVInterior"
local LAST_SAFE_KEY = "CSR_RVExitRescueLastSafe"
local RECORD_INTERVAL_MS = 10000
local MIN_MOVE_TO_UPDATE_SQ = 4

local _lastRecordMs = 0

local function sandbox()
    return SandboxVars and SandboxVars.CommonSenseLight or {}
end

local function enabled()
    if CSR_FeatureFlags and CSR_FeatureFlags.isRVExitRescueEnabled then
        return CSR_FeatureFlags.isRVExitRescueEnabled()
    end
    return sandbox().EnableRVExitRescue ~= false
end

local function nowMs()
    return (getTimestampMs and getTimestampMs()) or 0
end

local function isFiniteNumber(n)
    return type(n) == "number" and n == n and n > -100000 and n < 100000
end

local function isInteriorCoord(x, y)
    return x and y and x > 22500 and y > 12000
end

local function playerInRVInterior(player)
    if not player then return false end
    local x = player.getX and player:getX() or nil
    local y = player.getY and player:getY() or nil
    return isInteriorCoord(x, y)
end

local function validTarget(x, y, z)
    x = tonumber(x)
    y = tonumber(y)
    z = tonumber(z) or 0
    if not isFiniteNumber(x) or not isFiniteNumber(y) or not isFiniteNumber(z) then
        return nil
    end
    if x < 0 or y < 0 or z < 0 or z > 32 then return nil end
    if x == 0 and y == 0 then return nil end
    if isInteriorCoord(x, y) then return nil end
    return { x = x, y = y, z = z }
end

local function withSource(candidate, source)
    if not candidate then return nil end
    candidate.source = source
    return candidate
end

local function playerModData(player)
    return player and player.getModData and player:getModData() or nil
end

local function projectRVModData()
    if not ModData or not ModData.getOrCreate then return nil end
    return ModData.getOrCreate(PROJECT_RV_MODDATA)
end

local function candidateFromBeforeEnter(player)
    local pmd = playerModData(player)
    local before = pmd and pmd.beforeEnter
    if type(before) ~= "table" then return nil end
    local playerId = pmd and pmd.projectRV_playerId
    local md = projectRVModData()
    local pdata = md and md.Players and playerId and md.Players[playerId] or nil
    if pdata and before.vehicleId and pdata.VehicleId
        and tostring(before.vehicleId) ~= tostring(pdata.VehicleId) then
        return nil
    end
    return withSource(validTarget(before.x, before.y, before.z), "ProjectRV beforeEnter")
end

local function candidateFromProjectRVVehicle(player)
    local pmd = playerModData(player)
    local playerId = pmd and pmd.projectRV_playerId
    if not playerId then return nil end
    local md = projectRVModData()
    local pdata = md and md.Players and md.Players[playerId] or nil
    local vehicleId = pdata and pdata.VehicleId or nil
    if not vehicleId then return nil end
    local vpos = md and md.Vehicles and md.Vehicles[vehicleId] or nil
    if type(vpos) ~= "table" then return nil end
    return withSource(validTarget(vpos.x, vpos.y, vpos.z), "ProjectRV vehicle position")
end

local function candidateFromCSRLastSafe(player)
    local pmd = playerModData(player)
    local safe = pmd and pmd[LAST_SAFE_KEY] or nil
    if type(safe) ~= "table" then return nil end
    return withSource(validTarget(safe.x, safe.y, safe.z), "CSR last safe position")
end

local function chooseTarget(player)
    return candidateFromBeforeEnter(player)
        or candidateFromProjectRVVehicle(player)
        or candidateFromCSRLastSafe(player)
end

local function sendActionResult(player, text)
    if not player or not text then return end
    pcall(function()
        sendServerCommand(player, MODULE, "ActionResult", {
            text = text,
            playerOnlineID = player.getOnlineID and player:getOnlineID() or nil,
            playerIndex = player.getPlayerNum and player:getPlayerNum() or 0,
        })
    end)
end

local function sendTeleport(player, target)
    if not player or not target then return end
    pcall(function()
        sendServerCommand(player, MODULE, CMD_TELEPORT, {
            x = target.x,
            y = target.y,
            z = target.z,
            source = target.source or "",
            playerOnlineID = player.getOnlineID and player:getOnlineID() or nil,
            playerIndex = player.getPlayerNum and player:getPlayerNum() or 0,
        })
    end)
end

local function forceServerTeleport(player, target)
    if not player or not target then return end
    pcall(function()
        if player.teleportTo then player:teleportTo(target.x, target.y, target.z) end
    end)
    pcall(function()
        player:setLastX(target.x)
        player:setX(target.x)
        player:setLastY(target.y)
        player:setY(target.y)
        player:setLastZ(target.z)
        player:setZ(target.z)
    end)
end

local function rememberLastSafe(player, target)
    local pmd = playerModData(player)
    if not pmd or not target then return end
    pmd[LAST_SAFE_KEY] = {
        x = target.x,
        y = target.y,
        z = target.z,
        time = nowMs(),
    }
    if player.transmitModData then
        pcall(function() player:transmitModData() end)
    end
end

local function clearProjectRVRoomState(player)
    local pmd = playerModData(player)
    local playerId = pmd and pmd.projectRV_playerId or nil
    if not playerId then return end
    local md = projectRVModData()
    local pdata = md and md.Players and md.Players[playerId] or nil
    if type(pdata) == "table" then
        pdata.ActualRoom = nil
        pdata.RoomType = nil
        pdata.CSRRescuedAt = nowMs()
        if ModData and ModData.transmit then
            pcall(function() ModData.transmit(PROJECT_RV_MODDATA) end)
        end
    end
end

function CSR_RVExitRescueServer.rescue(player)
    if not enabled() then
        sendActionResult(player, "RV emergency exit is disabled")
        return false
    end
    if not playerInRVInterior(player) then
        sendActionResult(player, "Emergency RV exit is only available inside an RV interior")
        return false
    end

    local target = chooseTarget(player)
    if not target then
        sendActionResult(player, "Emergency RV exit failed: no safe return position was found")
        return false
    end

    forceServerTeleport(player, target)
    rememberLastSafe(player, target)
    clearProjectRVRoomState(player)
    sendTeleport(player, target)
    sendActionResult(player, "Emergency RV exit completed")
    print(string.format("[CSR] RV rescue exit for %s -> %.2f, %.2f, %.2f (%s).",
        tostring(player and player.getUsername and player:getUsername() or "?"),
        tonumber(target.x) or 0,
        tonumber(target.y) or 0,
        tonumber(target.z) or 0,
        tostring(target.source or "?")))
    return true
end

local function shouldRecord(player)
    if not player then return false end
    if player.isDead and player:isDead() then return false end
    if playerInRVInterior(player) then return false end
    local target = validTarget(
        player.getX and player:getX() or nil,
        player.getY and player:getY() or nil,
        player.getZ and player:getZ() or 0
    )
    return target
end

local function recordPlayer(player)
    local target = shouldRecord(player)
    if not target then return end
    local pmd = playerModData(player)
    if not pmd then return end
    local prev = pmd[LAST_SAFE_KEY]
    if type(prev) == "table" then
        local dx = (tonumber(prev.x) or 0) - target.x
        local dy = (tonumber(prev.y) or 0) - target.y
        local pz = tonumber(prev.z) or 0
        if (dx * dx + dy * dy) < MIN_MOVE_TO_UPDATE_SQ and pz == target.z then
            return
        end
    end
    rememberLastSafe(player, target)
end

local function recordOnlinePlayers()
    if not enabled() then return end
    local n = nowMs()
    if (n - _lastRecordMs) < RECORD_INTERVAL_MS then return end
    _lastRecordMs = n

    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if players and players.size then
        for i = 0, players:size() - 1 do
            recordPlayer(players:get(i))
        end
        return
    end

    if getPlayer then
        recordPlayer(getPlayer())
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= CMD_REQUEST then return end
    local ok, err = pcall(function()
        CSR_RVExitRescueServer.rescue(player)
    end)
    if not ok then
        print("[CSR] RV rescue exit error: " .. tostring(err))
        sendActionResult(player, "Emergency RV exit failed")
    end
end

if Events then
    if Events.OnClientCommand then Events.OnClientCommand.Add(onClientCommand) end
    if Events.OnTick then Events.OnTick.Add(recordOnlinePlayers) end
end

return CSR_RVExitRescueServer
