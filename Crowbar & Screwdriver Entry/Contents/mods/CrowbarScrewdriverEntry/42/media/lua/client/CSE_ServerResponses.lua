require "CSE_Config"

CSE_ServerResponses = {}

local function resolveLocalPlayer(args)
    local count = getNumActivePlayers and getNumActivePlayers() or 1

    if args and args.playerOnlineID ~= nil then
        local onlineId = tonumber(args.playerOnlineID)
        for i = 0, count - 1 do
            local p = getSpecificPlayer(i)
            if p and onlineId and p:getOnlineID() == onlineId then
                return p
            end
        end
    end

    if args and args.playerIndex ~= nil then
        local p = getSpecificPlayer(tonumber(args.playerIndex) or 0)
        if p then return p end
    end

    return getPlayer()
end

-- Success line -> the sound that sells it.
local SUCCESS_SOUND = {
    ["Got it open!"] = "UnlockDoor",
    ["Unlocked it"] = "UnlockDoor",
    ["Cut through!"] = "MetalGateBreak",
    ["Through the wire!"] = "MetalGateBreak",
}

local FAILURE_MARKERS = {
    "failed", "Ouch", "won't budge", "jammed", "tricky", "impossible",
    "tough", "Almost through", "snap already", "metal is thick",
    "One more try", "leverage",
}

local function isFailureText(text)
    for i = 1, #FAILURE_MARKERS do
        if text:find(FAILURE_MARKERS[i], 1, true) then
            return true
        end
    end
    return false
end

local function onServerCommand(module, command, args)
    if module ~= CSE_Config.MODULE_NAME then return end
    if command ~= "ActionResult" then return end

    local player = resolveLocalPlayer(args)
    if not player or not args or not args.text then return end

    player:Say(args.text)

    local successSound = SUCCESS_SOUND[args.text]
    if successSound then
        player:playSound(successSound)
        player:setHaloNote(args.text, 120, 255, 120, 300)
    elseif isFailureText(args.text) then
        player:setHaloNote(args.text, 255, 80, 80, 300)
    end
end

Events.OnServerCommand.Add(onServerCommand)

return CSE_ServerResponses
