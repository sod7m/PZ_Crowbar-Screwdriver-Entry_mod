if isServer() then return end

require "CSR_FeatureFlags"
require "CSR_AA_InteropGuard"

CSR_RVExitRescueClient = CSR_RVExitRescueClient or {}

local MODULE = "CommonSenseLight"
local CMD_REQUEST = "RVExitRescue"
local CMD_TELEPORT = "RVExitRescueTeleport"

local registered = false

local function tr(key, fallback)
    if getText then
        local s = getText(key)
        if s and s ~= key then return s end
    end
    return fallback or key
end

local function enabled()
    if CSR_FeatureFlags and CSR_FeatureFlags.isRVExitRescueEnabled then
        return CSR_FeatureFlags.isRVExitRescueEnabled()
    end
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    return sb.EnableRVExitRescue ~= false
end

local function projectRVLoaded()
    local mods = getActivatedMods and getActivatedMods() or nil
    if mods and mods.contains then
        if mods:contains("PROJECTRVInterior42") then return true end
        if mods:contains("PROJECTRVInterior") then return true end
    end
    return rawget(_G, "RV_TeleportToRoom") ~= nil
        or rawget(_G, "RV_TeleportToVehicle") ~= nil
end

local function isInRVInterior(playerNum)
    return CSR_AA_InteropGuard
        and CSR_AA_InteropGuard.isInForeignInteriorCell
        and CSR_AA_InteropGuard.isInForeignInteriorCell(playerNum) == true
end

local function notify(player, text, ok)
    if not player or not text or text == "" then return end
    if player.setHaloNote then
        local r, g, b = 220, 220, 220
        if ok == true then
            r, g, b = 120, 255, 120
        elseif ok == false then
            r, g, b = 255, 100, 90
        end
        pcall(function() player:setHaloNote(text, r, g, b, 300) end)
    elseif player.Say then
        pcall(function() player:Say(text) end)
    end
end

local function forceTeleport(player, x, y, z)
    if not player then return end
    pcall(function()
        if player.teleportTo then player:teleportTo(x, y, z) end
    end)
    pcall(function()
        player:setLastX(x)
        player:setX(x)
        player:setLastY(y)
        player:setY(y)
        player:setLastZ(z)
        player:setZ(z)
    end)
    pcall(function()
        if getCell and getCell() and getCell().getGridSquare then
            getCell():getGridSquare(x, y, z)
        end
    end)
end

local function scheduleTeleport(player, args)
    if type(args) ~= "table" then return end
    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z) or 0
    if not x or not y or (x == 0 and y == 0) then return end
    forceTeleport(player, x, y, z)
    local fired = false
    local function lateTick()
        if fired then return end
        fired = true
        if Events and Events.OnTick and Events.OnTick.Remove then
            Events.OnTick.Remove(lateTick)
        end
        forceTeleport(player, x, y, z)
    end
    if Events and Events.OnTick and Events.OnTick.Add then
        Events.OnTick.Add(lateTick)
    end
    notify(player, tr("IGUI_CSR_RVExitRescueDone", "Emergency RV exit completed"), true)
end

local function requestExit(player)
    if not player then return end
    if isClient() then
        sendClientCommand(player, MODULE, CMD_REQUEST, {})
        return
    end
    notify(player, tr("IGUI_CSR_RVExitRescueMPOnly", "Emergency RV exit is handled by the server in multiplayer"), false)
end

local function addContext(playerNum, context, worldobjects, test)
    if test then return end
    if not enabled() then return end
    if not projectRVLoaded() then return end
    if not isInRVInterior(playerNum) then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local option = context:addOption(
        tr("ContextMenu_CSR_RVExitRescue", "Emergency Exit RV"),
        player,
        requestExit
    )
    if option and getTexture then
        local tex = getTexture("media/textures/rvInteriorEnter.png")
        if tex then option.iconTexture = tex end
    end
end

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    if command ~= CMD_TELEPORT then return end

    local player = getPlayer()
    if args and args.playerOnlineID ~= nil and getNumActivePlayers then
        for i = 0, (getNumActivePlayers() or 1) - 1 do
            local p = getSpecificPlayer(i)
            if p and p.getOnlineID and p:getOnlineID() == args.playerOnlineID then
                player = p
                break
            end
        end
    end
    scheduleTeleport(player, args or {})
end

local function init()
    if registered then return end
    if not Events or not Events.OnFillWorldObjectContextMenu then return end
    registered = true
    if CSR_AA_InteropGuard and CSR_AA_InteropGuard.addForeignInteriorContextHandler then
        CSR_AA_InteropGuard.addForeignInteriorContextHandler(addContext)
    else
        Events.OnFillWorldObjectContextMenu.Add(addContext)
    end
end

if Events then
    init()
    if Events.OnGameStart then Events.OnGameStart.Add(init) end
    if Events.OnServerCommand then Events.OnServerCommand.Add(onServerCommand) end
end

return CSR_RVExitRescueClient
