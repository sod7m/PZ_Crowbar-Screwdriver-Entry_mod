require "CSR_Utils"
require "CSR_Config"
require "CSR_KnowledgeData"
require "CSR_FenceData"
require "CSR_DisinfectantUtils"
require "CSR_BathWater"


local function getDWUtils()
    return nil
end

CSR_ServerCommands = {}

local QUIET_COMMAND_LOG = {
    RequestPlayerMarkers = true,
    RequestZombieDensity = true,
    TrunkSpillageTick = true,
    ThrowableThrow = true,
}

local function splitIds(str)
    local result = {}
    if not str or str == "" then return result end
    for v in string.gmatch(str, "[^,]+") do
        result[#result + 1] = tonumber(v)
    end
    return result
end

local function splitStrings(str)
    local result = {}
    if not str or str == "" then return result end
    for v in string.gmatch(str, "[^,]+") do
        result[#result + 1] = v
    end
    return result
end
local recentRequests = {}
local markerRequests = {}
local markerStateCache = {}
local zombieDensityRequests = {}
local zombieDensityStateCache = {}
-- Shared zombie-position list: rebuilt at most once every ZOMBIE_SCAN_SHARE_MS ms,
-- shared across all players to avoid rescanning all objects per-request.
local _zombieScanCache = { time = 0, positions = nil }
local ZOMBIE_SCAN_SHARE_MS = 5000
local knowledgeRecipeInvites = {}
local knowledgeRecipeSessions = {}
local knowledgeLectureSessions = {}

local failStreaks = {}

local PRY_FRUSTRATION = {
    "Pry failed",
    "Come on...",
    "It won't budge!",
    "This is really jammed...",
    "Son of a...",
    "I'm gonna break this thing!",
    "Why won't this OPEN?!",
}

local LOCKPICK_FRUSTRATION = {
    "Lockpick failed",
    "Almost had it...",
    "Slipped again...",
    "This lock is tricky...",
    "Are you kidding me?!",
    "I can't feel the pins!",
    "This is impossible!",
}

local BOLT_CUT_FRUSTRATION = {
    "Bolt cut failed",
    "These are tough...",
    "Almost through!",
    "Come on, snap already!",
    "This metal is thick...",
    "One more try!",
    "I need more leverage!",
}

local function getFrustrationMessage(player, table)
    local id = player and player.getOnlineID and player:getOnlineID() or 0
    failStreaks[id] = (failStreaks[id] or 0) + 1
    local idx = math.min(failStreaks[id], #table)
    return table[idx]
end

local function resetFrustration(player)
    local id = player and player.getOnlineID and player:getOnlineID() or 0
    failStreaks[id] = 0
end

local function sandbox()
    return SandboxVars and SandboxVars.CommonSenseLight or {}
end

local spriteName -- forward declaration (defined at line ~400)

local function sendResult(player, text)
    sendServerCommand(player, "CommonSenseLight", "ActionResult", {
        text = text,
        playerOnlineID = player and player.getOnlineID and player:getOnlineID() or nil,
        playerIndex = player and player.getPlayerNum and player:getPlayerNum() or 0,
    })
end

-- Server-side getText returns the raw key when translations aren't loaded
-- (B42 dedicated server doesn't always have Translate/EN bundles in scope).
-- Use this helper so halo text on the client never shows literal "Tooltip_*".
local function srvText(key, fallback)
    local s = getText and getText(key) or nil
    if not s or s == "" or tostring(s) == key then return fallback end
    return s
end

local function sendOpenAnim(player, obj)
    if not player or not obj or not obj.getSquare then
        return
    end

    local sq = obj:getSquare()
    if not sq then
        return
    end

    local onlineID = player.getOnlineID and player:getOnlineID() or -1
    local playerNum = player.getPlayerNum and player:getPlayerNum() or 0

    sendServerCommand(player, "CommonSenseLight", "DoClientOpenAnim", {
        x = sq:getX(),
        y = sq:getY(),
        z = sq:getZ(),
        objectIndex = obj.getObjectIndex and obj:getObjectIndex() or -1,
        sprite = spriteName(obj) or "",
        playerOnlineID = onlineID,
        playerIndex = playerNum,
    })
end

local function getPlayerRequestKey(player)
    return tostring(player and player.getOnlineID and player:getOnlineID() or "local")
end

local function getNowMs()
    return getTimestampMs and getTimestampMs() or os.time() * 1000
end

local function isFreshRequest(args)
    -- Timestamp freshness check removed: client and dedicated server clocks
    -- are almost never in sync, causing all requests to expire.
    -- Security is enforced by isNearPlayer() distance checks and
    -- requestId deduplication (pruneOldRequests) instead.
    return true
end

local function pruneOldRequests(bucket, nowMs)
    local cutoff = nowMs - CSR_Config.REQUEST_DEDUPE_WINDOW_MS
    for key, entry in pairs(bucket) do
        if not entry or (entry.time or 0) < cutoff then
            bucket[key] = nil
        end
    end
end

local function syncInventoryItem(item)
    if not item then
        return
    end

    if item.transmitModData then
        item:transmitModData()
    end

    -- sendReplaceItemInContainer forces a full item re-sync to the client,
    -- including condition, uses, delta, etc. (vanilla pattern from item.changeRecording)
    local container = item.getContainer and item:getContainer() or nil
    if container and sendReplaceItemInContainer then
        sendReplaceItemInContainer(container, item, item)
    elseif sendItemStats then
        sendItemStats(item)
    end
end

local function syncPlayerInventory(player)
    if not player then return end
    local inv = player:getInventory()
    if inv then
        inv:setDrawDirty(true)
        if inv.setDirtySlots then inv:setDirtySlots(true) end
    end
end

local function isDuplicateRequest(player, command, args)
    local requestId = args and args.requestId or nil
    if not requestId or requestId == "" then
        return false
    end

    local nowMs = getNowMs()
    pruneOldRequests(recentRequests, nowMs)

    local key = table.concat({ getPlayerRequestKey(player), tostring(command), tostring(requestId) }, ":")
    if recentRequests[key] then
        print("[CSR] Duplicate request blocked: " .. tostring(command))
        return true
    end

    recentRequests[key] = { time = nowMs }
    return false
end

local function pruneMarkerCaches(nowMs)
    local requestCutoff = nowMs - math.max(CSR_Config.REQUEST_DEDUPE_WINDOW_MS, CSR_Config.PLAYER_MAP_CACHE_TTL_MS)
    for key, entry in pairs(markerRequests) do
        if not entry or (entry.time or 0) < requestCutoff then
            markerRequests[key] = nil
        end
    end

    local stateCutoff = nowMs - CSR_Config.PLAYER_MAP_CACHE_TTL_MS
    for key, entry in pairs(markerStateCache) do
        if not entry or (entry.time or 0) < stateCutoff then
            markerStateCache[key] = nil
        end
    end

    local densityRequestCutoff = nowMs - math.max(CSR_Config.REQUEST_DEDUPE_WINDOW_MS, CSR_Config.ZOMBIE_DENSITY_CACHE_TTL_MS)
    for key, entry in pairs(zombieDensityRequests) do
        if not entry or (entry.time or 0) < densityRequestCutoff then
            zombieDensityRequests[key] = nil
        end
    end

    local densityStateCutoff = nowMs - CSR_Config.ZOMBIE_DENSITY_CACHE_TTL_MS
    for key, entry in pairs(zombieDensityStateCache) do
        if not entry or (entry.time or 0) < densityStateCutoff then
            zombieDensityStateCache[key] = nil
        end
    end
end

local function pruneKnowledgeState(nowMs)
    local inviteCutoff = nowMs - CSR_Config.KNOWLEDGE_INVITE_TIMEOUT_MS
    for targetId, invite in pairs(knowledgeRecipeInvites) do
        if not invite or (invite.expiry and invite.expiry < nowMs) or (invite.createdAt and invite.createdAt < inviteCutoff) then
            knowledgeRecipeInvites[targetId] = nil
        end
    end

    local sessionCutoff = nowMs - CSR_Config.KNOWLEDGE_SESSION_TIMEOUT_MS
    for teacherId, session in pairs(knowledgeRecipeSessions) do
        if not session or (session.createdAt and session.createdAt < sessionCutoff) then
            knowledgeRecipeSessions[teacherId] = nil
        end
    end

    for teacherId, session in pairs(knowledgeLectureSessions) do
        if not session or (session.createdAt and session.createdAt < sessionCutoff) then
            knowledgeLectureSessions[teacherId] = nil
        end
    end
end

local function getInventoryItems(container)
    if not container or not container.getItems then
        return nil
    end

    return container:getItems()
end

local function findInventoryItemById(player, itemId)
    if not player or not itemId then
        return nil
    end

    local mainInv = player:getInventory()
    if not mainInv then
        return nil
    end

    -- Recursive walk: items can be nested arbitrarily deep (bag-in-bag-in-bag).
    -- The previous one-level search returned nil for any item more than one
    -- container deep, silently breaking every "All" command on stowed items.
    local visited = {}
    local function search(inv)
        if not inv or visited[inv] then return nil end
        visited[inv] = true
        local items = getInventoryItems(inv)
        if not items then return nil end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and item.getID and item:getID() == itemId then
                return item
            end
        end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and instanceof(item, "InventoryContainer") then
                local subInv = item.getInventory and item:getInventory() or nil
                if subInv then
                    local found = search(subInv)
                    if found then return found end
                end
            end
        end
        return nil
    end

    return search(mainInv)
end

local function findOnlinePlayerByID(onlineID)
    if onlineID == nil then
        return nil
    end

    if getPlayerByOnlineID then
        return getPlayerByOnlineID(onlineID)
    end

    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then
        return nil
    end

    for i = 0, players:size() - 1 do
        local candidate = players:get(i)
        if candidate and candidate:getOnlineID() == onlineID then
            return candidate
        end
    end

    return nil
end

local function removeInventoryItem(player, item)
    local container = item and item.getContainer and item:getContainer() or (player and player:getInventory())
    if not container or not item then
        return
    end

    if container.DoRemoveItem then
        container:DoRemoveItem(item)
    else
        container:Remove(item)
    end
    if sendRemoveItemFromContainer then
        sendRemoveItemFromContainer(container, item)
    end
end

local function addItem(container, itemOrType)
    local item = container:AddItem(itemOrType)
    if item and sendAddItemToContainer then
        sendAddItemToContainer(container, item)
    end
    return item
end

local function damageTool(tool, amount)
    if tool and tool.getCondition and tool.setCondition then
        local condition = tool:getCondition() or 0
        tool:setCondition(math.max(0, condition - amount))
    end
end

local function extinguishPlayerFire(player)
    if not player then return end
    local bodyDamage = player.getBodyDamage and player:getBodyDamage() or nil
    if bodyDamage and bodyDamage.setOnFire then bodyDamage:setOnFire(false) end
    if player.setOnFire then player:setOnFire(false) end
    if player.StopBurning then player:StopBurning() end
    if player.stopBurning then player:stopBurning() end

    local sq = player.getSquare and player:getSquare() or nil
    if sq then
        if sq.transmitStopFire then sq:transmitStopFire() end
        if sq.stopFire then sq:stopFire() end
    end
end

local TRUNK_SPILLAGE_CRASH_THRESHOLD = 2
local TRUNK_SPILLAGE_MIN_REQUEST_MS = 350
local trunkSpillageState = setmetatable({}, { __mode = "k" })
local trunkSpillageLastRequest = {}

local function trunkSpillageMaxItemsPerCrash()
    return tonumber(sandbox().TrunkSpillageMaxItemsPerCrash) or 15
end

local function trunkSpillageDriveChanceMultiplier()
    return (tonumber(sandbox().TrunkSpillageDriveChance) or 100) / 100.0
end

local function trunkSpillageMinSpeed()
    return tonumber(sandbox().TrunkSpillageMinSpeed) or 20
end

local function getTrunkContainerPart(vehicle)
    if not vehicle or not vehicle.getPartCount then return nil, nil end
    local n = vehicle:getPartCount()
    for i = 0, n - 1 do
        local part = vehicle:getPartByIndex(i)
        if part and part.getItemContainer then
            local id = tostring(part:getId() or "")
            if id == "TruckBed" or id == "TruckBedOpen"
                    or id == "TrailerTrunk" or id == "TrailerAnimalFood"
                    or string.find(id, "TruckBed", 1, true)
                    or string.find(id, "TrailerTrunk", 1, true) then
                local container = part:getItemContainer()
                if container then return part, container end
            end
        end
    end
    return nil, nil
end

local function isTrunkOpen(vehicle, trunkPart)
    if not vehicle or not trunkPart then return false end
    local id = tostring(trunkPart:getId() or "")
    if id == "TruckBedOpen" or string.find(id, "Open", 1, true) then
        return true
    end
    if not vehicle.getPartCount then return false end
    local n = vehicle:getPartCount()
    for i = 0, n - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then
            local pid = tostring(part:getId() or "")
            if pid == "TrunkDoor" or pid == "DoorRear" or pid == "TrunkDoorOpened"
                    or string.find(pid, "TrunkDoor", 1, true) then
                local door = part.getDoor and part:getDoor() or nil
                if door and door.isOpen and door:isOpen() then return true end
                if not part.getInventoryItem or not part:getInventoryItem() then return true end
                return false
            end
        end
    end
    return false
end

local function getTrunkSpillageState(vehicle)
    if not vehicle then return nil end
    local state = trunkSpillageState[vehicle]
    if not state then
        state = { lastCondition = {} }
        trunkSpillageState[vehicle] = state
    end
    return state
end

local function snapshotVehicleConditions(vehicle, state)
    if not vehicle or not vehicle.getPartCount or not state then return end
    local n = vehicle:getPartCount()
    local nextSnap = {}
    for i = 0, n - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then
            local id = tostring(part:getId() or i)
            nextSnap[id] = part:getCondition() or 100
        end
    end
    state.lastCondition = nextSnap
end

local function detectTrunkCrashSpill(vehicle, state)
    if not vehicle or not vehicle.getPartCount or not state or not state.lastCondition then return 0 end
    local n = vehicle:getPartCount()
    local maxDelta = 0
    for i = 0, n - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then
            local id = tostring(part:getId() or i)
            local prev = state.lastCondition[id]
            if prev then
                local cur = part:getCondition() or 100
                local delta = prev - cur
                if delta > maxDelta then maxDelta = delta end
            end
        end
    end
    if maxDelta < TRUNK_SPILLAGE_CRASH_THRESHOLD then return 0 end
    return math.min(trunkSpillageMaxItemsPerCrash(), math.floor(maxDelta / 2))
end

local function spillOneTrunkItem(vehicle, container)
    if not vehicle or not container or container:isEmpty() then return false end
    local items = container:getItems()
    if not items or items:size() <= 0 then return false end
    local item = items:get(ZombRand(items:size()))
    local square = vehicle:getCurrentSquare()
    if not item or not square then return false end

    removeInventoryItem(nil, item)
    local dx = ZombRand(3) - 1
    local dy = ZombRand(3) - 1
    local target = getCell():getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ()) or square
    target:AddWorldInventoryItem(item, ZombRandFloat(0.0, 0.9), ZombRandFloat(0.0, 0.9), 0.0)
    return true
end

local function processTrunkSpillage(vehicle)
    if not vehicle then return end
    local state = getTrunkSpillageState(vehicle)
    local crashCount = detectTrunkCrashSpill(vehicle, state)
    local trunkPart, container = getTrunkContainerPart(vehicle)

    if trunkPart and container and not container:isEmpty() and isTrunkOpen(vehicle, trunkPart) then
        if crashCount > 0 then
            for _ = 1, crashCount do
                if not spillOneTrunkItem(vehicle, container) then break end
            end
        end

        local speedKmh = math.abs(vehicle:getCurrentSpeedKmHour() or 0)
        if speedKmh >= trunkSpillageMinSpeed() then
            local steering = vehicle.getCurrentSteering and math.abs(vehicle:getCurrentSteering() or 0) or 0
            local chance = steering * (speedKmh / 40.0) * trunkSpillageDriveChanceMultiplier()
            if chance > 0 and ZombRandFloat(0, 1) < chance * 0.05 then
                spillOneTrunkItem(vehicle, container)
            end
        end
    end

    snapshotVehicleConditions(vehicle, state)
end

function CSR_ServerCommands.handleTrunkSpillageTick(player, args)
    if sandbox().EnableTrunkSpillage ~= true then return end
    if not player or (player.isDead and player:isDead()) then return end

    local vehicle = player.getVehicle and player:getVehicle() or nil
    if not vehicle or vehicle:getDriver() ~= player then return end

    local target = args and args.target == "trailer" and "trailer" or "vehicle"
    local key = tostring(player.getOnlineID and player:getOnlineID() or player:getUsername() or "unknown") .. ":" .. target
    local now = getNowMs()
    if trunkSpillageLastRequest[key] and now - trunkSpillageLastRequest[key] < TRUNK_SPILLAGE_MIN_REQUEST_MS then return end
    trunkSpillageLastRequest[key] = now

    if target == "trailer" then
        vehicle = vehicle.getVehicleTowing and vehicle:getVehicleTowing() or nil
    end
    if not vehicle then return end

    processTrunkSpillage(vehicle)
end

function CSR_ServerCommands.handleThrowableThrow(player, args)
    if not player or not args then return end
    if sandbox().EnableThrowableItems == false then return end

    if not isFreshRequest(args) then
        sendResult(player, "Throw request expired")
        return
    end

    local itemId = tonumber(args.itemId)
    if not itemId then
        sendResult(player, "Nothing to throw")
        return
    end

    local item = findInventoryItemById(player, itemId)
    local expectedType = args.itemType and tostring(args.itemType) or nil
    if not item or (expectedType and expectedType ~= "" and item.getFullType and item:getFullType() ~= expectedType) then
        sendResult(player, "Item not found")
        return
    end

    local ok, reason = CSR_Throwables.validatePlayerItem(player, item)
    if not ok then
        sendResult(player, reason or "Cannot throw that")
        return
    end

    local result = CSR_Throwables.performThrow(player, item, args)
    if not result or not result.ok then
        sendResult(player, result and result.reason or "Throw failed")
        return
    end

    if sendServerCommand then
        sendServerCommand("CommonSenseLight", CSR_Throwables.CMD_IMPACT, {
            x = result.x,
            y = result.y,
            z = result.z,
            sound = result.sound,
            broke = result.broke,
            category = result.category,
        })
    end
end

local function toolHasUsableCondition(tool)
    if not tool then
        return false
    end
    if not tool.getCondition then
        return true
    end
    local condition = tool:getCondition()
    return condition == nil or condition > 0
end

local function consumeItemUse(player, item)
    if not item then
        return
    end

    if item.Use then
        item:Use()
    else
        removeInventoryItem(player, item)
    end
end

local function copyCondition(source, dest)
    if source and dest and source.getCondition and dest.setCondition then
        dest:setCondition(source:getCondition())
    end
end

local function getSquare(x, y, z)
    local cell = getCell()
    if not cell then
        return nil
    end
    return cell:getGridSquare(x, y, z)
end

local function iterateSquareObjects(square, fn)
    if not square then
        return
    end

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

spriteName = function(obj)
    local sprite = obj and obj.getSprite and obj:getSprite() or nil
    if sprite and sprite.getName then
        return sprite:getName()
    end
    return nil
end

local function resolveWorldObject(args, player)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end

    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil
    end

    local selected = nil
    local fallback = nil
    iterateSquareObjects(square, function(obj)
        if not fallback and CSR_Utils.isPryTarget(obj) and not CSR_Utils.isBarricadedForPlayer(obj, player) then
            fallback = obj
        end

        if not selected and args.sprite and args.sprite ~= "" and spriteName(obj) == args.sprite and CSR_Utils.isPryTarget(obj) and not CSR_Utils.isBarricadedForPlayer(obj, player) then
            selected = obj
        end
    end)

    if args.objectIndex ~= nil and args.objectIndex >= 0 then
        local objects = square:getObjects()
        if objects and args.objectIndex < objects:size() then
            local obj = objects:get(args.objectIndex)
            if obj and CSR_Utils.isPryTarget(obj) and not CSR_Utils.isBarricadedForPlayer(obj, player) then
                return obj
            end
        end
    end

    if selected then
        return selected
    end

    return fallback
end

local function resolveBoltCutObject(args, player)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end

    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil
    end

    local selected = nil
    local fallback = nil
    iterateSquareObjects(square, function(obj)
        if not fallback and CSR_Utils.isBoltCutterTarget(obj) and not CSR_Utils.isBarricadedForPlayer(obj, player) then
            fallback = obj
        end

        if not selected and args.sprite and args.sprite ~= "" and spriteName(obj) == args.sprite and CSR_Utils.isBoltCutterTarget(obj) and not CSR_Utils.isBarricadedForPlayer(obj, player) then
            selected = obj
        end
    end)

    if args.objectIndex ~= nil and args.objectIndex >= 0 then
        local objects = square:getObjects()
        if objects and args.objectIndex < objects:size() then
            local obj = objects:get(args.objectIndex)
            if obj and CSR_Utils.isBoltCutterTarget(obj) and not CSR_Utils.isBarricadedForPlayer(obj, player) then
                return obj
            end
        end
    end

    if selected then
        return selected
    end

    return fallback
end

local function resolveFenceCutObject(args, player)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end

    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil
    end

    if args.objectIndex ~= nil and args.objectIndex >= 0 then
        local objects = square:getObjects()
        if objects and args.objectIndex < objects:size() then
            local obj = objects:get(args.objectIndex)
            if obj and CSR_Utils.isFenceCutTarget(obj) then
                return obj
            end
        end
    end

    local selected, fallback = nil, nil
    iterateSquareObjects(square, function(obj)
        if not fallback and CSR_Utils.isFenceCutTarget(obj) then
            fallback = obj
        end
        if not selected and args.sprite and args.sprite ~= "" and spriteName(obj) == args.sprite and CSR_Utils.isFenceCutTarget(obj) then
            selected = obj
        end
    end)
    return selected or fallback
end

local function destroyFenceObject(player, target)
    if not target then return false end
    local sq = target.getSquare and target:getSquare() or nil
    if not sq then return false end

    local sprite = target.getSprite and target:getSprite() or nil
    local spriteNameStr = sprite and sprite:getName() or nil
    local drops = CSR_FenceData and CSR_FenceData.getDrops(spriteNameStr) or nil

    if sq.transmitRemoveItemFromSquare then
        sq:transmitRemoveItemFromSquare(target)
    elseif sq.RemoveTileObject then
        sq:RemoveTileObject(target)
    end
    if sq.RecalcProperties then sq:RecalcProperties() end
    if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end

    if drops and player then
        local pSq = player:getCurrentSquare() or sq
        for _, d in ipairs(drops) do
            for _ = 1, (d.count or 1) do
                pSq:AddWorldInventoryItem(d.type, 0, 0, 0)
            end
        end
    end
    return true
end

local function resolveCorpse(args)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end

    local square = getSquare(args.x, args.y, args.z)
    if not square or not square.getStaticMovingObjects then
        return nil
    end

    local corpses = square:getStaticMovingObjects()
    if not corpses then
        return nil
    end

    local fallback = nil
    for i = 0, corpses:size() - 1 do
        local obj = corpses:get(i)
        if obj and instanceof(obj, "IsoDeadBody") then
            if not fallback then
                fallback = obj
            end
            if args.corpseIndex ~= nil and obj.getStaticMovingObjectIndex and obj:getStaticMovingObjectIndex() == args.corpseIndex then
                return obj
            end
        end
    end

    return fallback
end

local function resolveBarricadeWindow(args, player)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end

    local square = getSquare(args.x, args.y, args.z)
    if not square then
        return nil
    end

    if args.objectIndex ~= nil and args.objectIndex >= 0 then
        local objects = square:getObjects()
        if objects and args.objectIndex < objects:size() then
            local obj = objects:get(args.objectIndex)
            if obj and instanceof(obj, "IsoWindow")
                and not CSR_Utils.isBarricadedForPlayer(obj, player)
                and (not obj.isBarricadeAllowed or obj:isBarricadeAllowed()) then
                return obj
            end
        end
    end

    local selected = nil
    iterateSquareObjects(square, function(obj)
        if selected then
            return
        end

        if obj and instanceof(obj, "IsoWindow")
            and not CSR_Utils.isBarricadedForPlayer(obj, player)
            and (not obj.isBarricadeAllowed or obj:isBarricadeAllowed()) then
            if args.sprite and args.sprite ~= "" then
                if spriteName(obj) == args.sprite then
                    selected = obj
                end
            else
                selected = obj
            end
        end
    end)

    return selected
end

local function isNearPlayer(player, args)
    return math.abs(player:getX() - args.x) <= CSR_Config.MAX_WORLD_INTERACT_DISTANCE
        and math.abs(player:getY() - args.y) <= CSR_Config.MAX_WORLD_INTERACT_DISTANCE
        and math.abs(player:getZ() - args.z) <= 1
end

local function arePlayersClose(a, b, maxDistance)
    if not a or not b or a:isDead() or b:isDead() or a:getZ() ~= b:getZ() then
        return false
    end

    local distance = IsoUtils.DistanceTo(a:getX(), a:getY(), b:getX(), b:getY())
    return distance <= (maxDistance or CSR_Config.KNOWLEDGE_RANGE)
end

local function getVehicleByArgs(args)
    if not args or not args.vehicleId then
        return nil
    end
    return getVehicleById and getVehicleById(args.vehicleId) or nil
end

local function addInjury(player, amount)
    local hand = ZombRand(2) == 0 and BodyPartType.Hand_L or BodyPartType.Hand_R
    player:getBodyDamage():AddDamage(hand, amount)
end

local function shouldSendPlayerMarkersTo(requester)
    local mode = sandbox().PlayerMapVisibilityMode or 1
    if sandbox().EnablePlayerMapTracking == false or mode == 3 then
        return false
    end

    if mode == 2 then
        local level = requester.getAccessLevel and requester:getAccessLevel() or ""
        return level == "admin" or level == "moderator" or level == "gm" or level == "overseer"
    end

    return true
end

local function getVisiblePlayersFor(requester)
    local results = {}
    if not shouldSendPlayerMarkersTo(requester) then
        return results
    end

    -- Use getOnlinePlayers() on the server; IsoPlayer.getPlayers() is client-only
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then
        return results
    end

    local function isFiniteWorldCoord(value)
        return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
    end

    for i = 0, players:size() - 1 do
        local other = players:get(i)
        if other and requester ~= other and not other:isDead()
            and isFiniteWorldCoord(other:getX()) and isFiniteWorldCoord(other:getY()) and isFiniteWorldCoord(other:getZ()) then
            table.insert(results, {
                id = other:getOnlineID(),
                username = other:getDisplayName(),
                x = math.floor(other:getX()),
                y = math.floor(other:getY()),
                z = math.floor(other:getZ()),
            })
        end
    end

    return results
end

local function markerKey(player)
    return getPlayerRequestKey(player)
end

local function buildMarkerSignature(players)
    if not players or #players == 0 then
        return "empty"
    end

    local parts = {}
    for i = 1, #players do
        local data = players[i]
        parts[#parts + 1] = table.concat({
            tostring(data.id or ""),
            tostring(data.x or ""),
            tostring(data.y or ""),
            tostring(data.z or ""),
            tostring(data.username or ""),
        }, "|")
    end

    return table.concat(parts, ";")
end

local function buildZombieCellSignature(cells)
    if not cells or #cells == 0 then
        return "empty"
    end

    local parts = {}
    for i = 1, #cells do
        local data = cells[i]
        parts[#parts + 1] = table.concat({
            tostring(data.x or ""),
            tostring(data.y or ""),
            tostring(data.amount or ""),
            tostring(data.density or ""),
        }, "|")
    end

    return table.concat(parts, ";")
end

local function sendMarkerResponse(player, players, requestSeq)
    sendServerCommand(player, "CommonSenseLight", "PlayerMarkers", {
        players = players or {},
        requestSeq = requestSeq or 0,
    })
end

local function sendZombieDensityResponse(player, cells, requestSeq)
    sendServerCommand(player, "CommonSenseLight", "ZombieDensityCells", {
        cells = cells or {},
        requestSeq = requestSeq or 0,
    })
end

function CSR_ServerCommands.handlePlayerMarkerRequest(player, args)
    if not player then
        return
    end

    local playerKey = markerKey(player)
    local nowMs = getNowMs()
    pruneMarkerCaches(nowMs)

    local lastRequest = markerRequests[playerKey]
    if lastRequest and (nowMs - lastRequest.time) < (CSR_Config.PLAYER_MAP_SERVER_MIN_TICKS * 16) then
        local cached = markerStateCache[playerKey]
        if cached then
            sendMarkerResponse(player, cached.players, args and args.requestSeq or 0)
        end
        return
    end

    local players = getVisiblePlayersFor(player)
    local signature = buildMarkerSignature(players)
    local cached = markerStateCache[playerKey]

    markerRequests[playerKey] = { time = nowMs }
    if cached and cached.signature == signature then
        cached.time = nowMs
        sendMarkerResponse(player, cached.players, args and args.requestSeq or 0)
        return
    end

    markerStateCache[playerKey] = {
        time = nowMs,
        signature = signature,
        players = players,
    }
    sendMarkerResponse(player, players, args and args.requestSeq or 0)
end

function CSR_ServerCommands.handleZombieDensityRequest(player, args)
    if not player or sandbox().EnableZombieDensityOverlay == false then
        return
    end

    local playerKey = markerKey(player)
    local nowMs = getNowMs()
    pruneMarkerCaches(nowMs)

    local lastRequest = zombieDensityRequests[playerKey]
    if lastRequest and (nowMs - lastRequest.time) < (CSR_Config.ZOMBIE_DENSITY_SERVER_MIN_TICKS * 16) then
        local cached = zombieDensityStateCache[playerKey]
        if cached then
            sendZombieDensityResponse(player, cached.cells, args and args.requestSeq or 0)
        end
        return
    end

    local cellSize = CSR_Config.ZOMBIE_DENSITY_CELL_SIZE
    -- Server admin can shrink the grid via the ZombieDensityCellRadius sandbox option
    -- to cut both scan area and per-frame client render cost.
    local radius = sandbox().ZombieDensityCellRadius or CSR_Config.ZOMBIE_DENSITY_CELL_RADIUS
    if type(radius) ~= "number" or radius < 1 then radius = CSR_Config.ZOMBIE_DENSITY_CELL_RADIUS end
    if radius > 3 then radius = 3 end
    local baseX = math.floor(player:getX() / cellSize) * cellSize
    local baseY = math.floor(player:getY() / cellSize) * cellSize
    local cellMap = {}

    for dx = -radius, radius do
        for dy = -radius, radius do
            local x = baseX + (dx * cellSize)
            local y = baseY + (dy * cellSize)
            local key = tostring(x) .. "," .. tostring(y)
            cellMap[key] = {
                x = x,
                y = y,
                amount = 0,
                density = 0,
            }
        end
    end

    local cell = player.getCell and player:getCell() or getCell()
    -- Use shared zombie-position cache so the world is sampled at most once every
    -- ZOMBIE_SCAN_SHARE_MS (5 s) across ALL players. The cache is keyed on time only;
    -- in MP the dedicated server's cell holds every loaded zombie, so one scan covers
    -- every connected player.
    local zombiePositions
    if nowMs - _zombieScanCache.time < ZOMBIE_SCAN_SHARE_MS and _zombieScanCache.positions then
        zombiePositions = _zombieScanCache.positions
    else
        -- B42.17 exposes IsoCell:getZombieList() which returns ONLY zombies (~10-200 entries).
        -- The previous code preferred getObjectListForLua() which returns every loaded object
        -- (walls, floors, items, ~50k+) and then filtered with instanceof(IsoZombie) -> 99% of
        -- the work was discarded. Prefer the typed list; fall back to the object list only on
        -- ancient builds that lack it.
        local zombieList = cell and ((cell.getZombieList and cell:getZombieList())
                                     or (cell.getObjectListForLua and cell:getObjectListForLua())) or nil
        local positions = {}
        if zombieList then
            local sz = zombieList:size()
            for i = 0, sz - 1 do
                local zombie = zombieList:get(i)
                -- getZombieList() is already typed; only re-check instanceof on the legacy fallback path.
                if zombie and not zombie:isDead()
                        and (zombieList ~= cell.getObjectListForLua or instanceof(zombie, "IsoZombie")) then
                    positions[#positions + 1] = { x = zombie:getX(), y = zombie:getY() }
                end
            end
        end
        _zombieScanCache = { time = nowMs, positions = positions }
        zombiePositions = positions
    end

    for _, zpos in ipairs(zombiePositions) do
        local zx = math.floor(zpos.x / cellSize) * cellSize
        local zy = math.floor(zpos.y / cellSize) * cellSize
        local key = tostring(zx) .. "," .. tostring(zy)
        local cellData = cellMap[key]
        if cellData then
            cellData.amount = cellData.amount + 1
        end
    end

    local cells = {}
    for _, cellData in pairs(cellMap) do
        if cellData.amount > 60 then
            cellData.density = 3
        elseif cellData.amount > 30 then
            cellData.density = 2
        elseif cellData.amount > 0 then
            cellData.density = 1
        end
        cells[#cells + 1] = cellData
    end

    table.sort(cells, function(a, b)
        if a.y == b.y then
            return a.x < b.x
        end
        return a.y < b.y
    end)

    local signature = buildZombieCellSignature(cells)
    local cached = zombieDensityStateCache[playerKey]
    zombieDensityRequests[playerKey] = { time = nowMs }
    if cached and cached.signature == signature then
        cached.time = nowMs
        sendZombieDensityResponse(player, cached.cells, args and args.requestSeq or 0)
        return
    end

    zombieDensityStateCache[playerKey] = {
        time = nowMs,
        signature = signature,
        cells = cells,
    }
    sendZombieDensityResponse(player, cells, args and args.requestSeq or 0)
end

function CSR_ServerCommands.handlePry(player, args)
    if not player or not args then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Pry request expired")
        return
    end

    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    if sandbox().EnablePrySystem ~= true then
        sendResult(player, "Pry is disabled")
        return
    end

    local crowbar = findInventoryItemById(player, args.crowbarId) or player:getInventory():FindAndReturn("Crowbar")
    local target = resolveWorldObject(args, player)
    local canPry = target and CSR_Utils.canPryWorldTarget(target, player) or false
    if not crowbar or not target or not canPry then
        sendResult(player, "Nothing to pry")
        return
    end

    local success = ZombRandFloat(0, 1) < CSR_Utils.calculatePrySuccess(player, crowbar)
    local noiseMult = sandbox().PryNoiseMultiplier or 1.0

    if success and CSR_Utils.unlockTarget(target, player, false) then
        addSound(player, args.x, args.y, args.z, CSR_Config.BASE_NOISE_RADIUS * noiseMult, 1)
        resetFrustration(player)
        sendResult(player, "Got it open!")
        return
    end

    local wear = math.max(1, math.floor(CSR_Config.TOOL_DAMAGE_ON_FAIL * (sandbox().ToolWearMultiplier or 1.0)))
    damageTool(crowbar, wear)
    addSound(player, args.x, args.y, args.z, CSR_Config.BASE_NOISE_RADIUS * noiseMult * 0.5, 1)

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        addInjury(player, CSR_Config.INJURY_DAMAGE)
        sendResult(player, "Ouch!")
    else
        sendResult(player, getFrustrationMessage(player, PRY_FRUSTRATION))
    end
end

function CSR_ServerCommands.handleBoltCut(player, args)
    if not player or not args then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Bolt cut request expired")
        return
    end

    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    if sandbox().EnableBoltCutter == false or sandbox().EnablePrySystem ~= true then
        sendResult(player, "Bolt cutters disabled")
        return
    end

    local tool = findInventoryItemById(player, args.toolId) or player:getInventory():FindAndReturn("BoltCutters")

    if args.isFence == true then
        if sandbox().EnableFenceCutting == false then
            sendResult(player, "Fence cutting disabled")
            return
        end
        local fence = resolveFenceCutObject(args, player)
        if not tool or not fence then
            sendResult(player, "Nothing to cut")
            return
        end

        local success = ZombRandFloat(0, 1) < CSR_Utils.calculateBoltCutSuccess(player, tool)
        local noiseMult = sandbox().PryNoiseMultiplier or 1.0

        if success and destroyFenceObject(player, fence) then
            addSound(player, args.x, args.y, args.z, CSR_Config.BOLT_CUT_NOISE_RADIUS * noiseMult, 1)
            resetFrustration(player)
            sendResult(player, "Through the wire!")
            return
        end

        local wear = math.max(1, math.floor(CSR_Config.TOOL_DAMAGE_ON_FAIL * (sandbox().ToolWearMultiplier or 1.0)))
        damageTool(tool, wear)
        addSound(player, args.x, args.y, args.z, CSR_Config.BOLT_CUT_NOISE_RADIUS * noiseMult * 0.5, 1)
        if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
            addInjury(player, CSR_Config.INJURY_DAMAGE)
            sendResult(player, "Ouch!")
        else
            sendResult(player, getFrustrationMessage(player, BOLT_CUT_FRUSTRATION))
        end
        return
    end

    local target = resolveBoltCutObject(args, player)
    local canCut = target and CSR_Utils.canBoltCutWorldTarget(target, player) or false
    if not tool or not target or not canCut then
        sendResult(player, "Nothing to cut")
        return
    end

    local success = ZombRandFloat(0, 1) < CSR_Utils.calculateBoltCutSuccess(player, tool)
    local noiseMult = sandbox().PryNoiseMultiplier or 1.0

    if success and CSR_Utils.unlockTarget(target, player, false) then
        addSound(player, args.x, args.y, args.z, CSR_Config.BOLT_CUT_NOISE_RADIUS * noiseMult, 1)
        resetFrustration(player)
        sendResult(player, "Cut through!")
        return
    end

    local wear = math.max(1, math.floor(CSR_Config.TOOL_DAMAGE_ON_FAIL * (sandbox().ToolWearMultiplier or 1.0)))
    damageTool(tool, wear)
    addSound(player, args.x, args.y, args.z, CSR_Config.BOLT_CUT_NOISE_RADIUS * noiseMult * 0.5, 1)

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        addInjury(player, CSR_Config.INJURY_DAMAGE)
        sendResult(player, "Ouch!")
    else
        sendResult(player, getFrustrationMessage(player, BOLT_CUT_FRUSTRATION))
    end
end

function CSR_ServerCommands.handleLockpick(player, args)
    if not player or not args or sandbox().EnableScrewdriverLockpick == false then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Lockpick request expired")
        return
    end

    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    local screwdriver = findInventoryItemById(player, args.screwdriverId)
    if not screwdriver then
        local inv = player:getInventory()
        screwdriver = inv:FindAndReturn("Screwdriver") or inv:FindAndReturn("Screwdriver_Old") or inv:FindAndReturn("Screwdriver_Improvised")
    end
    local isPaperclip = args.isPaperclip == true
    if isPaperclip and not screwdriver then
        screwdriver = player:getInventory():FindAndReturn("Paperclip")
    end
    local target = resolveWorldObject(args, player)
    local canLockpick = target and CSR_Utils.canLockpickWorldTarget(target, player) or false
    if not screwdriver or not target or not canLockpick then
        sendResult(player, "Nothing to lockpick")
        return
    end

    local success = ZombRandFloat(0, 1) < CSR_Utils.calculateLockpickSuccess(player, screwdriver, target)
    local noiseMult = sandbox().LockpickNoiseMultiplier or 0.4
    if success and CSR_Utils.unlockTarget(target, player, false) then
        if isPaperclip then
            removeInventoryItem(player, screwdriver)
        end
        addSound(player, args.x, args.y, args.z, math.max(1, CSR_Config.BASE_NOISE_RADIUS * noiseMult), 1)
        resetFrustration(player)
        sendResult(player, "Unlocked it")
        return
    end

    if not isPaperclip then
        damageTool(screwdriver, 1)
    end
    addSound(player, args.x, args.y, args.z, math.max(1, CSR_Config.BASE_NOISE_RADIUS * noiseMult * 0.5), 1)
    sendResult(player, getFrustrationMessage(player, LOCKPICK_FRUSTRATION))
end

function CSR_ServerCommands.handlePryVehicleDoor(player, args)
    if not player or not args or sandbox().EnableVehicleDoorPry == false then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Pry request expired")
        return
    end

    local crowbar = findInventoryItemById(player, args.crowbarId) or player:getInventory():FindAndReturn("Crowbar")
    local vehicle = getVehicleByArgs(args)
    local part = vehicle and args.partId and vehicle:getPartById(args.partId) or nil
    if not crowbar or not vehicle or not part or not CSR_Utils.canPryVehiclePart(part) then
        sendResult(player, "Nothing to pry")
        return
    end

    -- v1.8.10: prying a claimed vehicle's door is auto-Tier-4.
    if CSR_VehicleClaim and CSR_VehicleClaim.getOwner and CSR_VehicleClaim.isAllowed then
        local _owner = CSR_VehicleClaim.getOwner(vehicle)
        if _owner and _owner ~= "" and not CSR_VehicleClaim.isAllowed(vehicle, player) then
            if CSR_VehicleClaimServerEnforcer and CSR_VehicleClaimServerEnforcer.handleViolation then
                local key = CSR_VehicleClaim.getVehicleKey
                    and CSR_VehicleClaim.getVehicleKey(vehicle, false) or ""
                CSR_VehicleClaimServerEnforcer.handleViolation(player, {
                    vehicleKey = key,
                    kind      = "pry",
                })
            end
            sendResult(player, "Vehicle is claimed")
            return
        end
    end

    if player.DistToSquared and vehicle.getX and vehicle.getY then
        local maxDistance = CSR_Config.MAX_VEHICLE_INTERACT_DISTANCE
        -- Long modded vehicles (W900, PZK semis) have parts far from vehicle:getX/Y.
        -- Measure to the part's own area center when available; fall back to vehicle origin.
        local refX, refY = vehicle:getX(), vehicle:getY()
        if part.getArea and vehicle.getAreaCenter then
            local areaCenter = vehicle:getAreaCenter(part:getArea())
            if areaCenter and areaCenter.getX and areaCenter.getY then
                refX, refY = areaCenter:getX(), areaCenter:getY()
            end
        end
        if player:DistToSquared(refX, refY) > (maxDistance * maxDistance) then
            sendResult(player, "Too far away")
            return
        end
    end

    local success = ZombRandFloat(0, 1) < CSR_Utils.calculatePrySuccess(player, crowbar)
    if success then
        CSR_Utils.unlockVehicleDoorPart(vehicle, part, player, true, true)
        resetFrustration(player)
        sendResult(player, "Got it open!")
        return
    end

    damageTool(crowbar, math.max(1, math.floor(CSR_Config.TOOL_DAMAGE_ON_FAIL * (sandbox().ToolWearMultiplier or 1.0))))
    if sandbox().VehicleWindowShatterChance and ZombRand(100) < sandbox().VehicleWindowShatterChance then
        local windowPart = part.getChildWindow and part:getChildWindow() or vehicle:getClosestWindow(player)
        if windowPart and windowPart.getWindow and windowPart:getWindow() and not windowPart:getWindow():isDestroyed() then
            windowPart:getWindow():damage(windowPart:getWindow():getHealth())
            vehicle:transmitPartWindow(windowPart)
        end
    end

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        addInjury(player, CSR_Config.INJURY_DAMAGE)
        sendResult(player, "Ouch!")
    else
        sendResult(player, getFrustrationMessage(player, PRY_FRUSTRATION))
    end
end

function CSR_ServerCommands.handleLockpickVehicleDoor(player, args)
    if not player or not args or sandbox().EnableScrewdriverLockpick == false then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Lockpick request expired")
        return
    end

    local screwdriver = findInventoryItemById(player, args.screwdriverId)
    if not screwdriver then
        local inv = player:getInventory()
        screwdriver = inv:FindAndReturn("Screwdriver") or inv:FindAndReturn("Screwdriver_Old") or inv:FindAndReturn("Screwdriver_Improvised")
    end
    local vehicle = getVehicleByArgs(args)
    local part = vehicle and args.partId and vehicle:getPartById(args.partId) or nil
    if not screwdriver or not vehicle or not part or not CSR_Utils.canLockpickVehiclePart(part) then
        sendResult(player, "Nothing to lockpick")
        return
    end

    -- v1.8.10: lockpicking a claimed vehicle's door is auto-Tier-4.
    if CSR_VehicleClaim and CSR_VehicleClaim.getOwner and CSR_VehicleClaim.isAllowed then
        local _owner = CSR_VehicleClaim.getOwner(vehicle)
        if _owner and _owner ~= "" and not CSR_VehicleClaim.isAllowed(vehicle, player) then
            if CSR_VehicleClaimServerEnforcer and CSR_VehicleClaimServerEnforcer.handleViolation then
                local key = CSR_VehicleClaim.getVehicleKey
                    and CSR_VehicleClaim.getVehicleKey(vehicle, false) or ""
                CSR_VehicleClaimServerEnforcer.handleViolation(player, {
                    vehicleKey = key,
                    kind      = "lockpick",
                })
            end
            sendResult(player, "Vehicle is claimed")
            return
        end
    end

    if player.DistToSquared and vehicle.getX and vehicle.getY then
        local maxDistance = CSR_Config.MAX_VEHICLE_INTERACT_DISTANCE
        -- Long modded vehicles (W900, PZK semis) have parts far from vehicle:getX/Y.
        -- Measure to the part's own area center when available; fall back to vehicle origin.
        local refX, refY = vehicle:getX(), vehicle:getY()
        if part.getArea and vehicle.getAreaCenter then
            local areaCenter = vehicle:getAreaCenter(part:getArea())
            if areaCenter and areaCenter.getX and areaCenter.getY then
                refX, refY = areaCenter:getX(), areaCenter:getY()
            end
        end
        if player:DistToSquared(refX, refY) > (maxDistance * maxDistance) then
            sendResult(player, "Too far away")
            return
        end
    end

    local success = ZombRandFloat(0, 1) < CSR_Utils.calculateLockpickSuccess(player, screwdriver, part)
    if success then
        CSR_Utils.unlockVehicleDoorPart(vehicle, part, player, true, false)
        resetFrustration(player)
        sendResult(player, "Unlocked it")
        return
    end

    damageTool(screwdriver, 1)
    sendResult(player, getFrustrationMessage(player, LOCKPICK_FRUSTRATION))
end

function CSR_ServerCommands.handleUnHotwireVehicle(player, args)
    if not player or not args then return end
    if sandbox().EnableUnHotwire == false then
        sendResult(player, "Remove hotwire is disabled")
        return
    end
    if not isFreshRequest(args) then
        sendResult(player, "Remove hotwire request expired")
        return
    end

    local vehicle = getVehicleByArgs(args) or (player.getVehicle and player:getVehicle() or nil)
    if not vehicle or (player.getVehicle and player:getVehicle() ~= vehicle) then
        sendResult(player, "Vehicle not found")
        return
    end
    if not vehicle.isDriver or not vehicle:isDriver(player) then
        sendResult(player, "Sit in the driver seat")
        return
    end
    if (vehicle.isEngineRunning and vehicle:isEngineRunning())
            or (vehicle.isEngineStarted and vehicle:isEngineStarted()) then
        sendResult(player, "Turn the engine off first")
        return
    end
    if not (vehicle.isHotwired and vehicle:isHotwired()) then
        sendResult(player, "Hotwire already removed")
        return
    end
    if CSR_VehicleClaim and CSR_VehicleClaim.isClaimed and CSR_VehicleClaim.isClaimed(vehicle)
            and CSR_VehicleClaim.isAllowed and not CSR_VehicleClaim.isAllowed(vehicle, player) then
        sendResult(player, "Vehicle is claimed")
        return
    end

    local screwdriver = findInventoryItemById(player, args.screwdriverId)
    if not screwdriver and CSR_Utils.hasScrewdriver then
        screwdriver = CSR_Utils.hasScrewdriver(player)
    end
    if not screwdriver then
        sendResult(player, "Need a screwdriver")
        return
    end

    if CSR_ServerCommands._clearVehicleHotwire(vehicle) then
        damageTool(screwdriver, 1)
        syncInventoryItem(screwdriver)
        syncPlayerInventory(player)
        sendResult(player, "Hotwire removed")
    else
        sendResult(player, "Hotwire already removed")
    end
end

function CSR_ServerCommands.handleOpenCan(player, args)
    local item = findInventoryItemById(player, args and args.itemId)
    local tool = findInventoryItemById(player, args and args.toolId)
    if not item or not tool or not CSR_Utils.isSupportedCan(item) or not CSR_Utils.isCanOpeningTool(tool) then
        return
    end

    local newType = CSR_Utils.getOpenCanResult(item)
    if not newType then
        return
    end

    local inv = player:getInventory()
    local openedItem = addItem(inv, newType)
    if openedItem then
        copyCondition(item, openedItem)
    end
    removeInventoryItem(player, item)
    damageTool(tool, 1)
    syncInventoryItem(tool)

    local canInjuryChance = sandbox().CanInjuryChance or 0.05
    if CSR_Utils.isKnifeItem(tool) and ZombRandFloat(0, 1) < canInjuryChance then
        addInjury(player, 5)
        sendResult(player, "Ouch! Cut myself opening the can")
    end
end

local CSR_BINKS_DUNG_TYPES = {
    ["Base.Dung_Chicken"] = true, ["Base.Dung_Turkey"] = true, ["Base.Dung_Cow"] = true,
    ["Base.Dung_Deer"] = true, ["Base.Dung_Mouse"] = true, ["Base.Dung_Pig"] = true,
    ["Base.Dung_Rabbit"] = true, ["Base.Dung_Raccoon"] = true, ["Base.Dung_Rat"] = true,
    ["Base.Dung_Sheep"] = true,
}

local function isBinksDungFullType(ft)
    if not ft then return false end
    if CSR_BINKS_DUNG_TYPES[ft] then return true end
    if string.sub(ft, 1, 5) == "Base." then
        local rest = string.sub(ft, 6)
        if string.sub(rest, 1, 5) == "Dung_" then return true end
    end
    return false
end

function CSR_ServerCommands.handleBinksScoopDung(player, args)
    if not player or not args or not args.targets then return end
    if sandbox().EnableBinksScooper == false then return end

    -- Validate the player still holds a Bink's Pooper Scooper.
    local tool = findInventoryItemById(player, args.toolId)
    if not tool or tool:getFullType() ~= "Base.CSR_BinksScooper" then
        return
    end

    local maxCap = tonumber(sandbox().BinksScooperMaxPerAction) or 30
    if maxCap < 1 then maxCap = 1 end
    if maxCap > 60 then maxCap = 60 end
    local clientCap = tonumber(args.maxPerAction) or maxCap
    if clientCap > maxCap then clientCap = maxCap end

    local radius = tonumber(sandbox().BinksScooperRadius) or 3
    if radius < 1 then radius = 1 end
    if radius > 6 then radius = 6 end

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local inv = player:getInventory()
    local cell = getCell()
    if not cell or not inv then return end

    local count = 0
    for _, t in ipairs(args.targets) do
        if count >= clientCap then break end
        if t and t.x and t.y and t.z and t.fullType and isBinksDungFullType(t.fullType) then
            -- Proximity check: within radius+1 of the player.
            if math.abs(t.x - px) <= (radius + 1) and math.abs(t.y - py) <= (radius + 1) and math.abs(t.z - pz) <= 1 then
                local sq = cell:getGridSquare(t.x, t.y, t.z)
                if sq and sq.getWorldObjects then
                    local list = sq:getWorldObjects()
                    if list then
                        for i = list:size() - 1, 0, -1 do
                            local wo = list:get(i)
                            if wo and instanceof(wo, "IsoWorldInventoryObject") then
                                local it = wo.getItem and wo:getItem() or nil
                                if it and it.getFullType and it:getFullType() == t.fullType then
                                    addItem(inv, t.fullType)
                                    if sq.transmitRemoveItemFromSquare then
                                        sq:transmitRemoveItemFromSquare(wo)
                                    end
                                    count = count + 1
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if count > 0 then
        damageTool(tool, 1)
        syncInventoryItem(tool)
        sendResult(player, string.format("Scooped %d", count))
    else
        sendResult(player, "Nothing to scoop")
    end
end

function CSR_ServerCommands.handleIgniteCorpse(player, args)
    if not player or not args or sandbox().EnableCorpseIgnite == false then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Ignite request expired")
        return
    end

    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    local corpse = resolveCorpse(args)
    local ignition = findInventoryItemById(player, args.ignitionId) or CSR_Utils.findPreferredIgnitionSource(player)
    if not corpse or not ignition or not CSR_Utils.hasIgnitionSource(player) then
        sendResult(player, "Need a lighter or matches")
        return
    end

    if player.burnCorpse then
        player:burnCorpse(corpse)
        consumeItemUse(player, ignition)
        syncInventoryItem(ignition)
        sendResult(player, "Corpse ignited")
    end
end

function CSR_ServerCommands.handleStopDropRollExtinguish(player, _args)
    if sandbox().EnableStopDropRoll == false then return end
    if not player or (player.isDead and player:isDead()) then return end
    if player.getVehicle and player:getVehicle() then return end
    extinguishPlayerFire(player)
end

function CSR_ServerCommands.handleBarricadeWindow(player, args)
    if not player or not args then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Barricade request expired")
        return
    end

    if not isNearPlayer(player, args) then
        sendResult(player, "Too far away")
        return
    end

    local window = resolveBarricadeWindow(args, player)
    local plank = findInventoryItemById(player, args.plankId) or CSR_Utils.findPreferredPlank(player)
    if not window or not plank then
        sendResult(player, "Need a plank and a clear window")
        return
    end

    local barricade = IsoBarricade and IsoBarricade.AddBarricadeToObject and IsoBarricade.AddBarricadeToObject(window, player) or nil
    if not barricade then
        sendResult(player, "Cannot barricade that window")
        return
    end

    removeInventoryItem(player, plank)
    barricade:addPlank(player, plank)
    if barricade.getNumPlanks and barricade:getNumPlanks() == 1 and barricade.transmitCompleteItemToClients then
        barricade:transmitCompleteItemToClients()
    elseif barricade.sendObjectChange then
        barricade:sendObjectChange(IsoObjectChange.STATE)
    end

    sendResult(player, "Window barricaded")
end

function CSR_ServerCommands.handleMakeBandage(player, args)
    if not player or not args then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Bandage request expired")
        return
    end

    local item = findInventoryItemById(player, args.itemId)
    local thread = findInventoryItemById(player, args.threadId)
    local needle = findInventoryItemById(player, args.needleId)
    if not item or not thread or not needle or not CSR_Utils.canMakeBandage(item, player) then
        sendResult(player, "Need cloth, thread, and a needle")
        return
    end

    removeInventoryItem(player, item)
    consumeItemUse(player, thread)
    damageTool(needle, 1)
    local bandage = addItem(player:getInventory(), "Base.Bandage")
    syncInventoryItem(thread)
    syncInventoryItem(needle)
    syncInventoryItem(bandage)
    sendResult(player, "Bandage made")
end

function CSR_ServerCommands.handleDisinfectRag(player, args)
    if not player or not args then
        return
    end

    if sandbox().EnableEquipmentQoL == false then
        return
    end

    if not isFreshRequest(args) then
        sendResult(player, "Disinfect request expired")
        return
    end

    local rag = findInventoryItemById(player, tonumber(args.ragId))
    local disinfectant = findInventoryItemById(player, tonumber(args.disinfectantId))
    if not rag or not disinfectant then
        sendResult(player, "Need bandage and disinfectant")
        return
    end

    if args.ragType and rag.getFullType and rag:getFullType() ~= args.ragType then
        sendResult(player, "Bandage changed")
        return
    end
    if args.disinfectantType and disinfectant.getFullType and disinfectant:getFullType() ~= args.disinfectantType then
        sendResult(player, "Disinfectant changed")
        return
    end

    local replacementType = CSR_DisinfectantUtils.getDisinfectedBandageType(rag:getFullType())
    if not replacementType or not CSR_DisinfectantUtils.isDisinfectant(disinfectant) then
        sendResult(player, "Nothing to disinfect")
        return
    end

    local container = rag.getContainer and rag:getContainer() or player:getInventory()
    if not container then return end

    if not CSR_DisinfectantUtils.drainDisinfectant(
        disinfectant,
        CSR_DisinfectantUtils.RAG_DRAIN_AMOUNT
    ) then
        sendResult(player, "Not enough disinfectant")
        return
    end

    removeInventoryItem(player, rag)
    local replacement = addItem(container, replacementType)
    if replacement and rag.copyModData then
        replacement:copyModData(rag:getModData())
    end
    syncInventoryItem(disinfectant)
    syncInventoryItem(replacement)
    syncPlayerInventory(player)
    sendResult(player, "Bandage disinfected")
end

function CSR_ServerCommands.handleOpenJar(player, args)
    local item = findInventoryItemById(player, args and args.itemId)
    if not item or not CSR_Utils.isSupportedJarFood(item) then
        return
    end

    local newType = CSR_Utils.getOpenJarResult(item)
    if not newType then
        return
    end

    local inv = player:getInventory()
    local openedItem = addItem(inv, newType)
    if openedItem then
        copyCondition(item, openedItem)
    end
    removeInventoryItem(player, item)

    local lidType = CSR_Utils.getJarLidType()
    if lidType then
        addItem(inv, lidType)
    end

    sendResult(player, "Jar opened")
end

function CSR_ServerCommands.handleOpenAllJars(player, args)
    local itemIds = splitIds(args and args.itemIdStr)
    local expectedTypes = splitStrings(args and args.expectedTypeStr)
    if #itemIds == 0 then
        print("[CSR] OpenAllJars: no itemIds in args")
        return
    end

    local opened = 0
    local lidType = CSR_Utils.getJarLidType()
    local inv = player:getInventory()
    for idx, itemId in ipairs(itemIds) do
        local item = findInventoryItemById(player, itemId)
        local expectedType = expectedTypes[idx]
        local newType = CSR_Utils.getOpenJarResult(item)
        if item and expectedType and item:getFullType() == expectedType and newType then
            local openedItem = addItem(inv, newType)
            if openedItem then
                copyCondition(item, openedItem)
            end
            removeInventoryItem(player, item)
            if lidType then
                addItem(inv, lidType)
            end
            opened = opened + 1
        end
    end

    if opened > 0 then
        sendResult(player, "Opened " .. opened .. " jars")
    end
end

function CSR_ServerCommands.handleSawAllLogs(player, args)
    local tool = findInventoryItemById(player, args and args.toolId)
    local itemIds = splitIds(args and args.itemIdStr)
    if not tool or #itemIds == 0 then
        print("[CSR] SawAllLogs: invalid args, tool=" .. tostring(tool) .. " ids=" .. tostring(#itemIds))
        return
    end

    local sawed = 0
    local inv = player:getInventory()
    local dropToGround = sandbox().EnableSawAllDropToGround == true
    local square = dropToGround and player:getCurrentSquare() or nil
    for _, itemId in ipairs(itemIds) do
        local item = findInventoryItemById(player, itemId)
        if item and item:getFullType() == "Base.Log" then
            removeInventoryItem(player, item)
            for _ = 1, 3 do
                if dropToGround and square then
                    local plank = instanceItem("Base.Plank")
                    square:AddWorldInventoryItem(plank, 0.0, 0.0, 0.0)
                else
                    addItem(inv, "Base.Plank")
                end
            end
            sawed = sawed + 1
        end
    end

    if sawed > 0 then
        local wear = math.max(1, math.floor(sawed / 3))
        damageTool(tool, wear)
        syncInventoryItem(tool)
        addXp(player, Perks.Woodwork, sawed * 5)
        sendResult(player, "Sawed " .. sawed .. " logs into planks (+" .. (sawed * 5) .. " XP)")
    end
end

local WATCH_TYPES_SERVER = {
    -- B42 standalone clocks
    ["AlarmClock2"] = true,
    ["Pocketwatch"] = true,
    -- B42 wristwatches (digital)
    ["WristWatch_Right_DigitalBlack"] = true,
    ["WristWatch_Left_DigitalBlack"] = true,
    ["WristWatch_Right_DigitalRed"] = true,
    ["WristWatch_Left_DigitalRed"] = true,
    ["WristWatch_Right_DigitalDress"] = true,
    ["WristWatch_Left_DigitalDress"] = true,
    -- B42 wristwatches (analog)
    ["WristWatch_Right_ClassicBlack"] = true,
    ["WristWatch_Left_ClassicBlack"] = true,
    ["WristWatch_Right_ClassicBrown"] = true,
    ["WristWatch_Left_ClassicBrown"] = true,
    ["WristWatch_Right_ClassicMilitary"] = true,
    ["WristWatch_Left_ClassicMilitary"] = true,
    ["WristWatch_Right_ClassicGold"] = true,
    ["WristWatch_Left_ClassicGold"] = true,
    ["WristWatch_Right_Expensive"] = true,
    ["WristWatch_Left_Expensive"] = true,
}

function CSR_ServerCommands.handleDismantleAllWatches(player, args)
    local tool = findInventoryItemById(player, args and args.toolId)
    local itemIds = splitIds(args and args.itemIdStr)
    if not tool or #itemIds == 0 then
        print("[CSR] DismantleAllWatches: invalid args, tool=" .. tostring(tool) .. " ids=" .. tostring(#itemIds))
        return
    end

    local dismantled = 0
    local inv = player:getInventory()
    for _, itemId in ipairs(itemIds) do
        local item = findInventoryItemById(player, itemId)
        if item and WATCH_TYPES_SERVER[item:getType()] then
            removeInventoryItem(player, item)
            addItem(inv, "Base.ElectronicsScrap")
            dismantled = dismantled + 1
        end
    end

    if dismantled > 0 then
        local wear = math.max(1, math.floor(dismantled / 4))
        damageTool(tool, wear)
        syncInventoryItem(tool)
        -- XP awarded server-side (Journals pattern: server-authoritative addXp).
        local xpGained = dismantled * 3
        if addXp and Perks and Perks.Electricity then
            addXp(player, Perks.Electricity, xpGained)
        end
        sendResult(player, "Dismantled " .. dismantled .. " watches (+" .. xpGained .. " XP)")
    end
end

function CSR_ServerCommands.handleOpenAllCans(player, args)
    local tool = findInventoryItemById(player, args and args.toolId)
    local itemIds = splitIds(args and args.itemIdStr)
    local expectedTypes = splitStrings(args and args.expectedTypeStr)
    if not tool or #itemIds == 0 or not CSR_Utils.isCanOpeningTool(tool) then
        print("[CSR] OpenAllCans: invalid args, tool=" .. tostring(tool) .. " ids=" .. tostring(#itemIds))
        return
    end

    local opened = 0
    local canInjuryChance = sandbox().CanInjuryChance or 0.05
    local inv = player:getInventory()
    for idx, itemId in ipairs(itemIds) do
        local item = findInventoryItemById(player, itemId)
        local expectedType = expectedTypes[idx]
        local newType = CSR_Utils.getOpenCanResult(item)
        if item and expectedType and item:getFullType() == expectedType and newType then
            local openedItem = addItem(inv, newType)
            if openedItem then
                copyCondition(item, openedItem)
            end
            removeInventoryItem(player, item)
            opened = opened + 1

            if CSR_Utils.isKnifeItem(tool) and ZombRandFloat(0, 1) < canInjuryChance then
                addInjury(player, 5)
            end
        end
    end

    if opened > 0 then
        damageTool(tool, math.max(1, math.floor(opened / 5)))
        syncInventoryItem(tool)
        sendResult(player, "Opened " .. opened .. " cans")
    end
end

function CSR_ServerCommands.handleOpenAmmoBox(player, args)
    local boxId = args and args.boxId
    local box = findInventoryItemById(player, boxId)
    if not box then
        print("[CSR] OpenAmmoBox: item not found for boxId=" .. tostring(boxId))
        return
    end
    if not CSR_Utils.isAmmoBox(box) then
        print("[CSR] OpenAmmoBox: item is not an ammo box: " .. tostring(box:getFullType()))
        return
    end
    local info = CSR_Utils.getAmmoBoxInfo(box)
    if not info then
        print("[CSR] OpenAmmoBox: no ammo box info for " .. tostring(box:getFullType()))
        return
    end

    local inv = player:getInventory()
    removeInventoryItem(player, box)
    for _ = 1, info.count do
        addItem(inv, info.round)
    end

    sendResult(player, "Opened box: " .. info.count .. " rounds")
end

function CSR_ServerCommands.handleOpenAllAmmoBoxes(player, args)
    local boxIdStr = args and args.boxIdStr or nil
    if not boxIdStr or boxIdStr == "" then
        print("[CSR] OpenAllAmmoBoxes: no boxIdStr in args")
        return
    end
    local boxTypeStr = args and args.boxTypeStr or ""

    local boxIds = {}
    for id in string.gmatch(boxIdStr, "[^,]+") do
        boxIds[#boxIds + 1] = tonumber(id)
    end
    local boxTypeList = {}
    for t in string.gmatch(boxTypeStr, "[^,]+") do
        boxTypeList[#boxTypeList + 1] = t
    end

    print("[CSR] OpenAllAmmoBoxes: processing " .. #boxIds .. " boxes")
    local totalRounds = 0
    local boxCount = 0
    local inv = player:getInventory()
    for idx, boxId in ipairs(boxIds) do
        local box = findInventoryItemById(player, boxId)
        if box and CSR_Utils.isAmmoBox(box) then
            local info = CSR_Utils.getAmmoBoxInfo(box)
            if info then
                removeInventoryItem(player, box)
                for _ = 1, info.count do
                    addItem(inv, info.round)
                end
                totalRounds = totalRounds + info.count
                boxCount = boxCount + 1
            end
        else
            print("[CSR] OpenAllAmmoBoxes: box not found or not ammo box, id=" .. tostring(boxId))
        end
    end
    if totalRounds > 0 then
        sendResult(player, "Opened " .. boxCount .. " boxes: " .. totalRounds .. " rounds")
    else
        print("[CSR] OpenAllAmmoBoxes: no rounds opened from " .. #boxIds .. " boxes")
    end
end

function CSR_ServerCommands.handlePackAmmoBox(player, args)
    if not player or not args then return end
    local roundType = args.roundType
    local boxType = args.boxType
    local perBox = args.perBox
    if not roundType or not boxType or not perBox then return end

    local rounds = CSR_Utils.collectAmmoRounds(player, roundType, perBox)
    if #rounds < perBox then
        sendResult(player, "Not enough rounds to pack")
        return
    end

    for _, round in ipairs(rounds) do
        removeInventoryItem(player, round)
    end
    addItem(player:getInventory(), boxType)
    sendResult(player, "Packed " .. perBox .. " rounds into a box")
end

function CSR_ServerCommands.handlePackAllAmmoBoxes(player, args)
    if not player or not args then
        print("[CSR] PackAllAmmoBoxes: nil player or args")
        return
    end
    local roundType = args.roundType
    local boxType = args.boxType
    local perBox = args.perBox
    if not roundType or not boxType or not perBox then
        print("[CSR] PackAllAmmoBoxes: missing roundType/boxType/perBox: " .. tostring(roundType) .. "/" .. tostring(boxType) .. "/" .. tostring(perBox))
        return
    end

    local totalAvailable = CSR_Utils.countAmmoRoundsOfType(player, roundType)
    local boxesToMake = math.floor(totalAvailable / perBox)
    if boxesToMake < 1 then
        print("[CSR] PackAllAmmoBoxes: not enough rounds, available=" .. tostring(totalAvailable) .. " perBox=" .. tostring(perBox))
        sendResult(player, "Not enough rounds to pack")
        return
    end

    local totalToRemove = boxesToMake * perBox
    local rounds = CSR_Utils.collectAmmoRounds(player, roundType, totalToRemove)
    if #rounds < totalToRemove then
        print("[CSR] PackAllAmmoBoxes: collected " .. #rounds .. " but needed " .. totalToRemove)
        return
    end

    local inv = player:getInventory()
    for _, round in ipairs(rounds) do
        removeInventoryItem(player, round)
    end
    for _ = 1, boxesToMake do
        addItem(inv, boxType)
    end
    sendResult(player, "Packed " .. boxesToMake .. " boxes (" .. totalToRemove .. " rounds)")
end

function CSR_ServerCommands.handleQuickRepair(player, args)
    local itemId = args and args.itemId
    local toolId = args and args.toolId
    local item = findInventoryItemById(player, itemId)
    local tool = findInventoryItemById(player, toolId)
    if not item then
        print("[CSR] QuickRepair: item not found for itemId=" .. tostring(itemId))
        return
    end
    if not tool then
        print("[CSR] QuickRepair: tool not found for toolId=" .. tostring(toolId))
        return
    end
    if not CSR_Utils.isRepairableItem(item) then
        local cond = item.getCondition and item:getCondition() or "?"
        local condMax = item.getConditionMax and item:getConditionMax() or "?"
        print("[CSR] QuickRepair: item not repairable: " .. tostring(item:getFullType()) .. " cond=" .. tostring(cond) .. "/" .. tostring(condMax))
        return
    end
    if tool:getCondition() <= 0 then
        print("[CSR] QuickRepair: tool has no condition")
        return
    end
    if CSR_Utils.isClothingItem(item) then return end
    if CSR_Utils.isQuickRepairTool(item) then
        print("[CSR] QuickRepair: refused -- tool target requires material repair (" .. tostring(item:getFullType()) .. ")")
        sendResult(player, "Tools require a propane torch, scrap metal, and a plank to repair")
        return
    end

    -- v1.8.16: block the same-type self-repair exploit. Two crowbars
    -- (or any pair of identical tools) used to let the player repair
    -- one with the other for net +8 condition per click; swapping
    -- tool/item roles produced infinite condition. The tool must be a
    -- different fullType than the item being repaired.
    if tool == item then
        print("[CSR] QuickRepair: refused -- tool is the item being repaired")
        sendResult(player, "Cannot repair an item with itself")
        return
    end
    if tool.getFullType and item.getFullType
       and tool:getFullType() == item:getFullType() then
        print("[CSR] QuickRepair: refused -- same-type self-repair (" .. tostring(item:getFullType()) .. ")")
        sendResult(player, "Cannot repair an item using another of the same kind")
        return
    end

    local repairAmount = math.min(10, item:getConditionMax() - item:getCondition())
    -- v1.8.16: scale wear with repair amount so a single click can never
    -- have a net-positive condition swap even across different tool
    -- types. Wear is now at least half the repair amount, with the
    -- prior 2-condition floor preserved as a minimum.
    local mult = sandbox().ToolWearMultiplier or 1.0
    local wear = math.max(2, math.ceil(repairAmount * 0.5 * mult))
    item:setCondition(item:getCondition() + repairAmount)
    damageTool(tool, wear)
    syncInventoryItem(item)
    syncInventoryItem(tool)
    syncPlayerInventory(player)
    sendResult(player, "Repaired: +" .. repairAmount .. " condition")
end

function CSR_ServerCommands.handleToolRepair(player, args)
    local item = findInventoryItemById(player, args and args.itemId)
    local torch = findInventoryItemById(player, args and args.torchId)
    local scrap = findInventoryItemById(player, args and args.scrapId)
    local plank = findInventoryItemById(player, args and args.plankId)
    if not item then
        sendResult(player, "Tool not found")
        return
    end
    if not CSR_Utils.isToolRepairTarget(item) then
        sendResult(player, "That tool does not need repair")
        return
    end
    if not torch or not CSR_Utils.hasPropaneTorchFuel(torch, CSR_Utils.getToolRepairTorchFuelCost()) then
        sendResult(player, "Need a propane torch with at least 50% fuel")
        return
    end
    if not scrap or not scrap.getType or scrap:getType() ~= "ScrapMetal" then
        sendResult(player, "Need scrap metal")
        return
    end
    if not plank or not plank.getType or plank:getType() ~= "Plank" then
        sendResult(player, "Need a plank")
        return
    end

    local repairAmount = math.min(10, item:getConditionMax() - item:getCondition())
    if repairAmount <= 0 then return end
    if not CSR_Utils.consumePropaneTorchFuel(torch, CSR_Utils.getToolRepairTorchFuelCost()) then
        sendResult(player, "Need a propane torch with at least 50% fuel")
        return
    end

    item:setCondition(item:getCondition() + repairAmount)
    removeInventoryItem(player, scrap)
    removeInventoryItem(player, plank)
    syncInventoryItem(item)
    syncInventoryItem(torch)
    syncPlayerInventory(player)
    sendResult(player, "Tool repaired: +" .. repairAmount .. " condition")
end

function CSR_ServerCommands.handleMaterialRepair(player, args, amount)
    local item = findInventoryItemById(player, args and args.itemId)
    local material = findInventoryItemById(player, args and args.materialId)
    if not item or not material or not CSR_Utils.isRepairableItem(item) then
        return
    end
    if CSR_Utils.isQuickRepairTool(item) then
        sendResult(player, "Tools require a propane torch, scrap metal, and a plank to repair")
        return
    end

    local repairAmount = math.min(amount, item:getConditionMax() - item:getCondition())
    item:setCondition(item:getCondition() + repairAmount)
    consumeItemUse(player, material)
    syncInventoryItem(item)
    syncInventoryItem(material)
    syncPlayerInventory(player)
    sendResult(player, "Repaired with material")
end

function CSR_ServerCommands.handlePatchClothing(player, args)
    local item = findInventoryItemById(player, args and args.itemId)
    local thread = findInventoryItemById(player, args and args.threadId)
    local needle = findInventoryItemById(player, args and args.needleId)
    local fabric = findInventoryItemById(player, args and args.fabricId)
    if not item or not thread or not needle or not fabric then return end
    if not CSR_Utils.isClothingItem(item) or not CSR_Utils.isRepairableItem(item) then return end

    local repairAmount = math.min(15, item:getConditionMax() - item:getCondition())
    item:setCondition(item:getCondition() + repairAmount)
    consumeItemUse(player, thread)
    damageTool(needle, 1)
    removeInventoryItem(player, fabric)
    syncInventoryItem(item)
    syncInventoryItem(thread)
    syncInventoryItem(needle)
    syncPlayerInventory(player)
    if player.getXp then
        addXp(player, Perks.Tailoring, 3)
    end
    sendResult(player, "Clothing patched")
end

function CSR_ServerCommands.handleRepairAllClothing(player, args)
    if not player then return end
    local inv = player:getInventory()
    if not inv then return end

    local list = CSR_Utils.getDamagedWornClothing(player)
    if #list == 0 then return end

    local processed = 0
    for _, item in ipairs(list) do
        local thread = CSR_Utils.findPreferredThread(player)
        local needle = CSR_Utils.findPreferredNeedle(player)
        local fabric = CSR_Utils.findPreferredFabricMaterial(player)
        if not (thread and needle and fabric) then break end

        item:setCondition(item:getConditionMax())

        if item.getCoveredParts and item.getPatchType and item.removePatch then
            local parts = item:getCoveredParts()
            if parts and parts.size then
                for i = 0, parts:size() - 1 do
                    local part = parts:get(i)
                    if part and item:getPatchType(part) ~= nil then
                        item:removePatch(part)
                    end
                end
            end
        end

        consumeItemUse(player, thread)
        damageTool(needle, 1)
        removeInventoryItem(player, fabric)
        syncInventoryItem(item)
        syncInventoryItem(thread)
        syncInventoryItem(needle)
        processed = processed + 1
    end

    if processed > 0 then
        syncPlayerInventory(player)
        if player.getXp then
            addXp(player, Perks.Tailoring, 3 * processed)
        end
        sendResult(player, "Repaired " .. processed .. " garment(s)")
    end
end

function CSR_ServerCommands.handleTearCloth(player, args)
    local item = findInventoryItemById(player, args and args.itemId)
    local expectedType = args and args.expectedType or nil
    local tearInfo = CSR_Utils.getTearClothInfo(item)
    if not item or not expectedType or item:getFullType() ~= expectedType or not tearInfo then
        return
    end

    local tool = findInventoryItemById(player, args and args.toolId)
    if tearInfo.requiresTool and (not tool or not CSR_Utils.isClothCuttingTool(tool) or not toolHasUsableCondition(tool)) then
        return
    end

    local inv = player:getInventory()
    removeInventoryItem(player, item)
    for _ = 1, tearInfo.quantity do
        addItem(inv, tearInfo.outputType)
    end
    if tearInfo.threadChance and ZombRand and ZombRand(100) < tearInfo.threadChance then
        addItem(inv, "Base.Thread")
    end
    if tool then
        damageTool(tool, 1)
        syncInventoryItem(tool)
    end
    sendResult(player, "Tore clothing into usable material")
end

function CSR_ServerCommands.handleTearAllCloth(player, args)
    local itemIds = splitIds(args and args.itemIdStr)
    local expectedTypes = splitStrings(args and args.expectedTypeStr)
    local outputTypes = splitStrings(args and args.outputTypeStr)
    local quantities = splitStrings(args and args.quantityStr)
    if #itemIds == 0 then
        print("[CSR] TearAllCloth: no itemIds in args")
        return
    end

    local tool = findInventoryItemById(player, args and args.toolId)
    local torn = 0
    for idx, itemId in ipairs(itemIds) do
        local item = findInventoryItemById(player, itemId)
        local expectedType = expectedTypes[idx]
        local expectedOutput = outputTypes[idx]
        local expectedQuantity = tonumber(quantities[idx] or 0) or 0
        local tearInfo = CSR_Utils.getTearClothInfo(item)
        if item and expectedType and item:getFullType() == expectedType and tearInfo and tearInfo.outputType == expectedOutput and tearInfo.quantity == expectedQuantity then
            if tearInfo.requiresTool and (not tool or not CSR_Utils.isClothCuttingTool(tool) or not toolHasUsableCondition(tool)) then
                break
            end
            removeInventoryItem(player, item)
            for _ = 1, tearInfo.quantity do
                addItem(player:getInventory(), tearInfo.outputType)
            end
            if tearInfo.threadChance and ZombRand and ZombRand(100) < tearInfo.threadChance then
                addItem(player:getInventory(), "Base.Thread")
            end
            torn = torn + 1
        end
    end

    if torn > 0 then
        if tool then
            damageTool(tool, math.max(1, math.floor(torn / 3)))
            syncInventoryItem(tool)
        end
        sendResult(player, "Tore " .. torn .. " clothing items into material")
    end
end

function CSR_ServerCommands.handleReplaceBattery(player, args)
    local item = findInventoryItemById(player, args and args.itemId)
    local battery = findInventoryItemById(player, args and args.batteryId)
    if not item or not battery or not CSR_Utils.canRechargeFlashlight(item) or battery:getType() ~= "Battery" then
        return
    end

    item:setDelta(1.0)
    removeInventoryItem(player, battery)
    syncInventoryItem(item)
    syncPlayerInventory(player)
    sendResult(player, "Battery replaced")
end

function CSR_ServerCommands.handleRefillLighter(player, args)
    local lighter = findInventoryItemById(player, args and args.itemId)
    local fluid = findInventoryItemById(player, args and args.fluidId)
    if not lighter or not fluid or not CSR_Utils.canRefillLighter(lighter) or fluid:getType() ~= "LighterFluid" or not fluid.getDelta then
        return
    end

    local current = lighter:getDelta()
    local available = fluid:getDelta()
    local needed = 1.0 - current
    local transfer = math.min(needed, available)

    lighter:setDelta(math.min(1.0, current + transfer))
    fluid:setDelta(math.max(0.0, available - transfer))
    if fluid:getDelta() <= 0 then
        removeInventoryItem(player, fluid)
    end

    syncInventoryItem(lighter)
    syncInventoryItem(fluid)
    sendResult(player, "Lighter refilled")
end

function CSR_ServerCommands.handleClipboardAddPaper(player, args)
    if not isFreshRequest(args) then
        return
    end

    local item = findInventoryItemById(player, args and args.itemId)
    local paper = player and player:getInventory() and player:getInventory():FindAndReturn("SheetPaper2") or nil
    if not item or not paper or not CSR_Utils.isClipboard(item) then
        return
    end

    local data = CSR_Utils.getClipboardData(item)
    if not data or data.paperAmount >= 5 then
        return
    end

    data.paperAmount = data.paperAmount + 1
    removeInventoryItem(player, paper)
    syncInventoryItem(item)
    sendResult(player, "Added paper to clipboard")
end

function CSR_ServerCommands.handleClipboardRemovePaper(player, args)
    if not isFreshRequest(args) then
        return
    end

    local item = findInventoryItemById(player, args and args.itemId)
    if not item or not CSR_Utils.isClipboard(item) then
        return
    end

    local data = CSR_Utils.getClipboardData(item)
    if not data or data.paperAmount <= 0 then
        return
    end

    data.paperAmount = data.paperAmount - 1
    local maxEntries = data.paperAmount * 6
    for i = #data.entries, maxEntries + 1, -1 do
        data.entries[i] = nil
    end
    addItem(player:getInventory(), "Base.SheetPaper2")
    syncInventoryItem(item)
    sendResult(player, "Removed paper from clipboard")
end

function CSR_ServerCommands.handleClipboardSave(player, args)
    if not isFreshRequest(args) then
        return
    end

    local item = findInventoryItemById(player, args and args.itemId)
    if not item or not CSR_Utils.isClipboard(item) then
        return
    end

    local data = CSR_Utils.getClipboardData(item)
    if not data then
        return
    end

    local title = tostring(args and args.title or data.title or "Clipboard")
    title = title:gsub("[%c]", ""):sub(1, 48)
    if title == "" then
        title = "Clipboard"
    end

    local paperAmount = data.paperAmount or 0
    local maxEntries = paperAmount * 6
    local entryTextsStr = args and args.entryTextsStr or ""
    local entryCheckedStr = args and args.entryCheckedStr or ""

    local entryTexts = {}
    if entryTextsStr ~= "" then
        for text in string.gmatch(entryTextsStr .. "\n", "(.-)\n") do
            entryTexts[#entryTexts + 1] = text
        end
    end

    local checkedSet = {}
    for idx in string.gmatch(entryCheckedStr, "[^,]+") do
        checkedSet[tonumber(idx)] = true
    end

    local entries = {}
    for i = 1, math.min(maxEntries, #entryTexts) do
        local text = tostring(entryTexts[i] or ""):gsub("[%c]", " "):sub(1, 64)
        entries[i] = {
            text = text,
            checked = checkedSet[i] == true,
        }
    end

    data.title = title
    data.entries = entries
    if item.setCustomName then
        item:setCustomName(true)
    end
    item:setName("Clipboard: " .. title)
    syncInventoryItem(item)
    sendResult(player, "Clipboard updated")
end

function CSR_ServerCommands.handleKnowledgeRecipeInvite(player, args)
    if not isFreshRequest(args) then
        return
    end

    local recipeData = CSR_KnowledgeData.getRecipe(args and args.recipeKey)
    local target = findOnlinePlayerByID(args and args.targetID)
    if not recipeData or not target or target == player or not arePlayersClose(player, target, CSR_Config.KNOWLEDGE_RANGE) then
        return
    end

    local canTeach = CSR_KnowledgeData.canTeachRecipe(player, target, recipeData)
    if not canTeach then
        sendResult(player, "Cannot teach that recipe right now")
        return
    end

    local targetId = target:getOnlineID()
    knowledgeRecipeInvites[targetId] = {
        teacherID = player:getOnlineID(),
        recipeKey = recipeData.key,
        createdAt = getNowMs(),
        expiry = getNowMs() + CSR_Config.KNOWLEDGE_INVITE_TIMEOUT_MS,
    }

    sendServerCommand(target, "CommonSenseLight", "KnowledgeRecipeInvite", {
        teacherID = player:getOnlineID(),
        teacherName = player:getUsername(),
        recipeKey = recipeData.key,
        recipeName = recipeData.displayName,
    })
    sendResult(player, "Teaching offer sent")
end

function CSR_ServerCommands.handleKnowledgeRecipeRespond(player, args)
    if not isFreshRequest(args) then
        return
    end

    local invite = knowledgeRecipeInvites[player:getOnlineID()]
    if not invite or invite.teacherID ~= (args and args.teacherID) or invite.recipeKey ~= (args and args.recipeKey) then
        return
    end

    knowledgeRecipeInvites[player:getOnlineID()] = nil

    local teacher = findOnlinePlayerByID(invite.teacherID)
    local recipeData = CSR_KnowledgeData.getRecipe(invite.recipeKey)
    if not teacher or not recipeData or invite.expiry < getNowMs() or not arePlayersClose(teacher, player, CSR_Config.KNOWLEDGE_RANGE) then
        return
    end

    if args and args.accept ~= true then
        sendResult(teacher, player:getUsername() .. " declined the lesson")
        return
    end

    local canTeach = CSR_KnowledgeData.canTeachRecipe(teacher, player, recipeData)
    if not canTeach then
        sendResult(teacher, "That lesson is no longer valid")
        return
    end

    local sessionId = table.concat({ "recipe", tostring(teacher:getOnlineID()), tostring(player:getOnlineID()), tostring(getNowMs()) }, ":")
    knowledgeRecipeSessions[teacher:getOnlineID()] = {
        sessionId = sessionId,
        targetID = player:getOnlineID(),
        recipeKey = recipeData.key,
        createdAt = getNowMs(),
    }

    sendServerCommand(teacher, "CommonSenseLight", "KnowledgeRecipeStart", {
        sessionId = sessionId,
        targetID = player:getOnlineID(),
        targetName = player:getUsername(),
        recipeKey = recipeData.key,
        recipeName = recipeData.displayName,
    })
    sendResult(player, "Lesson accepted")
end

function CSR_ServerCommands.handleKnowledgeRecipeComplete(player, args)
    if not isFreshRequest(args) then
        return
    end

    local session = knowledgeRecipeSessions[player:getOnlineID()]
    local recipeData = CSR_KnowledgeData.getRecipe(args and args.recipeKey)
    if not session or not recipeData or session.sessionId ~= (args and args.sessionId) or session.recipeKey ~= recipeData.key then
        return
    end

    knowledgeRecipeSessions[player:getOnlineID()] = nil

    local target = findOnlinePlayerByID(session.targetID)
    if not target or not arePlayersClose(player, target, CSR_Config.KNOWLEDGE_RANGE) then
        sendResult(player, "Lesson failed: student moved away")
        return
    end

    local canTeach = CSR_KnowledgeData.canTeachRecipe(player, target, recipeData)
    if not canTeach then
        sendResult(player, "Lesson failed: requirements changed")
        return
    end

    target:learnRecipe(recipeData.recipe)
    sendResult(player, "Taught " .. target:getUsername() .. " " .. recipeData.displayName)
    sendResult(target, player:getUsername() .. " taught you " .. recipeData.displayName)
end

function CSR_ServerCommands.handleKnowledgeRecipeCancel(player, args)
    local session = knowledgeRecipeSessions[player:getOnlineID()]
    if not session or session.sessionId ~= (args and args.sessionId) then
        return
    end

    knowledgeRecipeSessions[player:getOnlineID()] = nil
end

function CSR_ServerCommands.handleKnowledgeLectureStart(player, args)
    if not isFreshRequest(args) then
        return
    end

    local lectureData = CSR_KnowledgeData.getLecture(args and args.lectureKey)
    local canTeach = CSR_KnowledgeData.canGiveLecture(player, lectureData)
    if not lectureData or not canTeach then
        return
    end

    knowledgeLectureSessions[player:getOnlineID()] = {
        sessionId = args and args.sessionId,
        lectureKey = lectureData.key,
        createdAt = getNowMs(),
        lastPulseMs = 0,
        listeners = {},
    }
end

function CSR_ServerCommands.handleKnowledgeLecturePulse(player, args)
    if not isFreshRequest(args) then
        return
    end

    local session = knowledgeLectureSessions[player:getOnlineID()]
    local lectureData = CSR_KnowledgeData.getLecture(args and args.lectureKey)
    if not session or not lectureData or session.sessionId ~= (args and args.sessionId) or session.lectureKey ~= lectureData.key then
        return
    end

    local nowMs = getNowMs()
    if session.lastPulseMs > 0 and (nowMs - session.lastPulseMs) < CSR_Config.KNOWLEDGE_LECTURE_MIN_PULSE_MS then
        return
    end

    local canTeach = CSR_KnowledgeData.canGiveLecture(player, lectureData)
    if not canTeach then
        knowledgeLectureSessions[player:getOnlineID()] = nil
        return
    end

    session.lastPulseMs = nowMs

    -- v1.8.34: pulses now only track which students are listening; the actual
    -- skill grant happens on Stop (one full level per completed share, capped
    -- at teacher's level - 1). This replaces the old XP-trickle scaling that
    -- the user found unsatisfying.
    local perk = Perks.FromString(lectureData.perkName)
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then
        return
    end

    for i = 0, players:size() - 1 do
        local student = players:get(i)
        if student and student ~= player and arePlayersClose(player, student, CSR_Config.KNOWLEDGE_RANGE) then
            if not session.listeners[student:getOnlineID()] then
                session.listeners[student:getOnlineID()] = true
                sendResult(student, "Learning from " .. player:getUsername() .. "'s " .. lectureData.displayName .. " lecture")
            end
        end
    end
end

function CSR_ServerCommands.handleKnowledgeLectureStop(player, args)
    local session = knowledgeLectureSessions[player:getOnlineID()]
    if not session or session.sessionId ~= (args and args.sessionId) then
        return
    end

    -- v1.8.34: grant +1 perk level per completed share, capped at teacher level - 1.
    local lectureData = CSR_KnowledgeData.getLecture(session.lectureKey)
    if lectureData and session.listeners then
        local perk = Perks.FromString(lectureData.perkName)
        if perk then
            local teacherLevel = player:getPerkLevel(perk) or 0
            local topLevel = math.max(0, teacherLevel - 1)
            local players = getOnlinePlayers and getOnlinePlayers() or nil
            if players then
                for i = 0, players:size() - 1 do
                    local student = players:get(i)
                    if student and student ~= player and session.listeners[student:getOnlineID()] then
                        if arePlayersClose(player, student, CSR_Config.KNOWLEDGE_RANGE) then
                            local cur = student:getPerkLevel(perk) or 0
                            if cur < topLevel then
                                local newLvl = cur + 1
                                student:getXp():setXPToLevel(perk, newLvl)
                                sendResult(student, lectureData.displayName .. " skill increased to level " .. newLvl)
                            end
                        end
                    end
                end
            end
        end
    end

    knowledgeLectureSessions[player:getOnlineID()] = nil
end

-- =============================================
-- SAFEHOUSE CLAIMING
-- =============================================

local function sendSafehouseClaimResult(player, success, text)
    sendServerCommand(player, "CommonSenseLight", "SafehouseClaimResult", {
        success = success,
        text = text,
    })
end

function CSR_ServerCommands.handleClaimSafehouse(player, args)
    if not CSR_SafehouseClaim.isEnabled() then
        sendSafehouseClaimResult(player, false, "Multiple safehouse claiming is disabled")
        return
    end
    if not args or args.x == nil or args.y == nil or args.w == nil or args.h == nil then
        sendSafehouseClaimResult(player, false, "Invalid building data")
        return
    end

    local username = player:getUsername()
    local x, y, w, h = args.x, args.y, args.w, args.h

    -- Check if already claimed
    local existing = CSR_SafehouseClaim.findSafehouseAt(x, y, w, h)
    if existing then
        sendSafehouseClaimResult(player, false, "Building already claimed")
        return
    end

    -- Check claim count
    local count = CSR_SafehouseClaim.getOwnerCount(username)
    local max = CSR_SafehouseClaim.getMaxClaims()
    if count >= max then
        sendSafehouseClaimResult(player, false, "Max safehouses claimed (" .. max .. ")")
        return
    end

    -- Validation passed — send approval to client so it calls sendSafehouseClaim natively.
    -- Calling SafeHouse.addSafeHouse() server-side produces SafezoneClaimPacket with
    -- playerIndex:-1 which Java's isConsistent() check rejects, so clients never receive
    -- ownership. The vanilla flow requires the packet to originate from the client.
    sendServerCommand(player, "CommonSenseLight", "SafehouseClaimApproved", {
        x = x, y = y, w = w, h = h,
    })
end

function CSR_ServerCommands.handleReleaseSafehouse(player, args)
    if not CSR_SafehouseClaim.isEnabled() then
        sendSafehouseClaimResult(player, false, "Multiple safehouse claiming is disabled")
        return
    end
    if not args or args.x == nil or args.y == nil or args.w == nil or args.h == nil then
        sendSafehouseClaimResult(player, false, "Invalid safehouse data")
        return
    end

    local username = player:getUsername()
    local access = player:getAccessLevel()
    local isAdmin = access and (access == "admin" or access == "Admin")

    local house = CSR_SafehouseClaim.findSafehouseAt(args.x, args.y, args.w, args.h)
    if not house then
        sendSafehouseClaimResult(player, false, "Safehouse not found")
        return
    end
    if house:getOwner() ~= username and not isAdmin then
        sendSafehouseClaimResult(player, false, "Not your safehouse")
        return
    end

    if SafeHouse.removeSafeHouse then
        SafeHouse.removeSafeHouse(house)
    else
        local players = house:getPlayers()
        if players and players.clear then players:clear() end
        SafeHouse.getSafehouseList():remove(house)
    end

    -- Verify the house is actually gone before reporting success
    local stillExists = CSR_SafehouseClaim.findSafehouseAt(args.x, args.y, args.w, args.h)
    if stillExists then
        sendSafehouseClaimResult(player, false, "Failed to remove safehouse")
        return
    end

    sendSafehouseClaimResult(player, true, "Safehouse released")
end

-- =============================================
-- FACTION SAFEHOUSE CLAIMING
-- =============================================

-- In-memory registry: factionName → list of {x, y, w, h}
-- Rebuilt from SafeHouse modData on server start.
local _factionSafehouseRegistry = {}

-- Pending modData tag retries: {factionName, x, y, w, h, attempts}
local _pendingFactionTags = {}

local function broadcastFactionSafehouseEvent(event, payload)
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then sendServerCommand(p, MODULE, event, payload) end
    end
end

function CSR_ServerCommands.handleClaimFactionSafehouse(player, args)
    if not CSR_SafehouseClaim.isFactionSafehouseEnabled() then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Faction safehouse claiming is disabled" })
        return
    end
    if not args or args.x == nil or args.y == nil or args.w == nil or args.h == nil
       or not args.factionName then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Invalid data" })
        return
    end

    local username  = player:getUsername()
    local x, y, w, h = args.x, args.y, args.w, args.h
    local factionName = args.factionName

    -- Validate faction ownership
    local faction = Faction.getFaction(factionName)
    if not faction or not faction:isOwner(username) then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Not the faction owner" })
        return
    end

    -- Building must not already be claimed
    local existing = CSR_SafehouseClaim.findSafehouseAt(x, y, w, h)
    if existing then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Building already claimed as a safehouse" })
        return
    end

    -- Enforce faction safehouse cap
    local count = CSR_SafehouseClaim.getFactionSafehouseCount(factionName)
    local max   = CSR_SafehouseClaim.getMaxFactionSafehouses()
    if count >= max then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Faction safehouse limit reached (" .. max .. ")" })
        return
    end

    -- Enriched validation (spawn protection, residential check, padding).
    -- Returns false only when one of the configured rules is actively violated.
    local validOk, validErr = CSR_FactionClaimValidation.canClaim(x, y, w, h, factionName)
    if not validOk then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = validErr or "Validation failed" })
        return
    end

    -- Approved — add to in-memory registry
    _factionSafehouseRegistry[factionName] = _factionSafehouseRegistry[factionName] or {}
    table.insert(_factionSafehouseRegistry[factionName], { x = x, y = y, w = w, h = h })

    -- Tell the owner's client to call sendSafehouseClaim() (same reason as personal claims)
    sendServerCommand(player, MODULE, "FactionSafehouseClaimApproved",
        { x = x, y = y, w = w, h = h, factionName = factionName })

    -- Broadcast registry update to all clients so context menus stay in sync
    broadcastFactionSafehouseEvent("FactionSafehouseRegistered",
        { factionName = factionName, x = x, y = y, w = w, h = h })
end

-- Called by the owner's client 1 second after sendSafehouseClaim() to tag the
-- newly-created SafeHouse object with csrFactionOwner in its modData.
function CSR_ServerCommands.handleFactionSafehouseTag(player, args)
    if not args or args.x == nil or not args.factionName then return end
    local username = player:getUsername()
    local faction  = Faction.getFaction(args.factionName)
    if not faction or not faction:isOwner(username) then return end

    local sh = CSR_SafehouseClaim.findSafehouseAt(args.x, args.y, args.w or 10, args.h or 10)
    if sh then
        sh:getModData().csrFactionOwner = args.factionName
        if sh.transmitModData then sh:transmitModData() end
    else
        -- Safehouse may not be committed yet; queue a retry via EveryOneMinute
        table.insert(_pendingFactionTags, {
            factionName = args.factionName,
            x = args.x, y = args.y,
            w = args.w or 10, h = args.h or 10,
            attempts = 0,
        })
    end
end

function CSR_ServerCommands.handleReleaseFactionSafehouse(player, args)
    if not CSR_SafehouseClaim.isFactionSafehouseEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.w == nil or args.h == nil
       or not args.factionName then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Invalid data" })
        return
    end

    local username    = player:getUsername()
    local factionName = args.factionName
    local x, y, w, h = args.x, args.y, args.w, args.h

    -- Faction owner or admin may release
    local faction = Faction.getFaction(factionName)
    local isOwner = faction and faction:isOwner(username)
    local adminOk = false
    local access = player.getAccessLevel and player:getAccessLevel() or nil
    adminOk = access and (access == "admin" or access == "Admin")
    if not isOwner and not adminOk then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Not authorized to release this faction safehouse" })
        return
    end

    local house = CSR_SafehouseClaim.findSafehouseAt(x, y, w, h)
    if not house then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Faction safehouse not found" })
        return
    end

    -- Clear the faction tag from modData
    house:getModData().csrFactionOwner = nil
    if house.transmitModData then house:transmitModData() end

    -- Remove the safehouse (same pattern as personal release)
    if SafeHouse.removeSafeHouse then
        SafeHouse.removeSafeHouse(house)
    else
        local players = house:getPlayers()
        if players and players.clear then players:clear() end
        SafeHouse.getSafehouseList():remove(house)
    end

    local stillExists = CSR_SafehouseClaim.findSafehouseAt(x, y, w, h)
    if stillExists then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Failed to release faction safehouse" })
        return
    end

    -- Remove from in-memory registry
    if _factionSafehouseRegistry[factionName] then
        for i = #_factionSafehouseRegistry[factionName], 1, -1 do
            local e = _factionSafehouseRegistry[factionName][i]
            if e.x == x and e.y == y then
                table.remove(_factionSafehouseRegistry[factionName], i)
            end
        end
    end

    sendServerCommand(player, MODULE, "FactionSafehouseResult",
        { success = true, text = "Faction safehouse released" })
    broadcastFactionSafehouseEvent("FactionSafehouseReleased",
        { factionName = factionName, x = x, y = y, w = w, h = h })
end

-- Sends the full faction safehouse registry to a newly-connected client.
function CSR_ServerCommands.handleGetFactionSafehouseRegistry(player, args)
    for factionName, entries in pairs(_factionSafehouseRegistry) do
        for _, e in ipairs(entries) do
            sendServerCommand(player, MODULE, "FactionSafehouseRegistered",
                { factionName = factionName, x = e.x, y = e.y, w = e.w, h = e.h })
        end
    end
end

-- ----------------------------------------------------------------------------
-- Transfer a faction safehouse from one faction to another.
-- Caller must be the owner of the SOURCE faction or an admin.
-- The DEST faction must exist and the caller must be its owner (or admin).
-- ----------------------------------------------------------------------------
function CSR_ServerCommands.handleTransferFactionSafehouse(player, args)
    if not CSR_SafehouseClaim.isFactionSafehouseEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.w == nil or args.h == nil
       or not args.fromFaction or not args.toFaction then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Invalid transfer data" }); return
    end
    local username = player:getUsername()
    local fromFac = Faction.getFaction(args.fromFaction)
    local toFac   = Faction.getFaction(args.toFaction)
    local adminOk = false
    local access = player.getAccessLevel and player:getAccessLevel() or nil
    adminOk = access and (access == "admin" or access == "Admin")
    if not toFac then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Destination faction not found" }); return
    end
    local mayTransfer = adminOk
        or (fromFac and fromFac:isOwner(username) and toFac:isOwner(username))
    if not mayTransfer then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "You must own both factions to transfer" }); return
    end
    -- Cap check on destination
    local destCount = CSR_SafehouseClaim.getFactionSafehouseCount(args.toFaction)
    local maxFac    = CSR_SafehouseClaim.getMaxFactionSafehouses()
    if destCount >= maxFac then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Destination faction is at safehouse cap" }); return
    end
    local sh = CSR_SafehouseClaim.findSafehouseAt(args.x, args.y, args.w, args.h)
    if not sh then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Safehouse not found" }); return
    end
    sh:getModData().csrFactionOwner = args.toFaction
    if sh.transmitModData then sh:transmitModData() end
    -- Update registry
    if _factionSafehouseRegistry[args.fromFaction] then
        for i = #_factionSafehouseRegistry[args.fromFaction], 1, -1 do
            local e = _factionSafehouseRegistry[args.fromFaction][i]
            if e.x == args.x and e.y == args.y then
                table.remove(_factionSafehouseRegistry[args.fromFaction], i)
            end
        end
    end
    _factionSafehouseRegistry[args.toFaction] = _factionSafehouseRegistry[args.toFaction] or {}
    table.insert(_factionSafehouseRegistry[args.toFaction],
        { x = args.x, y = args.y, w = args.w, h = args.h })
    broadcastFactionSafehouseEvent("FactionSafehouseReleased",
        { factionName = args.fromFaction, x = args.x, y = args.y, w = args.w, h = args.h })
    broadcastFactionSafehouseEvent("FactionSafehouseRegistered",
        { factionName = args.toFaction, x = args.x, y = args.y, w = args.w, h = args.h })
    sendServerCommand(player, MODULE, "FactionSafehouseResult",
        { success = true, text = "Safehouse transferred to " .. args.toFaction })
end

-- ----------------------------------------------------------------------------
-- Set per-member role on a faction safehouse.  Stored in safehouse modData
-- under csrFactionRoles[username] = roleString (e.g. "officer", "member",
-- "guest").  Role enforcement is left to consumer code; this handler only
-- writes the value.
-- ----------------------------------------------------------------------------
function CSR_ServerCommands.handleSetFactionMemberRole(player, args)
    if not CSR_SafehouseClaim.isFactionSafehouseEnabled() then return end
    if not args or not args.factionName or not args.username or args.x == nil then return end
    local username = player:getUsername()
    local faction  = Faction.getFaction(args.factionName)
    local adminOk = false
    local access = player.getAccessLevel and player:getAccessLevel() or nil
    adminOk = access and (access == "admin" or access == "Admin")
    if not adminOk and not (faction and faction:isOwner(username)) then
        sendServerCommand(player, MODULE, "FactionSafehouseResult",
            { success = false, text = "Only the faction owner can change roles" }); return
    end
    local sh = CSR_SafehouseClaim.findSafehouseAt(args.x, args.y, args.w or 10, args.h or 10)
    if not sh then return end
    local md = sh:getModData()
    md.csrFactionRoles = md.csrFactionRoles or {}
    if args.role == nil or args.role == "" then
        md.csrFactionRoles[args.username] = nil
    else
        md.csrFactionRoles[args.username] = tostring(args.role)
    end
    if sh.transmitModData then sh:transmitModData() end
    sendServerCommand(player, MODULE, "FactionSafehouseResult",
        { success = true, text = "Role updated for " .. args.username })
end

-- Rebuild the in-memory registry from persisted SafeHouse modData after a restart.
local function rebuildFactionSafehouseRegistry()
    _factionSafehouseRegistry = {}
    if not (SafeHouse and SafeHouse.getSafehouseList) then return end
    local list = SafeHouse.getSafehouseList()
    if not list or not list.size then return end
    local sz = list:size()
    for i = 0, sz - 1 do
        local sh = list:get(i)
        if sh and sh.getModData then
            local md = sh:getModData()
            local tag = md and md.csrFactionOwner
            if type(tag) == "string" and tag ~= "" then
                _factionSafehouseRegistry[tag] = _factionSafehouseRegistry[tag] or {}
                table.insert(_factionSafehouseRegistry[tag],
                    { x = sh:getX(), y = sh:getY(), w = sh:getW(), h = sh:getH() })
            end
        end
    end
end

-- Retry pending modData tags once per in-game minute (≈1 real second at normal speed).
local function processPendingFactionTags()
    if #_pendingFactionTags == 0 then return end
    local remaining = {}
    for _, entry in ipairs(_pendingFactionTags) do
        entry.attempts = entry.attempts + 1
        local sh = CSR_SafehouseClaim.findSafehouseAt(entry.x, entry.y, entry.w, entry.h)
        if sh then
            sh:getModData().csrFactionOwner = entry.factionName
            if sh.transmitModData then sh:transmitModData() end
        elseif entry.attempts < 6 then
            table.insert(remaining, entry)
        end
    end
    _pendingFactionTags = remaining
end

Events.OnServerStarted.Add(rebuildFactionSafehouseRegistry)
Events.EveryOneMinute.Add(processPendingFactionTags)

-- =============================================
-- VEHICLE CLAIMING
-- =============================================

local function sendVehicleClaimResult(player, success, text)
    sendServerCommand(player, "CommonSenseLight", "VehicleClaimResult", {
        success = success,
        text = text,
    })
end

CSR_ServerCommands._vehicleClaimKeyIdField = "CSR_VehicleClaimKeyId"
CSR_ServerCommands._vehicleClaimKeyTokenField = "CSR_VehicleClaimKeyToken"
CSR_ServerCommands._vehicleClaimKeyOwnerField = "CSR_VehicleClaimKeyOwnerSteamID"
CSR_ServerCommands._keyItemVehicleKeyField = "CSR_ClaimVehicleKey"
CSR_ServerCommands._keyItemTokenField = "CSR_ClaimKeyToken"
CSR_ServerCommands._keyItemOwnerField = "CSR_ClaimKeyOwnerSteamID"

function CSR_ServerCommands._safeSteamIDFor(player)
    if not player or not player.getSteamID then return "" end
    local sid = player:getSteamID()
    if not sid then return "" end
    local s = tostring(sid)
    if s == "" or s == "0" then return "" end
    return s
end

function CSR_ServerCommands._findOnlinePlayerByUsername(username)
    username = tostring(username or "")
    if username == "" or not getOnlinePlayers then return nil end
    local players = getOnlinePlayers()
    if not players or not players.size then return nil end
    local count = tonumber(players:size()) or 0
    for i = 0, count - 1 do
        local p = players:get(i)
        if p and p.getUsername and tostring(p:getUsername() or "") == username then
            return p
        end
    end
    return nil
end

function CSR_ServerCommands._steamIDForUsername(username)
    local p = CSR_ServerCommands._findOnlinePlayerByUsername(username)
    return CSR_ServerCommands._safeSteamIDFor(p)
end

function CSR_ServerCommands._memberSteamPatch(row, username, addMember)
    local patch = {}
    if not row or not username or username == "" or not CSR_ClaimRegistry then
        return patch
    end
    local currentIDs = tostring(row.memberSteamIDsCSV or "")
    local currentMap = tostring(row.memberSteamMapCSV or "")

    if addMember then
        local sid = CSR_ServerCommands._steamIDForUsername(username)
        if sid ~= "" then
            if CSR_ClaimRegistry.csvAdd then
                patch.memberSteamIDsCSV = CSR_ClaimRegistry.csvAdd(currentIDs, sid)
            end
            if CSR_ClaimRegistry.mapSet then
                patch.memberSteamMapCSV = CSR_ClaimRegistry.mapSet(currentMap, username, sid)
            end
        end
    else
        local sid = ""
        if CSR_ClaimRegistry.mapGet then
            sid = CSR_ClaimRegistry.mapGet(currentMap, username)
        end
        if sid ~= "" and CSR_ClaimRegistry.csvRemove then
            patch.memberSteamIDsCSV = CSR_ClaimRegistry.csvRemove(currentIDs, sid)
        end
        if CSR_ClaimRegistry.mapRemove then
            patch.memberSteamMapCSV = CSR_ClaimRegistry.mapRemove(currentMap, username)
        end
    end

    return patch
end

function CSR_ServerCommands._randomClaimKeyId()
    if ZombRand then return (ZombRand(65534) + 1) end
    return ((os and os.time and os.time()) or 1) % 65534 + 1
end

function CSR_ServerCommands._randomClaimKeyToken(vehicleKey)
    local ts = (os and os.time and os.time()) or 0
    local rnd = ZombRand and ZombRand(1000000000) or math.floor(ts % 1000000)
    return "ck:" .. tostring(ts) .. ":" .. tostring(rnd) .. ":" .. tostring(vehicleKey or "")
end

function CSR_ServerCommands._vehicleDisplayName(vehicle)
    if not vehicle then return "Vehicle" end
    if vehicle.getScript then
        local script = vehicle:getScript()
        if script then
            if script.getCarModelName then
                local model = script:getCarModelName()
                if model and tostring(model) ~= "" then return tostring(model) end
            end
            if script.getName then
                local name = script:getName()
                if name and tostring(name) ~= "" then return tostring(name) end
            end
        end
    end
    return "Vehicle"
end

function CSR_ServerCommands._giveVehicleClaimKey(player, vehicle, row, keyId, token)
    if not player or not vehicle or not keyId or keyId <= 0 or not token or token == "" then
        return false
    end
    local inv = player.getInventory and player:getInventory() or nil
    if not inv or not inv.AddItem then return false end

    local key = inv:AddItem("Base.CarKey")
    if not key then return false end
    if key.setKeyId then key:setKeyId(keyId) end
    local label = "CSR " .. CSR_ServerCommands._vehicleDisplayName(vehicle) .. " Key"
    if key.setName then key:setName(label) end

    local md = key.getModData and key:getModData() or nil
    if md then
        md[CSR_ServerCommands._keyItemVehicleKeyField] = tostring(row and row.vehicleKey or "")
        md[CSR_ServerCommands._keyItemTokenField] = tostring(token)
        md[CSR_ServerCommands._keyItemOwnerField] = CSR_ServerCommands._safeSteamIDFor(player)
    end

    if key.transmitModData then key:transmitModData() end
    if inv.setDrawDirty then inv:setDrawDirty(true) end
    syncInventoryItem(key)
    syncPlayerInventory(player)
    return true
end

function CSR_ServerCommands._clearVehicleHotwire(vehicle)
    if not vehicle then return false end
    local wasHotwired = vehicle.isHotwired and vehicle:isHotwired() == true
    local wasBroken = vehicle.isHotwiredBroken and vehicle:isHotwiredBroken() == true
    if not wasHotwired and not wasBroken then return false end

    if vehicle.cheatHotwire then
        vehicle:cheatHotwire(false, false)
    elseif vehicle.setHotwired then
        vehicle:setHotwired(false)
        if vehicle.setHotwiredBroken then
            vehicle:setHotwiredBroken(false)
        end
    end

    if vehicle.saveToVehicleTable then vehicle:saveToVehicleTable() end
    if vehicle.sendVars then vehicle:sendVars() end
    if vehicle.transmitModData then vehicle:transmitModData() end
    return true
end

function CSR_ServerCommands._mirrorVehicleClaimKey(vehicle, row)
    if not vehicle or not row then return false end
    local keyId = tonumber(row.vehicleClaimKeyId) or 0
    local token = tostring(row.vehicleClaimKeyToken or "")
    if keyId <= 0 or token == "" then return false end

    local changed = false
    if vehicle.getKeyId and vehicle.setKeyId then
        local cur = tonumber(vehicle:getKeyId()) or 0
        if cur ~= keyId then
            vehicle:setKeyId(keyId)
            changed = true
        end
    end
    if CSR_ServerCommands._clearVehicleHotwire(vehicle) then
        changed = true
    end

    local data = vehicle.getModData and vehicle:getModData() or nil
    if data then
        if tonumber(data[CSR_ServerCommands._vehicleClaimKeyIdField]) ~= keyId then
            data[CSR_ServerCommands._vehicleClaimKeyIdField] = keyId
            changed = true
        end
        if tostring(data[CSR_ServerCommands._vehicleClaimKeyTokenField] or "") ~= token then
            data[CSR_ServerCommands._vehicleClaimKeyTokenField] = token
            changed = true
        end
        local ownerSid = tostring(row.ownerSteamID or "")
        if tostring(data[CSR_ServerCommands._vehicleClaimKeyOwnerField] or "") ~= ownerSid then
            data[CSR_ServerCommands._vehicleClaimKeyOwnerField] = ownerSid
            changed = true
        end
    end

    if changed and vehicle.saveToVehicleTable then vehicle:saveToVehicleTable() end
    if changed and vehicle.transmitModData then vehicle:transmitModData() end
    return changed
end

function CSR_ServerCommands._bindVehicleClaimKey(player, vehicle, row, rotate, issueKey)
    if not vehicle or not row or not row.id then return row end
    local keyId = tonumber(row.vehicleClaimKeyId) or 0
    local token = tostring(row.vehicleClaimKeyToken or "")
    if rotate or keyId <= 0 or token == "" then
        keyId = CSR_ServerCommands._randomClaimKeyId()
        token = CSR_ServerCommands._randomClaimKeyToken(row.vehicleKey)
        if CSR_ClaimServer and CSR_ClaimServer.commitUpdate then
            row = CSR_ClaimServer.commitUpdate(row.id, {
                vehicleClaimKeyId = keyId,
                vehicleClaimKeyToken = token,
            }) or row
        end
    end

    CSR_ServerCommands._mirrorVehicleClaimKey(vehicle, row)
    if issueKey then
        CSR_ServerCommands._giveVehicleClaimKey(player, vehicle, row, keyId, token)
    end
    return row
end

-- Locate the unified-registry row id for a vehicle (or nil if no row exists).
local function findVehicleClaimRowId(vehicle)
    if not vehicle then return nil end
    local row = nil
    if CSR_VehicleClaim and CSR_VehicleClaim.getRegistryRow then
        row = CSR_VehicleClaim.getRegistryRow(vehicle)
    end
    return row and row.id or nil
end

local function vehicleClaimKey(value)
    if not value or value == "" then return "" end
    value = tostring(value)
    if string.sub(value, 1, 4) == "sql:" or string.sub(value, 1, 4) == "csr:" then
        return value
    end
    return ""
end

local function vehicleMatchesClaimKey(vehicle, key)
    if not vehicle or key == "" then return false end
    if not (CSR_VehicleClaim and CSR_VehicleClaim.getVehicleKeyCandidates) then
        return false
    end
    local keys = CSR_VehicleClaim.getVehicleKeyCandidates(vehicle, false)
    for i = 1, #keys do
        if keys[i] == key then return true end
    end
    return false
end

local function resolveVehicleClaimVehicle(player, args, allowCurrentVehicleWithoutKey)
    local key = args and vehicleClaimKey(args.vehicleKey or args.vehicleId) or ""
    local current = player and player.getVehicle and player:getVehicle() or nil
    if key ~= "" and CSR_VehicleClaim and CSR_VehicleClaim.findLoadedVehicleByKey then
        if vehicleMatchesClaimKey(current, key) then return current end
        local byKey = CSR_VehicleClaim.findLoadedVehicleByKey(key)
        if byKey then return byKey end
    end

    if allowCurrentVehicleWithoutKey then
        return current
    end

    return nil
end

local function findVehicleClaimRow(vehicle, args)
    local row = nil
    if args and args.rowId and CSR_ClaimRegistry then
        local candidate = CSR_ClaimRegistry.getRowById(tonumber(args.rowId))
        if candidate and candidate.kind == "vehicle" then row = candidate end
    end
    local key = args and vehicleClaimKey(args.vehicleKey or args.vehicleId) or ""
    if not row and key ~= ""
            and CSR_ClaimRegistry and CSR_ClaimRegistry.getRowByVehicleKey then
        row = CSR_ClaimRegistry.getRowByVehicleKey(key)
    end
    if not row and vehicle and CSR_VehicleClaim and CSR_VehicleClaim.getRegistryRow then
        row = CSR_VehicleClaim.getRegistryRow(vehicle)
    end
    if row and vehicle and CSR_VehicleClaim and CSR_VehicleClaim.getVehicleKeyCandidates then
        local rowKey = tostring(row.vehicleKey or "")
        if rowKey == "" then return nil end
        local keys = CSR_VehicleClaim.getVehicleKeyCandidates(vehicle, false)
        local matches = false
        for i = 1, #keys do
            if keys[i] == rowKey then matches = true; break end
        end
        if not matches then return nil end
    end
    return row
end

local function getVehicleIdentityForClaim(vehicle)
    if not vehicle or not CSR_VehicleClaim or not CSR_VehicleClaim.getVehicleIdentity then
        return nil
    end
    return CSR_VehicleClaim.getVehicleIdentity(vehicle, true)
end

-- v1.8.5: helper -- is this player a server admin?
local function isAdminAccess(player)
    if not player or not player.getAccessLevel then return false end
    local access = player:getAccessLevel()
    return access == "admin" or access == "Admin"
end

local function canManageVehicleClaim(player, row, vehicle)
    if isAdminAccess(player) then return true end
    if row and CSR_VehicleClaim and CSR_VehicleClaim.rowOwnerMatches
            and CSR_VehicleClaim.rowOwnerMatches(row, player) then
        return true
    end
    if row and player and player.getUsername and row.owner == player:getUsername() then
        return true
    end
    if vehicle and CSR_VehicleClaim and CSR_VehicleClaim.isOwner then
        return CSR_VehicleClaim.isOwner(vehicle, player)
    end
    return false
end

function CSR_ServerCommands.handleClaimVehicle(player, args)
    if not CSR_VehicleClaim.isEnabled() then
        sendVehicleClaimResult(player, false, "Vehicle claiming is disabled")
        return
    end
    local vehicle = resolveVehicleClaimVehicle(player, args or {}, true)
    if not vehicle then
        sendVehicleClaimResult(player, false, "Vehicle not found")
        return
    end
    local identity = getVehicleIdentityForClaim(vehicle)
    if not identity or identity.vehicleKey == "" then
        sendVehicleClaimResult(player, false, "Vehicle has no persistent id")
        return
    end
    local isAdmin = isAdminAccess(player)
    -- v1.8.5: admin force-claim path. If a foreign owner exists, release
    -- their row first (broadcasts CSR_VehicleClaimCleared via commitRemove)
    -- before falling through into the normal claim write below.
    if CSR_VehicleClaim.isClaimed(vehicle) then
        if not isAdmin then
            sendVehicleClaimResult(player, false, "Vehicle already claimed")
            return
        end
        local existingRowId = findVehicleClaimRowId(vehicle)
        if existingRowId and CSR_ClaimServer and CSR_ClaimServer.commitRemove then
            CSR_ClaimServer.commitRemove(existingRowId)
        end
        -- Clear any legacy modData mirror so the new owner is unambiguous.
        CSR_VehicleClaim.clearOwner(vehicle)
        if vehicle.transmitModData then vehicle:transmitModData() end
    end
    local username = player:getUsername()
    local ownerSteamID = CSR_ServerCommands._safeSteamIDFor(player)
    -- Admin force-claim does not count against the per-player cap.
    if not isAdmin then
        local count = CSR_VehicleClaim.getClaimCount(username)
        local max = CSR_VehicleClaim.getMaxClaims()
        if count >= max then
            sendVehicleClaimResult(player, false, "Max vehicles claimed (" .. max .. ")")
            return
        end
    end

    -- Build a display title for the unified Claims Manager UI.
    local title = ""
    if vehicle.getScript then
        local script = vehicle:getScript()
        if script and script.getName then
            local n = script:getName()
            if n then title = tostring(n) end
        end
    end
    if title == "" then title = "Vehicle" end

    -- Write the claim through the unified registry so the CSR Claims Manager
    -- panel sees radial-menu claims alongside personal/faction safehouse rows.
    local addedRow = nil
    if CSR_ClaimServer and CSR_ClaimServer.commitAdd then
        addedRow = CSR_ClaimServer.commitAdd({
            kind                = "vehicle",
            x = identity.lastVehicleX, y = identity.lastVehicleY, w = 1, h = 1, z = identity.lastVehicleZ,
            owner               = username,
            title               = title,
            factionName         = "",
            vehicleId           = identity.vehicleKey,
            vehicleKey          = identity.vehicleKey,
            vehicleSqlId        = identity.vehicleSqlId,
            vehicleRuntimeId    = "",
            vehicleClaimVersion = 2,
            lastVehicleX        = identity.lastVehicleX,
            lastVehicleY        = identity.lastVehicleY,
            lastVehicleZ        = identity.lastVehicleZ,
            membersCSV          = "",
            rolesCSV            = "",
            migratedFromVanilla = 0,
            vehicleScript       = identity.vehicleScript,
            vehicleClaimedAt    = os and os.time and os.time() or 0,
            ownerSteamID        = ownerSteamID,
        })
    end

    if addedRow then
        addedRow = CSR_ServerCommands._bindVehicleClaimKey(player, vehicle, addedRow, true, true) or addedRow
    end

    -- Legacy modData mirror (back-compat for any pre-v1.8.0 reader).
    CSR_VehicleClaim.setOwner(vehicle, username, addedRow)
    vehicle:transmitModData()

    -- Mirror the claim onto any currently-attached trailer so detaching
    -- it later doesn't strip the owner's protection. Trailer claim is
    -- independent (owner can unclaim it separately).
    if vehicle.getVehicleTowing then
        local trailer = vehicle:getVehicleTowing()
        if trailer and not CSR_VehicleClaim.isClaimed(trailer) then
            local trailerIdentity = nil
            if CSR_VehicleClaim and CSR_VehicleClaim.getVehicleIdentity then
                trailerIdentity = CSR_VehicleClaim.getVehicleIdentity(trailer, true)
            end
            if trailerIdentity and trailerIdentity.vehicleKey then
                local tTitle = "Trailer of " .. title
                local tRow = nil
                if CSR_ClaimServer and CSR_ClaimServer.commitAdd then
                    tRow = CSR_ClaimServer.commitAdd({
                        kind                = "vehicle",
                        x = trailerIdentity.lastVehicleX, y = trailerIdentity.lastVehicleY, w = 1, h = 1, z = trailerIdentity.lastVehicleZ,
                        owner               = username,
                        title               = tTitle,
                        factionName         = "",
                        vehicleId           = trailerIdentity.vehicleKey,
                        vehicleKey          = trailerIdentity.vehicleKey,
                        vehicleSqlId        = trailerIdentity.vehicleSqlId,
                        vehicleRuntimeId    = "",
                        vehicleClaimVersion = 2,
                        lastVehicleX        = trailerIdentity.lastVehicleX,
                        lastVehicleY        = trailerIdentity.lastVehicleY,
                        lastVehicleZ        = trailerIdentity.lastVehicleZ,
                        membersCSV          = "",
                        rolesCSV            = "",
                        migratedFromVanilla = 0,
                        vehicleScript       = trailerIdentity.vehicleScript,
                        vehicleClaimedAt    = os and os.time and os.time() or 0,
                        ownerSteamID        = ownerSteamID,
                    })
                end
                CSR_VehicleClaim.setOwner(trailer, username, tRow)
                if trailer.transmitModData then trailer:transmitModData() end
            end
        end
    end

    if addedRow then
        sendVehicleClaimResult(player, true, "Vehicle claimed!")
    else
        -- Registry write failed -- the modData write above is the legacy fallback.
        sendVehicleClaimResult(player, true, "Vehicle claimed (legacy)")
    end
end

function CSR_ServerCommands.handleUnclaimVehicle(player, args)
    if not CSR_VehicleClaim.isEnabled() then
        sendVehicleClaimResult(player, false, "Vehicle claiming is disabled")
        return
    end
    local vehicle = resolveVehicleClaimVehicle(player, args, true)
    if not vehicle then
        sendVehicleClaimResult(player, false, "Vehicle not found")
        return
    end
    -- v1.8.5: admin override -- admins may release any vehicle.
    local isAdmin = isAdminAccess(player)
    if not isAdmin and not CSR_VehicleClaim.isOwner(vehicle, player) then
        sendVehicleClaimResult(player, false, "Not your vehicle")
        return
    end

    -- v1.8.5: capture prior owner so we can label admin force-release.
    local priorOwner = CSR_VehicleClaim.getOwner(vehicle)

    -- Remove the unified-registry row (if present) and clear legacy modData.
    local rowId = findVehicleClaimRowId(vehicle)
    if rowId and CSR_ClaimServer and CSR_ClaimServer.commitRemove then
        CSR_ClaimServer.commitRemove(rowId)
    end
    CSR_VehicleClaim.clearOwner(vehicle)
    vehicle:transmitModData()
    if isAdmin and priorOwner and priorOwner ~= player:getUsername() then
        sendVehicleClaimResult(player, true,
            "Force-released vehicle from " .. tostring(priorOwner))
    else
        sendVehicleClaimResult(player, true, "Vehicle unclaimed")
    end
end

function CSR_ServerCommands.handleVehicleAddAllowed(player, args)
    if not CSR_VehicleClaim.isEnabled() then return end
    local vehicle = resolveVehicleClaimVehicle(player, args, false)
    local row = findVehicleClaimRow(vehicle, args)
    if not row then return end
    if not canManageVehicleClaim(player, row, vehicle) then return end
    local targetName = args and args.targetName
    if not targetName or targetName == "" then return end
    local changed = true
    if vehicle then
        changed = CSR_VehicleClaim.addAllowed(vehicle, targetName)
    end
    if changed then
        if vehicle and vehicle.transmitModData then
            vehicle:transmitModData()
        end
        local rowId = row.id
        if rowId and CSR_ClaimServer and CSR_ClaimServer.commitUpdate then
            local csv = row.membersCSV or ""
            if not (CSR_ClaimRegistry and CSR_ClaimRegistry.csvContains
                    and CSR_ClaimRegistry.csvContains(csv, targetName)) then
                local newCsv = (CSR_ClaimRegistry and CSR_ClaimRegistry.csvAdd)
                    and CSR_ClaimRegistry.csvAdd(csv, targetName)
                    or ((csv == "" and targetName) or (csv .. "," .. targetName))
                local patch = CSR_ServerCommands._memberSteamPatch(row, targetName, true)
                patch.membersCSV = newCsv
                CSR_ClaimServer.commitUpdate(rowId, patch)
            else
                local patch = CSR_ServerCommands._memberSteamPatch(row, targetName, true)
                if next(patch) ~= nil then CSR_ClaimServer.commitUpdate(rowId, patch) end
            end
        end
        sendVehicleClaimResult(player, true, targetName .. " added to vehicle")
    elseif row and row.id and CSR_ClaimRegistry and CSR_ClaimRegistry.csvContains
            and not CSR_ClaimRegistry.csvContains(row.membersCSV or "", targetName) then
        local newCsv = CSR_ClaimRegistry.csvAdd(row.membersCSV or "", targetName)
        local patch = CSR_ServerCommands._memberSteamPatch(row, targetName, true)
        patch.membersCSV = newCsv
        CSR_ClaimServer.commitUpdate(row.id, patch)
        sendVehicleClaimResult(player, true, targetName .. " added to vehicle")
    end
end

function CSR_ServerCommands.handleVehicleRemoveAllowed(player, args)
    if not CSR_VehicleClaim.isEnabled() then return end
    local vehicle = resolveVehicleClaimVehicle(player, args, false)
    local row = findVehicleClaimRow(vehicle, args)
    if not row then return end
    if not canManageVehicleClaim(player, row, vehicle) then return end
    local targetName = args and args.targetName
    if not targetName or targetName == "" then return end
    local changed = true
    if vehicle then
        changed = CSR_VehicleClaim.removeAllowed(vehicle, targetName)
    end
    if changed or (CSR_ClaimRegistry and CSR_ClaimRegistry.csvContains
            and CSR_ClaimRegistry.csvContains(row.membersCSV or "", targetName)) then
        if vehicle and vehicle.transmitModData then
            vehicle:transmitModData()
        end
        if row.id and CSR_ClaimServer and CSR_ClaimServer.commitUpdate then
            local newCsv = (CSR_ClaimRegistry and CSR_ClaimRegistry.csvRemove)
                and CSR_ClaimRegistry.csvRemove(row.membersCSV or "", targetName)
                or ""
            local patch = CSR_ServerCommands._memberSteamPatch(row, targetName, false)
            patch.membersCSV = newCsv
            CSR_ClaimServer.commitUpdate(row.id, patch)
        end
        sendVehicleClaimResult(player, true, targetName .. " removed from vehicle")
    end
end

function CSR_ServerCommands.handleVehicleReissueClaimKey(player, args)
    if not CSR_VehicleClaim.isEnabled() then
        sendVehicleClaimResult(player, false, "Vehicle claiming is disabled")
        return
    end
    local vehicle = resolveVehicleClaimVehicle(player, args, true)
    if not vehicle then
        sendVehicleClaimResult(player, false, "Vehicle not found")
        return
    end
    local row = findVehicleClaimRow(vehicle, args)
    if not row then
        sendVehicleClaimResult(player, false, "Vehicle is not claimed")
        return
    end
    if not canManageVehicleClaim(player, row, vehicle) then
        sendVehicleClaimResult(player, false, "Not allowed to reissue this key")
        return
    end
    CSR_ServerCommands._bindVehicleClaimKey(player, vehicle, row, true, true)
    sendVehicleClaimResult(player, true, "CSR vehicle key reissued")
end

function CSR_ServerCommands.handleVehicleRemoveClaimHotwire(player, args)
    if not CSR_VehicleClaim.isEnabled() then
        sendVehicleClaimResult(player, false, "Vehicle claiming is disabled")
        return
    end
    local vehicle = resolveVehicleClaimVehicle(player, args, true)
    if not vehicle then
        sendVehicleClaimResult(player, false, "Vehicle not found")
        return
    end
    local row = findVehicleClaimRow(vehicle, args)
    if not row then
        sendVehicleClaimResult(player, false, "Vehicle is not claimed")
        return
    end
    if not canManageVehicleClaim(player, row, vehicle) then
        sendVehicleClaimResult(player, false, "Not allowed to remove this hotwire")
        return
    end
    if player.getVehicle and player:getVehicle() ~= vehicle then
        sendVehicleClaimResult(player, false, "Sit in the vehicle first")
        return
    end
    if not vehicle.isDriver or not vehicle:isDriver(player) then
        sendVehicleClaimResult(player, false, "Sit in the driver seat")
        return
    end
    if (vehicle.isEngineRunning and vehicle:isEngineRunning())
            or (vehicle.isEngineStarted and vehicle:isEngineStarted()) then
        sendVehicleClaimResult(player, false, "Turn the engine off first")
        return
    end

    CSR_ServerCommands._bindVehicleClaimKey(player, vehicle, row, false, false)
    if CSR_ServerCommands._clearVehicleHotwire(vehicle) then
        sendVehicleClaimResult(player, true, "Vehicle hotwire removed")
    else
        sendVehicleClaimResult(player, true, "Vehicle hotwire already clear")
    end
end

-- ─── Dual Wield Server Logic ──────────────────────────────────────────
--
-- ARCHITECTURE NOTE -- READ BEFORE REFACTORING (especially LLM advisors):
--
-- The dual-wield secondary-weapon restoration uses a HYBRID design on
-- purpose. Two cooperating mechanisms run in parallel:
--
--   1. Events.OnTick -> checkUnarmedWeaponMode (below)
--        Anchors the current secondary every tick + restores within a
--        2-tick freshness window. This is the SAFETY NET.
--   2. Events.OnPlayerAttackFinished -> onServerAttackFinished (below)
--        Restores secondary after Java's Hit() pipeline nulls it during a
--        primary attack. This is the FAST PATH.
--
-- Do NOT "convert OnTick to event-driven" -- that suggestion has been
-- floated repeatedly and has been rejected each time. The OnTick path is
-- load-bearing and catches three classes of clears that no event covers:
--
--   (a) Third-party sync-mod clears (iSync, anti-cheat) that null the
--       secondary slot OUTSIDE any attack pipeline. No OnPlayerAttackFinished
--       fires. Only the per-tick freshness check restores it.
--   (b) 2H weapon mirror transitions. Vanilla mirrors a 2H weapon into BOTH
--       primary and secondary slots while wielded; on unequip the engine
--       clears primary first and secondary one tick later. The isMirrored2H
--       guard below is a per-tick state machine that drops the anchor during
--       2H states so we never restore a 1H over the 2H state, nor restore
--       the 2H over the unequip. This cannot be expressed as a single event.
--   (c) Distinguishing intentional player unequip from engine clear. The
--       2-tick freshness window is what tells them apart. Attack-finished
--       events carry no temporal context that can replace this.
--
-- History: v1.7.5-v1.7.7 changelog entries document the field bugs that
-- forced this design (off-hand weapon permanently disappearing, 2H weapons
-- stuck in off-hand, sync-mod ghost clears). Per-player cost is O(1) -- a
-- couple of getters and a hashmap write -- so there is no perf reason to
-- collapse it. If you must touch this, read those changelog entries first
-- and add new edge cases ALONGSIDE the existing logic, not in place of it.
--
-- ─────────────────────────────────────────────────────────────────────
local playerUnarmedModes = {}
local playerLastLeftHandInfos = {}

-- Secondary-weapon anchor: tracks each dual-wielding player's last-known valid
-- secondary so it can be restored when Java's primary-attack pipeline clears it.
-- The anchor is considered "fresh" only when it was updated in the same server
-- tick as the attack-finished event fires; this prevents fighting intentional
-- player unequips (which happen on a different tick than any attack).
local playerSecondaryAnchors = {}  -- [pid] = { weapon = item, tick = N }
local dwServerTick = 0             -- monotonic counter updated in onDualWieldServerTick

-- v1.8.1 Part A helper: clear any attachedSlot the engine set on an item so
-- setSecondaryHandItem() doesn't re-equip a weapon that the hotbar still
-- considers "stowed" (which is what makes the off-hand weapon appear stuck
-- and unequipable from inventory).
local function dwClearAttachedSlot(player, item)
    if not item then return end
    if item.getAttachedSlot and item:getAttachedSlot() ~= -1 then
        if item.setAttachedSlot     then item:setAttachedSlot(-1) end
        if item.setAttachedSlotType then item:setAttachedSlotType(nil) end
        if item.setAttachedToModel  then item:setAttachedToModel(nil) end
        if player and player.removeAttachedItem then
            player:removeAttachedItem(item)
        end
    end
end

-- v1.8.1 Part B: anchor freshness window extended from 2 -> 8 ticks. Catches
-- the slow-swing / packet-lag case where OnPlayerAttackFinished fires later
-- than the previous 2-tick window, leaving the secondary cleared. 8 ticks is
-- still far below any human-perceptible unequip intent.
local DW_ANCHOR_FRESHNESS_TICKS = 8

local function getIsoCharacterFromID(referencePlayer, id)
    local utils = getDWUtils()
    local p = utils.getPlayerFromID(id)
    if p then return p end
    return utils.getZombieFromID(referencePlayer, id)
end

local function checkUnarmedWeaponMode(player)
    if player:isDead() or player:isZombie() then return end

    local utils = getDWUtils()
    if not utils then return end
    local pid = utils.getPlayerID(player)

    -- Track secondary-weapon anchor every tick, regardless of primary-hand state.
    -- This must happen before any early-return so even armed players are tracked.
    --
    -- v1.7.7: NEVER anchor a 2H weapon held in the secondary slot. Vanilla
    -- mirrors a 2H weapon into BOTH primary and secondary slots while it is
    -- wielded. On unequip the engine clears primary first and secondary one
    -- tick later. Without this guard the previous code (a) saved the mirrored
    -- 2H ref into the anchor every tick, then (b) the moment the engine cleared
    -- secondary the next tick saw an empty slot with a fresh anchor and
    -- re-equipped the 2H weapon as a "dual-wield secondary" -- leaving the
    -- weapon visually stuck in the off-hand and un-stowable. The fix: only
    -- anchor a real dual-wield secondary (1H weapon, distinct from primary).
    local sec = player:getSecondaryHandItem()
    local prim = player:getPrimaryHandItem()
    local isMirrored2H = sec ~= nil and (
        sec == prim
        or (sec.isRequiresEquippedBothHands and sec:isRequiresEquippedBothHands())
        or (sec.isTwoHandWeapon and sec:isTwoHandWeapon())
    )
    if sec and not sec:isBroken() and sec.IsWeapon and sec:IsWeapon() and not isMirrored2H then
        playerSecondaryAnchors[pid] = { weapon = sec, tick = dwServerTick }
    elseif isMirrored2H then
        -- Drop any stale anchor while a 2H mirror is active so we never restore
        -- a 1H weapon over the 2H state, and never restore the 2H over the unequip.
        playerSecondaryAnchors[pid] = nil
    else
        local anchor = playerSecondaryAnchors[pid]
        if anchor and (dwServerTick - anchor.tick) <= DW_ANCHOR_FRESHNESS_TICKS then
            local w = anchor.weapon
            local wIs2H = w ~= nil and (
                (w.isRequiresEquippedBothHands and w:isRequiresEquippedBothHands())
                or (w.isTwoHandWeapon and w:isTwoHandWeapon())
            )
            if w and not w:isBroken() and not wIs2H and player:getInventory():contains(w) then
                dwClearAttachedSlot(player, w)
                player:setSecondaryHandItem(w)
            else
                playerSecondaryAnchors[pid] = nil
            end
        end
    end

    if player:getPrimaryHandItem() ~= nil then return end
    local unarmedMode = utils.getUnarmedMode(player)
    if playerUnarmedModes[pid] == unarmedMode then return end
    local weapon = player:getAttackingWeapon()
    if weapon:getScriptItem() ~= unarmedMode.SCRIPTITEM then
        utils.changeWeaponStats(weapon, unarmedMode.ITEM, unarmedMode.SCRIPTITEM)
    end
    playerUnarmedModes[pid] = unarmedMode
end

local function onDualWieldServerTick(tick)
    local utils = getDWUtils()
    if not utils then return end
    local sb = SandboxVars and SandboxVars.CommonSenseLight or nil
    if sb and sb.EnableDualWield == false then return end
    dwServerTick = dwServerTick + 1
    utils.foreachPlayerDo(checkUnarmedWeaponMode)
end

function CSR_ServerCommands.handleDW_LeftAttack(player, args)
    local utils = getDWUtils()
    local pid = utils.getPlayerID(player)
    playerLastLeftHandInfos[pid] = utils.checkIfValidLeftHandAttack(player, true)
end

function CSR_ServerCommands.handleDW_LeftHit(player, data)
    local utils = getDWUtils()
    local pid = utils.getPlayerID(player)
    local leftHandAttackInfo = playerLastLeftHandInfos[pid]
    if not leftHandAttackInfo then return end
    playerLastLeftHandInfos[pid] = nil

    -- Re-resolve weapon from current hand to avoid stale item references
    local weapon = leftHandAttackInfo.weapon
    if leftHandAttackInfo.mode == CSR_DualWield.ArmedMode then
        local currentSec = player:getSecondaryHandItem()
        if currentSec and not currentSec:isBroken() then
            weapon = currentSec
        end
    end
    if weapon:isBroken() then return end

    local anchoredSecondary = player:getSecondaryHandItem()

    local function restoreAnchoredSecondary()
        if not anchoredSecondary or anchoredSecondary:isBroken() then return end
        if player:getSecondaryHandItem() == anchoredSecondary then return end
        if not player:getInventory():contains(anchoredSecondary) then return end
        dwClearAttachedSlot(player, anchoredSecondary)
        player:setSecondaryHandItem(anchoredSecondary)
    end

    local maxHits = CSR_LeftHandAttackAction.getMaxHits(player, weapon, leftHandAttackInfo.mode)
    local attackerIsDoShove = player:isDoShove()
    -- Co-operative flag: third-party sync/anti-cheat mods (e.g. iSync) can read
    -- this to skip ghost-swing detection during our authoritative left-hand
    -- damage application.
    CSR_DualWield._inLeftHandHit = true
    for _, targetID in ipairs(data) do
        local enemy = getIsoCharacterFromID(player, targetID)
        if enemy then
            -- v1.8.19 Layer-3: two-phase shove+hit damage application.
            -- Replaces the prior single enemy:Hit(weapon, player, 1, false, 1)
            -- call.  Phase 1 (shove=true, ignoreDamage=true) plays the
            -- knockback/stagger reaction without applying damage; phase 2
            -- (shove=false) computes and applies the damage value.  This
            -- matches vanilla's processHitDamage + hitConsequences pipeline
            -- and gives perks / weapon condition / hit reactions the same
            -- inputs they get from a primary-hand swing, which our previous
            -- direct Hit() call was bypassing for some weapon types.
            player:setDoShove(true)
            local dmg1 = enemy:processHitDamage(weapon, player, 1, true, 1)
            enemy:hitConsequences(weapon, player, true, dmg1, false)
            player:setDoShove(false)
            local dmg2 = enemy:processHitDamage(weapon, player, 1, false, 1)
            enemy:hitConsequences(weapon, player, false, dmg2, false)
            restoreAnchoredSecondary()
            maxHits = maxHits - 1
            if maxHits <= 0 then break end
        end
    end
    CSR_DualWield._inLeftHandHit = false
    player:setDoShove(attackerIsDoShove)
    restoreAnchoredSecondary()

    if weapon:isBroken() and player:getSecondaryHandItem() == weapon then
        player:setSecondaryHandItem(nil)
    end

    -- Sync weapon condition state to clients
    if leftHandAttackInfo.mode.MAYDAMAGEWEAPON then
        syncInventoryItem(weapon)
    end

    if leftHandAttackInfo.xpPerk and player.getXp then
        addXp(player, leftHandAttackInfo.xpPerk, CSR_DualWield.LEFT_ATTACK_XP)
        if not weapon:hasTag(ItemTag.NO_MAINTENANCE_XP) then
            local condLowerChance = weapon:getConditionLowerChance()
            local amount = CSR_DualWield.LEFT_ATTACK_MAINTENANCE_XP
            if condLowerChance > 10 then
                amount = amount * 10 / condLowerChance
            end
            addXp(player, Perks.Maintenance, amount)
        end
    end
end

function CSR_ServerCommands.handleDW_UnarmedRightHit(player, data)
    if not data or #data < 2 then return end
    local targetID = data[1]
    local damageSplit = data[2]
    if not targetID or not damageSplit then return end
    local target = getIsoCharacterFromID(player, targetID)
    if not target then return end
    local utils = getDWUtils()
    local valid, mode = utils.isNonDefaultUnarmedAttack(player, target, true)
    if not valid then return end
    local attackerIsDoShove = player:isDoShove()
    player:setDoShove(false)
    CSR_DualWield._inLeftHandHit = true
    target:Hit(mode.ITEM, player, damageSplit, false, 1.0)
    CSR_DualWield._inLeftHandHit = false
    player:setDoShove(attackerIsDoShove)
end

if not CSR_ServerCommands._dualWieldTickRegistered then
    CSR_ServerCommands._dualWieldTickRegistered = true
    Events.OnTick.Add(onDualWieldServerTick)
end

local function onServerAttackFinished(player)
    if not player or not instanceof(player, "IsoPlayer") then return end
    local sb = SandboxVars and SandboxVars.CommonSenseLight or nil
    if sb and sb.EnableDualWield == false then return end
    if player:getSecondaryHandItem() ~= nil then return end

    local utils = getDWUtils()
    if not utils then return end
    local pid = utils.getPlayerID(player)
    local anchorData = playerSecondaryAnchors[pid]
    if not anchorData then return end
    if dwServerTick - anchorData.tick > DW_ANCHOR_FRESHNESS_TICKS then return end

    local weapon = anchorData.weapon
    if not weapon or weapon:isBroken() then
        playerSecondaryAnchors[pid] = nil
        return
    end
    local wIs2H = (weapon.isRequiresEquippedBothHands and weapon:isRequiresEquippedBothHands())
        or (weapon.isTwoHandWeapon and weapon:isTwoHandWeapon())
    if wIs2H then
        playerSecondaryAnchors[pid] = nil
        return
    end
    if player:getInventory():contains(weapon) then
        dwClearAttachedSlot(player, weapon)
        player:setSecondaryHandItem(weapon)
    else
        playerSecondaryAnchors[pid] = nil
    end
end

if Events and Events.OnPlayerAttackFinished then
    Events.OnPlayerAttackFinished.Add(onServerAttackFinished)
end

-- ─── End Dual Wield Server Logic ─────────────────────────────────────

-- ─── Admin: Purge All Fireworks ──────────────────────────────────────

local function removeFireworksFromContainer(container)
    if not container or not container.getItems then return 0 end
    local items = container:getItems()
    if not items then return 0 end
    local count = 0
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if item and item.getFullType and item:getFullType() == "CommonSenseLight.Firework" then
            container:Remove(item)
            if sendRemoveItemFromContainer then
                sendRemoveItemFromContainer(container, item)
            end
            count = count + 1
        elseif item and instanceof(item, "InventoryContainer") then
            local subInv = item.getInventory and item:getInventory() or nil
            if subInv then
                count = count + removeFireworksFromContainer(subInv)
            end
        end
    end
    return count
end

-- =============================================
-- NOTICE BOARD SERVER HANDLERS
-- =============================================

local NOTICE_PREFIX_SRV        = "papernotices_01_"
local WHITEBOARD_PREFIX_SRV    = "location_business_office_generic_01_"
local WHITEBOARD_MIN_SRV       = 50
local WHITEBOARD_MAX_SRV       = 55
local NOTICE_MAX_LEN_SRV       = 80
local WHITEBOARD_MAX_LEN_SRV   = 80
local WHITEBOARD_LINES_SRV     = 6

local function isWhiteboardSpriteSrv(sName)
    if not sName then return false end
    if sName:sub(1, #WHITEBOARD_PREFIX_SRV) ~= WHITEBOARD_PREFIX_SRV then return false end
    local num = tonumber(sName:sub(#WHITEBOARD_PREFIX_SRV + 1))
    return num and num >= WHITEBOARD_MIN_SRV and num <= WHITEBOARD_MAX_SRV
end

local function findWorldIsoObject(x, y, z, spriteName)
    if not x or not y or not z then return nil end
    local sq = getCell and getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local objs = sq:getObjects()
    if not objs then return nil end
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o and o.getSpriteName and o:getSpriteName() == spriteName then
            return o
        end
    end
    return nil
end

local function serverHasPenOrMarker(player)
    local inv = player:getInventory()
    return inv:containsTypeRecurse("Pen")
        or inv:containsTypeRecurse("RedPen")
        or inv:containsTypeRecurse("BluePen")
        or inv:containsTypeRecurse("Pencil")
        or inv:containsTypeRecurse("MarkerBlack")
        or inv:containsTypeRecurse("MarkerBlue")
        or inv:containsTypeRecurse("MarkerRed")
        or inv:containsTypeRecurse("MarkerGreen")
end

function CSR_ServerCommands.handleNoticeBoardWrite(player, args)
    if not CSR_FeatureFlags.isNoticeBoardEnabled() then return end

    local x = args and tonumber(args.x)
    local y = args and tonumber(args.y)
    local z = args and tonumber(args.z)
    local spriteName = args and tostring(args.spriteName or "")

    -- Validate sprite is a paper notice
    if spriteName:sub(1, #NOTICE_PREFIX_SRV) ~= NOTICE_PREFIX_SRV then
        return
    end

    if not serverHasPenOrMarker(player) then
        sendResult(player, "You need a pen or marker to write.")
        return
    end

    -- Distance check: server player vs tile coords
    if not isNearPlayer(player, {x=x, y=y, z=z}) then
        return
    end

    local obj = findWorldIsoObject(x, y, z, spriteName)
    if not obj then return end

    local text = tostring(args.text or ""):gsub("[%c]", " "):sub(1, NOTICE_MAX_LEN_SRV)
    local md = obj:getModData()
    md.csrNotice = {
        text      = text,
        author    = player:getUsername(),
        timestamp = getTimestamp and getTimestamp() or 0,
    }
    if obj.transmitModData then obj:transmitModData() end
    sendResult(player, "Notice posted.")
end

function CSR_ServerCommands.handleWhiteboardWrite(player, args)
    if not CSR_FeatureFlags.isNoticeBoardEnabled() then return end

    local x = args and tonumber(args.x)
    local y = args and tonumber(args.y)
    local z = args and tonumber(args.z)
    local spriteName = args and tostring(args.spriteName or "")

    if not isWhiteboardSpriteSrv(spriteName) then
        return
    end

    -- Whiteboard writing requires a marker specifically
    local inv = player:getInventory()
    local hasMarker = inv:containsTypeRecurse("MarkerBlack")
        or inv:containsTypeRecurse("MarkerBlue")
        or inv:containsTypeRecurse("MarkerRed")
        or inv:containsTypeRecurse("MarkerGreen")
    if not hasMarker then
        sendResult(player, "You need a marker to write on the whiteboard.")
        return
    end

    if not isNearPlayer(player, {x=x, y=y, z=z}) then
        return
    end

    local obj = findWorldIsoObject(x, y, z, spriteName)
    if not obj then return end

    local linesStr = tostring(args.linesStr or "")
    -- Sanitize each line but keep as a flat newline-delimited string.
    -- Nested Lua arrays in world-object modData don't survive the Java
    -- round-trip after transmitModData, so we never store arrays here.
    local rawLines = {}
    for line in (linesStr .. "\n"):gmatch("(.-)\n") do
        rawLines[#rawLines + 1] = tostring(line):gsub("[%c]", " "):sub(1, WHITEBOARD_MAX_LEN_SRV)
        if #rawLines >= WHITEBOARD_LINES_SRV then break end
    end

    local md = obj:getModData()
    -- Store each line under its own flat key (no delimiter) so values survive
    -- the Java modData serialization round-trip without issues.
    for i = 1, WHITEBOARD_LINES_SRV do
        md["csrWbLine" .. i] = rawLines[i] or ""
    end
    md.csrWbEditor = player:getUsername()
    if obj.transmitModData then obj:transmitModData() end
    sendResult(player, "Whiteboard saved.")
end

-- =====================================================================
-- Rally Point Beacon
-- Client sends ShareRallyPoint {x, y, z, label}  (MP only)
-- Server broadcasts the waypoint to all online players.
-- =====================================================================
-- Per-player rate limit: max 1 share / 10 sec. Anti-spam.
local _rallyLastShareSec = {}

local function _rallyTooSoon(username)
    if not username or username == "" then return false end
    local now = (os and os.time and os.time()) or 0
    local last = _rallyLastShareSec[username] or 0
    if (now - last) < 10 then return true end
    _rallyLastShareSec[username] = now
    return false
end

local function _rallyServerInventoryHas(player, types)
    if not player or not player.getInventory then return false end
    local inv = player:getInventory()
    if not inv then return false end
    for i = 1, #types do
        if inv:containsType(types[i]) or inv:containsTypeRecurse(types[i]) then return true end
    end
    return false
end

local function _rallyPlayerFactionName(player)
    if not Faction or not Faction.getPlayerFaction then return nil end
    local fac = Faction.getPlayerFaction(player)
    if not fac or not fac.getName then return nil end
    return fac:getName()
end

local function _rallyPlayersInSameFaction(player)
    local list = {}
    local fname = _rallyPlayerFactionName(player)
    if not fname then return list end
    local online = getOnlinePlayers and getOnlinePlayers() or nil
    if not online then return list end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        if p and _rallyPlayerFactionName(p) == fname then
            table.insert(list, p)
        end
    end
    return list
end

local function _rallyPlayersInSameSafehouse(player)
    local list = {}
    if not SafeHouse or not SafeHouse.hasSafehouse then return list end
    local sh = SafeHouse.hasSafehouse(player)
    if not sh or not sh.getPlayers then return list end
    local online = getOnlinePlayers and getOnlinePlayers() or nil
    if not online then return list end
    local members = sh:getPlayers()
    if not members then return list end
    local memberSet = {}
    for i = 0, members:size() - 1 do memberSet[tostring(members:get(i))] = true end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local uname = p and p.getUsername and p:getUsername() or nil
        if uname and memberSet[tostring(uname)] then
            table.insert(list, p)
        end
    end
    return list
end

function CSR_ServerCommands.handleShareRallyPoint(player, args)
    if not CSR_FeatureFlags.isRallyPointsEnabled() then return end

    local x = tonumber(args and args.x)
    local y = tonumber(args and args.y)
    local z = tonumber(args and args.z) or 0
    if not x or not y then return end

    local senderName = player and player.getUsername and player:getUsername() or "?"

    -- Rate-limit
    if _rallyTooSoon(senderName) then return end

    -- Server-side pencil re-validation (defence in depth)
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    if sb.RallyRequirePencil ~= false then
        local PENCIL_TYPES = { "Base.Pencil", "Base.Pen", "Base.RedPen", "Base.BluePen", "Base.GreenPen" }
        if not _rallyServerInventoryHas(player, PENCIL_TYPES) then return end
    end

    -- Sanitise label
    local label = tostring(args and args.label or ""):gsub("[%c]", ""):sub(1, 48)
    local scope = tostring(args and args.scope or "everyone")
    local target = tostring(args and args.targetUsername or "")

    -- Build recipient list per scope
    local recipients = {}
    if scope == "self" then
        table.insert(recipients, player)
    elseif scope == "faction" then
        recipients = _rallyPlayersInSameFaction(player)
        if #recipients == 0 then table.insert(recipients, player) end
    elseif scope == "safehouse" then
        recipients = _rallyPlayersInSameSafehouse(player)
        if #recipients == 0 then table.insert(recipients, player) end
    elseif scope == "player" then
        local online = getOnlinePlayers and getOnlinePlayers() or nil
        if online then
            for i = 0, online:size() - 1 do
                local p = online:get(i)
                local uname = p and p.getUsername and p:getUsername() or nil
                if uname and tostring(uname) == target then
                    table.insert(recipients, p)
                    break
                end
            end
        end
        -- Always include sender so they see their own pin
        table.insert(recipients, player)
    else
        -- "everyone"
        local online = getOnlinePlayers and getOnlinePlayers() or nil
        if online then
            for i = 0, online:size() - 1 do
                local p = online:get(i)
                if p then table.insert(recipients, p) end
            end
        end
    end

    for i = 1, #recipients do
        local p = recipients[i]
        if p then
            sendServerCommand(p, "CommonSenseLight", "RallyPointReceived", {
                x = x,
                y = y,
                z = z,
                label = label,
                senderName = senderName,
            })
        end
    end
end

-- =====================================================================
-- Survivor Bond server-side tick
-- =====================================================================
local survivorBondAccum = 0.0
-- Per-player proximity timers keyed by online ID
local bondProximityTime = {}

local function clampBond(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function onSurvivorBondTick()
    if not CSR_FeatureFlags.isSurvivorBondEnabled() then return end
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}

    survivorBondAccum = survivorBondAccum + (1.0 / 30.0)
    if survivorBondAccum < 0.25 then return end
    local dt = survivorBondAccum
    survivorBondAccum = 0.0

    local bondRadius    = tonumber(sb.SurvivorBondRadius)    or 10
    local bondThreshold = tonumber(sb.SurvivorBondThreshold) or 120
    local r2 = bondRadius * bondRadius

    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players or players:size() < 2 then
        -- Clear timers when nobody is around
        bondProximityTime = {}
        return
    end

    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local pid = p.getOnlineID and p:getOnlineID() or tostring(p)
            local sq  = p.getSquare and p:getSquare()
            if sq then
                local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
                local nearAlly = false

                for j = 0, players:size() - 1 do
                    if j ~= i then
                        local o = players:get(j)
                        if o and not o:isDead() then
                            local osq = o.getSquare and o:getSquare()
                            if osq and osq:getZ() == pz then
                                local dx = px - osq:getX()
                                local dy = py - osq:getY()
                                if (dx * dx + dy * dy) <= r2 then
                                    nearAlly = true
                                    break
                                end
                            end
                        end
                    end
                end

                if nearAlly then
                    bondProximityTime[pid] = (bondProximityTime[pid] or 0) + dt
                    if bondProximityTime[pid] > bondThreshold then
                        bondProximityTime[pid] = bondThreshold
                    end
                else
                    bondProximityTime[pid] = 0.0
                end

                local strength = clampBond((bondProximityTime[pid] or 0) / bondThreshold, 0.0, 1.0)
                if strength > 0.0 then
                    local stats = p.getStats and p:getStats()
                    if stats then
                        -- Use B42 CharacterStat API (same as CSR_SleepBenefits)
                        if CharacterStat then
                            if stats.get and stats.remove then
                                if sb.SurvivorBondReduceStress   ~= false then
                                    local v = stats:get(CharacterStat.STRESS)
                                    if v and v > 0 then stats:remove(CharacterStat.STRESS,    clampBond(0.05 * strength * dt, 0, v)) end
                                end
                                if sb.SurvivorBondReduceBoredom  ~= false then
                                    local v = stats:get(CharacterStat.BOREDOM)
                                    if v and v > 0 then stats:remove(CharacterStat.BOREDOM,   clampBond(0.4  * strength * dt, 0, v)) end
                                end
                                if sb.SurvivorBondReduceFatigue  ~= false then
                                    local v = stats:get(CharacterStat.FATIGUE)
                                    if v and v > 0 then stats:remove(CharacterStat.FATIGUE,   clampBond(0.01 * strength * dt, 0, v)) end
                                end
                                if sb.SurvivorBondReduceUnhappy  ~= false then
                                    local v = stats:get(CharacterStat.UNHAPPINESS)
                                    if v and v > 0 then stats:remove(CharacterStat.UNHAPPINESS, clampBond(0.3 * strength * dt, 0, v)) end
                                end
                            end
                        end

                        -- Notify client to show HUD badge (once per second approximation)
                        if strength >= 1.0 then
                            sendServerCommand(p, "CommonSenseLight", "SurvivorBondActive", { strength = strength })
                        end
                    end
                else
                    -- Tell client buff is inactive
                    sendServerCommand(p, "CommonSenseLight", "SurvivorBondActive", { strength = 0 })
                end
            end
        end
    end
end

if Events and Events.OnTick and not CSR_ServerCommands._bondTickRegistered then
    CSR_ServerCommands._bondTickRegistered = true
    Events.OnTick.Add(onSurvivorBondTick)
end

function CSR_ServerCommands.handlePurgeFireworks(player, args)
    local access = player and player.getAccessLevel and player:getAccessLevel() or ""
    if access ~= "admin" and access ~= "Admin" then
        print("[CSR] PurgeFireworks denied for non-admin: " .. tostring(access))
        return
    end

    local totalRemoved = 0

    -- 1) Purge from all online players' inventories
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then
                local inv = p:getInventory()
                if inv then
                    local removed = removeFireworksFromContainer(inv)
                    if removed > 0 then
                        totalRemoved = totalRemoved + removed
                        syncPlayerInventory(p)
                        local pName = p.getUsername and p:getUsername() or "?"
                        print("[CSR] PurgeFireworks: removed " .. removed .. " from player " .. pName)
                    end
                end
            end
        end
    end

    -- 2) Purge from world containers in all loaded cells
    local cell = getCell and getCell() or nil
    if cell then
        -- B42.17: getObjectList() renamed to getObjectListForLua()
        local objects = (cell.getObjectListForLua and cell:getObjectListForLua()) or cell:getObjectList()
        if objects then
            for i = 0, objects:size() - 1 do
                local obj = objects:get(i)
                if obj then
                    local containerCount = obj.getContainerCount and obj:getContainerCount() or 0
                    for c = 0, containerCount - 1 do
                        local container = obj:getContainerByIndex(c)
                        if container then
                            totalRemoved = totalRemoved + removeFireworksFromContainer(container)
                        end
                    end
                end
            end
        end
    end

    print("[CSR] PurgeFireworks complete: " .. totalRemoved .. " fireworks removed")
    sendResult(player, "Purged " .. totalRemoved .. " Distraction Firework(s) from all players and loaded world containers")
end

-- ─── End Admin: Purge All Fireworks ──────────────────────────────────

-- =============================================
-- FRIDGE / FREEZER POWER TOGGLE
-- =============================================

function CSR_ServerCommands.handleFridgeToggle(player, args)
    if not args or args.x == nil or args.y == nil or args.z == nil then return end
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    if sb.EnableFridgeToggle == false then return end

    local x, y, z = args.x, args.y, args.z
    local gridSquare = getWorld():getCell():getGridSquare(x, y, z)
    if not gridSquare then
        print("[CSR] FridgeToggle: square not found at " .. x .. "," .. y .. "," .. z)
        return
    end

    local objects = gridSquare:getObjects()
    if not objects then return end

    local object = nil
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if o and o.getContainerCount and o:getContainerCount() > 0 then
            local found = o:getContainerByType("fridge")      ~= nil
                or o:getContainerByType("fridge_off")  ~= nil
                or o:getContainerByType("freezer")     ~= nil
                or o:getContainerByType("freezer_off") ~= nil
            if found then object = o; break end
        end
    end

    if not object then return end

    local fridgeState  = "empty"
    local freezerState = "empty"
    if object:getContainerByType("fridge") then
        object:getContainerByType("fridge"):setType("fridge_off")
        fridgeState = "off"
    elseif object:getContainerByType("fridge_off") then
        object:getContainerByType("fridge_off"):setType("fridge")
        fridgeState = "on"
    end
    if object:getContainerByType("freezer") then
        object:getContainerByType("freezer"):setType("freezer_off")
        freezerState = "off"
    elseif object:getContainerByType("freezer_off") then
        object:getContainerByType("freezer_off"):setType("freezer")
        freezerState = "on"
    end

    if object.checkHaveElectricity then object:checkHaveElectricity() end

    -- Update nearby generators in a 40x40 radius
    local cx, cy = x, y
    local src = object:getContainer() and object:getContainer():getSourceGrid()
    if src then cx, cy = src:getX(), src:getY() end
    for gx = cx - 20, cx + 20 do
        for gy = cy - 20, cy + 20 do
            if IsoUtils.DistanceToSquared(gx + 0.5, gy + 0.5, cx + 0.5, cy + 0.5) <= 400.0 then
                local sq = getWorld():getCell():getGridSquare(gx, gy, z)
                if sq then
                    for i = 0, sq:getObjects():size() - 1 do
                        local o = sq:getObjects():get(i)
                        if o and instanceof(o, "IsoGenerator") then
                            o:setSurroundingElectricity()
                        end
                    end
                end
            end
        end
    end

    if isServer() then
        -- Broadcast new state to all clients
        local players = getOnlinePlayers()
        if players then
            for i = 0, players:size() - 1 do
                local p = players:get(i)
                if p then
                    sendServerCommand(p, "CommonSenseLight", "FridgeSynced", {
                        x = x, y = y, z = z,
                        fridge  = fridgeState,
                        freezer = freezerState,
                    })
                end
            end
        end
    else
        -- SP: refresh inventory UI directly
        local playerData = getPlayerData(getPlayer():getPlayerNum())
        if playerData then
            if playerData.playerInventory then playerData.playerInventory:refreshBackpacks() end
            if playerData.lootInventory then playerData.lootInventory:refreshBackpacks() end
        end
    end
end

-- ─────────────────────────────────────────────────────
-- Barrel cap toggle
-- Restores the cap/uncap option after a barrel is moved via Move
-- Furniture (some third-party barrel mods drop their custom context
-- option after the IsoObject is reconstructed). This handler writes
-- a flat csrBarrelCapped flag into the world object's modData and
-- locks/unlocks fluid input on the FluidContainer component, then
-- broadcasts via transmitModData so all clients see the change.
function CSR_ServerCommands.handleBarrelCap(player, args)
    if not player or not args then return end
    if not args.x or not args.y or not args.z then return end
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    if sb.EnableBarrelCapFix == false then return end
    if not isNearPlayer(player, args) then return end

    local sq = getWorld():getCell():getGridSquare(args.x, args.y, args.z)
    if not sq then return end
    local objects = sq:getObjects()
    if not objects then return end

    local target = nil
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if o and o.getFluidContainer and o:getFluidContainer() then
            local sprite = o:getSprite() and o:getSprite():getName() or ""
            if args.spriteName == nil or args.spriteName == sprite then
                target = o
                break
            end
        end
    end
    if not target then return end

    local md = target:getModData()
    md.csrBarrelCapped = (args.capped == true)
    local fc = target:getFluidContainer()
    if fc and fc.setInputLocked then fc:setInputLocked(md.csrBarrelCapped) end
    if fc and fc.setOutputLocked then fc:setOutputLocked(md.csrBarrelCapped) end
    if target.transmitModData then target:transmitModData() end
end

-- ─────────────────────────────────────────────────────
-- Fire Trail — gasoline path painting + bounded BFS chain ignition.
-- Paints individual squares (proximity-validated) and ignites a
-- connected painted region with a hard length cap to prevent grief.
-- ─────────────────────────────────────────────────────
local FIRE_TRAIL_KEY = "csrFireTrail"

local function fireTrailMaxLength()
    return tonumber((sandbox()).FireTrailMaxLength) or 25
end

local function fireTrailEnabled()
    return (sandbox()).EnableFireTrail ~= false
end

local function fireTrailRequiresAdmin()
    return (sandbox()).FireTrailRequiresAdmin == true
end

function CSR_ServerCommands.handleFireTrailPaint(player, args)
    if not fireTrailEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end
    local sq = getWorld():getCell():getGridSquare(args.x, args.y, args.z)
    if not sq then return end
    local md = sq:getModData()
    md[FIRE_TRAIL_KEY] = true
    if sq.RecalcAllWithNeighbours then
        sq:RecalcAllWithNeighbours(true)
    end
    if isServer() then
        sendServerCommand("CommonSenseLight", "FireTrailSquareSync", {
            x = args.x, y = args.y, z = args.z, painted = true
        })
    end
end

local function isAdminAccess(player)
    if not player then return false end
    local lvl = player.getAccessLevel and player:getAccessLevel() or nil
    return lvl == "admin" or lvl == "Admin"
end

function CSR_ServerCommands.handleFireTrailIgnite(player, args)
    if not fireTrailEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end
    if fireTrailRequiresAdmin() and not isAdminAccess(player) then return end

    local cell = getWorld():getCell()
    local startSq = cell:getGridSquare(args.x, args.y, args.z)
    if not startSq then return end
    local startMd = startSq:getModData()
    if not startMd or startMd[FIRE_TRAIL_KEY] ~= true then return end

    local seen = {}
    local function key(sq) return tostring(sq:getX()) .. "," .. tostring(sq:getY()) .. "," .. tostring(sq:getZ()) end
    local queue = { startSq }
    local head = 1
    local lit = 0
    local maxN = fireTrailMaxLength()
    while queue[head] and lit < maxN do
        local sq = queue[head]; head = head + 1
        local k = key(sq)
        if not seen[k] then
            local md = sq:getModData()
            if md and md[FIRE_TRAIL_KEY] == true then
                seen[k] = true
                IsoFireManager.StartFire(cell, sq, true, 100, 350)
                md[FIRE_TRAIL_KEY] = nil
                if sq.RecalcAllWithNeighbours then
                    sq:RecalcAllWithNeighbours(true)
                end
                if isServer() then
                    sendServerCommand("CommonSenseLight", "FireTrailSquareSync", {
                        x = sq:getX(), y = sq:getY(), z = sq:getZ(), painted = false
                    })
                end
                lit = lit + 1
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        if not (dx == 0 and dy == 0) then
                            local nb = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
                            if nb and not seen[key(nb)] then
                                queue[#queue + 1] = nb
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ─────────────────────────────────────────────────────
-- Power Line — per-square blue cord (replacement for old PowerBar registry).
-- Client paints squares while walking; server flips modData and pushes it
-- back to all clients via transmitModData. End command consumes one
-- Base.PowerBar from the player's inventory and converts every painted
-- square along the chain (BFS-connected from the destination) to a
-- permanently powered tile.
-- ─────────────────────────────────────────────────────
local function powerLineEnabled()
    return CSR_PowerLine and CSR_PowerLine.isEnabled and CSR_PowerLine.isEnabled() or false
end

local function powerLineMaxLength()
    return CSR_PowerLine and CSR_PowerLine.maxLineLength and CSR_PowerLine.maxLineLength() or 24
end

local function syncPowerLineVisual(square)
    if CSR_PowerLineSprites and CSR_PowerLineSprites.syncAround then
        CSR_PowerLineSprites.syncAround(square)
    end
end

function CSR_ServerCommands.handlePowerLinePaint(player, args)
    if not powerLineEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end
    local cell = getWorld() and getWorld():getCell() or nil
    if not cell then return end
    local sq = cell:getGridSquare(args.x, args.y, args.z)
    if not sq then return end
    local md = sq:getModData()
    if not md then return end
    md[CSR_PowerLine.PAINT_KEY] = true
    syncPowerLineVisual(sq)
    -- IsoGridSquare has no transmitModData(); broadcast a flat command
    -- and let each client mirror the flag onto its own square's modData.
    if isServer() then
        sendServerCommand("CommonSenseLight", "PowerLineSquareSync", {
            x = args.x, y = args.y, z = args.z, paint = true, power = false
        })
    end
end

function CSR_ServerCommands.handlePowerLineCancel(player, args)
    if not powerLineEnabled() then return end
    -- No-op on the server: the painter just stops, and EveryHours will
    -- eventually time out abandoned trail tiles. Cheap.
end

-- Remove a connected powered chain (BFS from the right-clicked square).
-- Used by the world context menu's "Remove Wiring" option.
function CSR_ServerCommands.handlePowerLineRemove(player, args)
    if not powerLineEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end
    local cell = getWorld() and getWorld():getCell() or nil
    if not cell then return end
    local startSq = cell:getGridSquare(args.x, args.y, args.z)
    if not startSq then return end
    local startMd = startSq:getModData()
    if not startMd or startMd[CSR_PowerLine.POWER_KEY] ~= true then return end

    local function key(sq) return tostring(sq:getX()) .. "," .. tostring(sq:getY()) .. "," .. tostring(sq:getZ()) end
    local seen = {}
    local q = { startSq }
    local h = 1
    local removed = 0
    local maxN = powerLineMaxLength() + 8
    while q[h] and removed < maxN do
        local sq = q[h]; h = h + 1
        local k = key(sq)
        if not seen[k] then
            seen[k] = true
            local md = sq:getModData()
            if md and md[CSR_PowerLine.POWER_KEY] == true then
                md[CSR_PowerLine.POWER_KEY] = nil
                md[CSR_PowerLine.PAINT_KEY] = nil
                syncPowerLineVisual(sq)
                if isServer() then
                    sendServerCommand("CommonSenseLight", "PowerLineSquareSync", {
                        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                        paint = false, power = false, clear = true, clearPower = true
                    })
                end
                removed = removed + 1
                for dx = -1, 1 do for dy = -1, 1 do
                    if not (dx == 0 and dy == 0) then
                        local nb = cell:getGridSquare(sq:getX()+dx, sq:getY()+dy, sq:getZ())
                        if nb then q[#q+1] = nb end
                    end
                end end
            end
        end
    end
end

-- Toggle the manual breaker on a connected wiring chain (BFS from the
-- right-clicked tile through every csr-powered neighbour). Lets the
-- player turn the whole run on or off without tearing it up.
function CSR_ServerCommands.handlePowerLineToggle(player, args)
    if not powerLineEnabled() then return end
    if not args or args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end
    local cell = getWorld() and getWorld():getCell() or nil
    if not cell then return end
    local startSq = cell:getGridSquare(args.x, args.y, args.z)
    if not startSq then return end
    local sMd = startSq:getModData()
    if not sMd or sMd[CSR_PowerLine.POWER_KEY] ~= true then return end

    local targetOff
    if args.off ~= nil then targetOff = (args.off == true)
    else                    targetOff = sMd[CSR_PowerLine.DISABLED_KEY] ~= true end

    local function key(sq) return tostring(sq:getX()) .. "," .. tostring(sq:getY()) .. "," .. tostring(sq:getZ()) end
    local seen = {}
    local q = { startSq }
    local h = 1
    local touched = 0
    local maxN = powerLineMaxLength() + 8
    while q[h] and touched < maxN do
        local sq = q[h]; h = h + 1
        local k = key(sq)
        if not seen[k] then
            seen[k] = true
            local md = sq:getModData()
            if md and md[CSR_PowerLine.POWER_KEY] == true then
                if targetOff then md[CSR_PowerLine.DISABLED_KEY] = true
                else              md[CSR_PowerLine.DISABLED_KEY] = nil end
                syncPowerLineVisual(sq)
                if isServer() then
                    sendServerCommand("CommonSenseLight", "PowerLineSquareSync", {
                        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                        toggleOff = targetOff and true or false
                    })
                end
                touched = touched + 1
                for dx = -1, 1 do for dy = -1, 1 do
                    if not (dx == 0 and dy == 0) then
                        local nb = cell:getGridSquare(sq:getX()+dx, sq:getY()+dy, sq:getZ())
                        if nb then q[#q+1] = nb end
                    end
                end end
            end
        end
    end
end

function CSR_ServerCommands.handlePowerLineEnd(player, args)
    if not powerLineEnabled() then return end
    if not player or not args or args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end

    -- Consume one Base.PowerBar.
    local inv = player.getInventory and player:getInventory() or nil
    if not inv then return end
    local bar = inv:getFirstTypeRecurse("PowerBar")
    if not bar then
        sendResult(player, getText("Tooltip_CSR_PowerLine_NoBar") or "No Power Bar.")
        return
    end

    local cell = getWorld() and getWorld():getCell() or nil
    if not cell then return end
    local endSq = cell:getGridSquare(args.x, args.y, args.z)
    if not endSq then return end

    -- BFS from the end through painted-trail-or-already-powered squares.
    -- Convert every visited painted-trail tile to a permanent powered tile.
    -- The destination always becomes powered, even if not pre-painted.
    local function key(sq) return tostring(sq:getX()) .. "," .. tostring(sq:getY()) .. "," .. tostring(sq:getZ()) end
    local seen = {}
    local queue = { endSq }
    local head = 1
    local converted = 0
    local maxN = powerLineMaxLength() + 4

    -- Always energize the destination tile.
    local endMd = endSq:getModData()
    if endMd then
        endMd[CSR_PowerLine.POWER_KEY] = true
        endMd[CSR_PowerLine.PAINT_KEY] = nil
    end
    syncPowerLineVisual(endSq)
    seen[key(endSq)] = true
    if isServer() then
        sendServerCommand("CommonSenseLight", "PowerLineSquareSync", {
            x = endSq:getX(), y = endSq:getY(), z = endSq:getZ(),
            paint = false, power = true
        })
    end
    converted = 1

    while queue[head] and converted < maxN do
        local sq = queue[head]; head = head + 1
        for dx = -1, 1 do
            for dy = -1, 1 do
                if not (dx == 0 and dy == 0) then
                    local nb = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
                    if nb then
                        local k = key(nb)
                        if not seen[k] then
                            local md = nb:getModData()
                            if md and md[CSR_PowerLine.PAINT_KEY] == true then
                                md[CSR_PowerLine.POWER_KEY] = true
                                md[CSR_PowerLine.PAINT_KEY] = nil
                                syncPowerLineVisual(nb)
                                if isServer() then
                                    sendServerCommand("CommonSenseLight", "PowerLineSquareSync", {
                                        x = nb:getX(), y = nb:getY(), z = nb:getZ(),
                                        paint = false, power = true
                                    })
                                end
                                seen[k] = true
                                converted = converted + 1
                                queue[#queue + 1] = nb
                            end
                        end
                    end
                end
            end
        end
    end

    -- Clean up any orphan painted-trail tiles within range that did not
    -- BFS-connect to the destination (player walked off and came back, etc).
    local r = powerLineMaxLength() + 2
    local px, py, pz = endSq:getX(), endSq:getY(), endSq:getZ()
    for x = px - r, px + r do
        for y = py - r, py + r do
            local s2 = cell:getGridSquare(x, y, pz)
            if s2 and not seen[key(s2)] then
                local md = s2:getModData()
                if md and md[CSR_PowerLine.PAINT_KEY] == true then
                    md[CSR_PowerLine.PAINT_KEY] = nil
                    syncPowerLineVisual(s2)
                    if isServer() then
                        sendServerCommand("CommonSenseLight", "PowerLineSquareSync", {
                            x = x, y = y, z = pz, paint = false, power = false, clear = true
                        })
                    end
                end
            end
        end
    end

    -- Remove the consumed Power Bar.
    inv:Remove(bar)

    -- Server-side getText() returns the raw key (translation tables only
    -- live on the client), which would render literally in the player's
    -- HUD. Send the English string directly; the client never re-looks
    -- it up, so a translated copy isn't possible here without piping
    -- the lookup through a client event. Plain English is acceptable.
    sendResult(player, "Cord laid. Tile is energized.")
end

-- ─────────────────────────────────────────────────────
-- Outfit Sets — server mirrors player ModData saves so they survive
-- reconnection and admin save/load. Client owns the heavy lifting
-- (search pool, action queue); server just persists the slot table.
-- ─────────────────────────────────────────────────────
function CSR_ServerCommands.handleOutfitSetSave(player, args)
    if not player or not args or not args.name or args.name == "" then return end
    local md = player:getModData()
    md.csrOutfitSets = md.csrOutfitSets or {}
    -- Client already wrote the items to the player's local ModData; on the
    -- server we just record the slot existed with its category so a future
    -- save/load preserves it.
    md.csrOutfitSets[tostring(args.name)] = md.csrOutfitSets[tostring(args.name)] or {
        category = tostring(args.category or ""),
        items = {},
    }
    md.csrOutfitSets[tostring(args.name)].category = tostring(args.category or "")
    if player.transmitModData then player:transmitModData() end
end

function CSR_ServerCommands.handleOutfitSetDelete(player, args)
    if not player or not args or not args.name then return end
    local md = player:getModData()
    if md.csrOutfitSets then
        md.csrOutfitSets[tostring(args.name)] = nil
        if player.transmitModData then player:transmitModData() end
    end
end

-- ─────────────────────────────────────────────────────
-- Wash All — recursive inventory + body + dirty bandage swap.
-- Server validates proximity to the water source, runs the same recursive
-- wash routine the client preview did, consumes water, and sends visual
-- + inventory + blood-body sync packets so other clients see the result.
-- ─────────────────────────────────────────────────────
local function outfitWardrobePayload(obj, enabled)
    local payload = CSR_OutfitSetsUtil.objectCommandArgs(obj) or {}
    payload.key = CSR_OutfitSetsUtil.objectRegistryKey(obj)
    payload.enabled = enabled == true
    return payload
end

local function sendOutfitWardrobeSync(obj, enabled, targetPlayer)
    if not sendServerCommand then return end
    local payload = outfitWardrobePayload(obj, enabled)
    if targetPlayer then
        sendServerCommand(targetPlayer, "CommonSenseLight", "OutfitWardrobeSync", payload)
    else
        sendServerCommand("CommonSenseLight", "OutfitWardrobeSync", payload)
    end
end

local function validateOutfitWardrobeRequest(player, args)
    if not player or not args then return nil, "" end
    if not CSR_OutfitSetsUtil or not CSR_OutfitSetsUtil.isEnabled() then
        return nil, "Outfit Sets disabled."
    end
    if CSR_OutfitSetsUtil.capacityBonusPct() <= 0 then
        return nil, "Wardrobe capacity bonus is disabled."
    end
    local obj = CSR_OutfitSetsUtil.findWardrobeObjectFromArgs(args)
    if not obj or not CSR_OutfitSetsUtil.isCapacityWardrobeObject(obj) then
        return nil, "Only true wardrobes can become Outfit Wardrobes."
    end
    local sq = obj:getSquare()
    if not sq then return nil, "Wardrobe not found." end
    if not isNearPlayer(player, { x = sq:getX(), y = sq:getY(), z = sq:getZ() }) then
        return nil, "Stand next to the wardrobe."
    end
    if not CSR_OutfitSetsUtil.playerHasSafehouseAccess(player, sq) then
        return nil, "Outfit Wardrobes must be inside your safehouse."
    end
    return obj, nil
end

-- Legacy command kept inert. The old implementation mutated map-object
-- container capacity and transmitted ObjectModData, which could desync or
-- duplicate dismantled drawers in MP.
function CSR_ServerCommands.handleOutfitCapacityBonus(player, args)
    return
end

function CSR_ServerCommands.handleOutfitWardrobeConvert(player, args)
    if not player or not args then return end
    local obj, err = validateOutfitWardrobeRequest(player, args)
    if not obj then
        if err and err ~= "" then sendResult(player, err) end
        return
    end
    local key = CSR_OutfitSetsUtil.objectRegistryKey(obj)
    if key == "" then return end
    CSR_OutfitSetsUtil.setOutfitWardrobeKey(key, true)
    sendOutfitWardrobeSync(obj, true)
    sendResult(player, "Outfit Wardrobe converted.")
end

function CSR_ServerCommands.handleOutfitWardrobeRevert(player, args)
    if not player or not args then return end
    local obj, err = validateOutfitWardrobeRequest(player, args)
    if not obj then
        if err and err ~= "" then sendResult(player, err) end
        return
    end
    local key = CSR_OutfitSetsUtil.objectRegistryKey(obj)
    if key == "" then return end
    CSR_OutfitSetsUtil.setOutfitWardrobeKey(key, false)
    sendOutfitWardrobeSync(obj, false)
    sendResult(player, "Outfit Wardrobe reverted.")
end

function CSR_ServerCommands.handleOutfitWardrobeSyncRequest(player, args)
    if not player or not sendServerCommand then return end
    sendServerCommand(player, "CommonSenseLight", "OutfitWardrobeSyncAll", {
        wardrobes = CSR_OutfitSetsUtil.getOutfitWardrobeSnapshot(),
    })
end

local DIRTY_BANDAGE_SWAP = {
    ["Base.BandageDirty"] = "Base.Bandage",
    ["Base.RippedSheetsDirty"] = "Base.RippedSheets",
    ["Base.DenimBandageDirty"] = "Base.DenimBandage",
    ["Base.LeatherBandageDirty"] = "Base.LeatherBandage",
}

local function washAllGetWaterPerItem()
    return (sandbox().WashAllWaterPerItem or 0.5)
end

local function washAllGetAvailableWater(sink)
    if not sink then return 0 end
    if sink.isWaterSource and sink:isWaterSource() then
        if sink.getWaterAmount then
            local amt = sink:getWaterAmount()
            if amt and amt > 0 then return amt end
        end
        return 9999
    end
    if sink.getFluidContainer then
        local fc = sink:getFluidContainer()
        if fc and fc.getAmount then return fc:getAmount() or 0 end
    end
    if sink.getWaterAmount then return sink:getWaterAmount() or 0 end
    return 0
end

local function washAllConsumeWater(sink, amount)
    if not sink or amount <= 0 then return end
    local fc = sink.getFluidContainer and sink:getFluidContainer() or nil
    if fc and fc.removeFluid then fc:removeFluid(amount); return end
    if fc and fc.adjustAmount then fc:adjustAmount(-amount); return end
    if sink.setWaterAmount and sink.getWaterAmount then
        sink:setWaterAmount(math.max((sink:getWaterAmount() or 0) - amount, 0))
    elseif sink.useWater then
        sink:useWater(math.ceil(amount))
    end
    if sink.transmitModData then sink:transmitModData() end
end

local function washAllItemDirty(item)
    if not item then return false end
    if item.getFullType and DIRTY_BANDAGE_SWAP[item:getFullType()] then return true end
    if instanceof(item, "Clothing") and item.getBloodClothingType
            and BloodClothingType and BloodClothingType.getCoveredParts then
        local bct = item:getBloodClothingType()
        if bct then
            local parts = BloodClothingType.getCoveredParts(bct)
            if parts then
                for j = 0, parts:size() - 1 do
                    local pt = parts:get(j)
                    if (item.getBlood and item:getBlood(pt) > 0)
                        or (item.getDirt and item:getDirt(pt) > 0) then
                        return true
                    end
                end
            end
        end
        if item.getDirtiness and item:getDirtiness() > 0 then return true end
        return false
    end
    if item.getBloodLevel and item:getBloodLevel() > 0 then return true end
    if item.getDirtiness and item:getDirtiness() > 0 then return true end
    return false
end

local function washAllWashItem(item, replaceQueue)
    local ft = item.getFullType and item:getFullType() or nil
    if ft and DIRTY_BANDAGE_SWAP[ft] then
        replaceQueue[#replaceQueue + 1] = { item = item, replacement = DIRTY_BANDAGE_SWAP[ft] }
        return
    end
    if instanceof(item, "Clothing") and item.getBloodClothingType
            and BloodClothingType and BloodClothingType.getCoveredParts then
        local bct = item:getBloodClothingType()
        local parts = bct and BloodClothingType.getCoveredParts(bct) or nil
        if parts then
            for j = 0, parts:size() - 1 do
                local pt = parts:get(j)
                if item.setBlood then item:setBlood(pt, 0) end
                if item.setDirt  then item:setDirt(pt, 0) end
            end
        end
        if item.setDirtiness then item:setDirtiness(0) end
        if item.setWetness   then item:setWetness(100) end
        if item.synchWithVisual then item:synchWithVisual() end
    else
        if item.setBloodLevel then item:setBloodLevel(0) end
        if item.setDirtiness  then item:setDirtiness(0) end
    end
end

local function washAllRecurse(inv, state, visited, replaceQueue)
    if not inv or visited[inv] then return end
    visited[inv] = true
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            if washAllItemDirty(it) and state.waterRemaining >= washAllGetWaterPerItem() then
                washAllWashItem(it, replaceQueue)
                state.waterRemaining = state.waterRemaining - washAllGetWaterPerItem()
            end
            if instanceof(it, "InventoryContainer") then
                local sub = it:getInventory()
                if sub then washAllRecurse(sub, state, visited, replaceQueue) end
            end
        end
    end
end

local function washAllBody(character, state)
    if not BloodBodyPartType or not BloodBodyPartType.MAX then return end
    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        local pt = BloodBodyPartType.FromIndex(i)
        if character.getBloodPartLevel and character:getBloodPartLevel(pt) > 0 and state.waterRemaining >= 0.1 then
            character:setBloodLevel(pt, 0)
            state.waterRemaining = state.waterRemaining - 0.1
        end
        if character.getDirtPartLevel and character:getDirtPartLevel(pt) > 0 and state.waterRemaining >= 0.1 then
            character:setDirtLevel(pt, 0)
            state.waterRemaining = state.waterRemaining - 0.1
        end
    end
end

local function washAllApplyBandageReplacements(character, replaceQueue)
    local inv = character:getInventory()
    for i = 1, #replaceQueue do
        local entry = replaceQueue[i]
        local old = entry.item
        if old and old.getContainer and old:getContainer() then
            local container = old:getContainer()
            local fav = old.isFavorite and old:isFavorite() or false
            container:Remove(old)
            local newItem = inv:AddItem(entry.replacement)
            if newItem and fav and newItem.setFavorite then newItem:setFavorite(true) end
        end
    end
end

local function washAllRefreshBandages(character)
    local bd = character.getBodyDamage and character:getBodyDamage() or nil
    if not bd or not bd.getBodyParts then return end
    local parts = bd:getBodyParts()
    for i = 0, parts:size() - 1 do
        local p = parts:get(i)
        if p and p.bandaged and p:bandaged() and p.getBandageLife and p:getBandageLife() <= 0 then
            p:setBandageLife(15.0)
        end
    end
end

function CSR_ServerCommands.handleWashAll(player, args)
    if not player or not args then return end
    if sandbox().EnableWashAll == false then return end
    if not isNearPlayer(player, args) then return end

    local sq = getWorld():getCell():getGridSquare(args.x, args.y, args.z)
    if not sq then return end
    local sink = nil
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if o and ((o.isWaterSource and o:isWaterSource()) or (o.getFluidContainer and o:getFluidContainer() and o:getFluidContainer():getAmount() > 0)) then
            sink = o; break
        end
    end
    if not sink then return end

    local water = washAllGetAvailableWater(sink)
    if water <= 0 then return end

    local state = { waterRemaining = water }
    local replaceQueue = {}
    local mode = args.mode or "all"
    if mode == "self" or mode == "all" then washAllBody(player, state) end
    if mode == "inventory" or mode == "all" then
        washAllRecurse(player:getInventory(), state, {}, replaceQueue)
        washAllApplyBandageReplacements(player, replaceQueue)
        washAllRefreshBandages(player)
    end

    local consumed = water - state.waterRemaining
    if consumed > 0 then washAllConsumeWater(sink, consumed) end

    if player.resetModelNextFrame then player:resetModelNextFrame() end
    if player.sendVisual then player:sendVisual() end
    if player.sendInventory then player:sendInventory() end
    if player.sendBloodBodyPartSync then player:sendBloodBodyPartSync() end
end

-- ─────────────────────────────────────────────────────
-- Massage MP relay - forward strain-zero command from doctor to patient
-- so the patient's authoritative IsoPlayer state clears its own stiffness.
-- Without this relay the doctor only zeroes a local remote-player copy.
-- ─────────────────────────────────────────────────────
local MASSAGE_SERVER_RANGE = 3

local MASSAGE_SUPPLY_TYPES = {
    ["Butter"] = true,
    ["CookingOil"] = true,
    ["OliveOil"] = true,
    ["VegetableOil"] = true,
}

local function hasMassageSupply(player)
    if not player or not CSR_Utils or not CSR_Utils.findPreferredInventoryItem then return false end
    return CSR_Utils.findPreferredInventoryItem(player, function(item)
        if not item or not item.getType then return false end
        return MASSAGE_SUPPLY_TYPES[item:getType()] == true
    end) ~= nil
end

local function areMassagePlayersClose(doctor, patient)
    if not doctor or not patient then return false end
    if doctor.getZ and patient.getZ and doctor:getZ() ~= patient:getZ() then return false end
    if doctor.DistToSquared and patient.getX and patient.getY then
        return doctor:DistToSquared(patient:getX(), patient:getY()) <= MASSAGE_SERVER_RANGE * MASSAGE_SERVER_RANGE
    end
    return true
end

function CSR_ServerCommands.handleMassageHealStrain(player, args)
    if not player or not args then return end
    if sandbox().EnableMassage == false then return end
    if player.isDead and player:isDead() then return end

    local patientID = tonumber(args.patientID)
    if not patientID then return end

    local patient = findOnlinePlayerByID(patientID)
    if not patient then return end
    if patient == player then return end
    if patient.isDead and patient:isDead() then return end
    if not areMassagePlayersClose(player, patient) then return end
    if not hasMassageSupply(player) then return end

    sendServerCommand(patient, "CommonSenseLight", "MassageStrainHeal", {
        patientID = patientID,
        clearAll = true,
    })
end

-- ─────────────────────────────────────────────────────
-- Jar capping — seal / unseal a jar in the player inventory.
function CSR_ServerCommands.handleJarCap(player, args)
    if not player or not args then return end
    if sandbox().EnableJarCapping == false then return end
    local item = findInventoryItemById(player, args.itemId)
    if not item then return end
    if args.expectedType and item.getFullType and item:getFullType() ~= args.expectedType then return end
    local md = item:getModData()
    if args.cap then
        if md.csrJarSealed then return end
        -- v1.8.34c: recursive lid search. FindAndReturn on the main inventory
        -- only matches top-level items, so a JarLid stowed inside a backpack
        -- was never found and the action ran to completion without consuming
        -- a lid or sealing the jar.
        local lid = nil
        local lidVisited = {}
        local function findLid(inv)
            if not inv or lidVisited[inv] then return nil end
            lidVisited[inv] = true
            local items = inv:getItems()
            if not items then return nil end
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                if it and it.getFullType and it:getFullType() == "Base.JarLid" then return it end
            end
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                if it and instanceof(it, "InventoryContainer") and it.getInventory then
                    local found = findLid(it:getInventory())
                    if found then return found end
                end
            end
            return nil
        end
        lid = findLid(player:getInventory())
        if not lid then
            sendResult(player, "No jar lid available")
            return
        end
        local lidContainer = (lid.getContainer and lid:getContainer()) or player:getInventory()
        lidContainer:Remove(lid)
        md.csrJarSealed = true
        local origName = item.getName and item:getName() or nil
        if origName then md.csrJarOriginalName = origName end
        if item.setName then
            local prefix = "Sealed"
            prefix = srvText("IGUI_CSR_JarSealedPrefix", prefix)
            item:setName(prefix .. " " .. (origName or item:getDisplayName() or "Jar"))
        end
        if item.setCustomName then item:setCustomName(true) end
    else
        if not md.csrJarSealed then return end
        md.csrJarSealed = nil
        if md.csrJarOriginalName and item.setName then
            item:setName(md.csrJarOriginalName)
            md.csrJarOriginalName = nil
            if item.setCustomName then item:setCustomName(false) end
        end
        player:getInventory():AddItem("Base.JarLid")
    end
    -- Push the sealed-state modData and the renamed jar back to the client.
    -- Without this the server quietly seals the jar but the player's UI never
    -- reflects the rename or the sealed flag.
    if item.transmitModData then item:transmitModData() end
    if item.transmitCustomName then item:transmitCustomName() end
    if player.sendInventory then player:sendInventory() end
end

-- ─────────────────────────────────────────────────────
-- Russian Roulette session — server-authoritative state.
-- A session pre-rolls a hidden kill chamber 1..6 at creation time. Each
-- pull rolls 1..6 server-side; if it equals the kill chamber the firing
-- player dies in their own client via the timed-action animation event.
-- All randomness is server-side. Clients only render outcomes.
-- ─────────────────────────────────────────────────────
local rouletteSessions = rouletteSessions or {}
local rouletteNextId = rouletteNextId or 1
local ROULETTE_REVOLVERS = {
    ["Base.Revolver"] = true,
    ["Base.Revolver_Long"] = true,
    ["Base.Revolver_Short"] = true,
}
local ROULETTE_ANIMS = { "CSR_Roulette_Handgun", "CSR_Roulette_Handgun_02", "CSR_Roulette_Handgun_03" }

local function rouletteFindPlayer(username)
    if not username then return nil end
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername() == username then return p end
    end
    return nil
end

local function rouletteHasRevolverWithRound(playerObj)
    if not playerObj then return false end
    local weapon = playerObj.getPrimaryHandItem and playerObj:getPrimaryHandItem() or nil
    if not weapon or not weapon.getFullType then return false end
    if not ROULETTE_REVOLVERS[weapon:getFullType()] then return false end
    local ammo = weapon.getCurrentAmmoCount and weapon:getCurrentAmmoCount() or 0
    return ammo > 0, weapon
end

local function rouletteBroadcastUpdate(session)
    for _, name in ipairs(session.players) do
        local p = rouletteFindPlayer(name)
        if p then
            sendServerCommand(p, "CommonSenseLight", "RouletteUpdate", {
                sessionId = session.id,
                players = session.players,
                turnIndex = session.turnIndex,
                round = session.round,
                status = session.status,
            })
        end
    end
end

local function rouletteBroadcastEnd(session, reason, deadPlayer)
    for _, name in ipairs(session.players) do
        local p = rouletteFindPlayer(name)
        if p then
            sendServerCommand(p, "CommonSenseLight", "RouletteEnd", {
                sessionId = session.id, reason = reason, deadPlayer = deadPlayer,
            })
        end
    end
    rouletteSessions[session.id] = nil
end

local function rouletteRealDeathEnabled()
    local cfg = SandboxVars and SandboxVars.CommonSenseLight or nil
    return cfg and cfg.RouletteRealDeath == true
end

local function rouletteApplyRealDeath(player)
    if not player or (player.isDead and player:isDead()) then return end
    if player.getBodyDamage and BodyPartType then
        local bd = player:getBodyDamage()
        local head = bd and bd.getBodyPart and bd:getBodyPart(BodyPartType.Head) or nil
        if head and head.setHaveBullet then
            head:setHaveBullet(true, 0)
        end
    end
    if player.splatBloodFloorBig then
        player:splatBloodFloorBig()
    end
    if player.Kill then
        player:Kill(player)
    end
end

local function rouletteAdvanceTurn(session)
    session.turnIndex = session.turnIndex + 1
    if session.turnIndex > #session.players then
        session.turnIndex = 1
        session.round = (session.round or 1) + 1
        if sandbox().RouletteRerollEachLap == true then
            session.kill = ZombRand(6) + 1
        end
    end
end

function CSR_ServerCommands.handleRouletteCreate(player, args)
    if not player or not args then return end
    if sandbox().EnableRouletteSession == false then return end
    if not args.invitees or #args.invitees == 0 then return end
    local hasRound, _ = rouletteHasRevolverWithRound(player)
    if not hasRound then
        sendResult(player, "Need a loaded revolver in your primary hand.")
        return
    end
    local id = rouletteNextId; rouletteNextId = rouletteNextId + 1
    local session = {
        id = id,
        host = player:getUsername(),
        players = { player:getUsername() },
        accepted = { [player:getUsername()] = true },
        turnIndex = 1,
        round = 1,
        status = "waiting",
        kill = ZombRand(6) + 1,
        pendingInvites = {},
    }
    for _, name in ipairs(args.invitees) do
        if name ~= session.host then
            session.pendingInvites[name] = true
            local target = rouletteFindPlayer(name)
            if target then
                sendServerCommand(target, "CommonSenseLight", "RouletteInvite", {
                    sessionId = id, hostName = session.host,
                })
            end
        end
    end
    rouletteSessions[id] = session
end

function CSR_ServerCommands.handleRouletteRespond(player, args)
    if not player or not args or not args.sessionId then return end
    local session = rouletteSessions[args.sessionId]
    if not session then return end
    local name = player:getUsername()
    if not session.pendingInvites[name] then return end
    session.pendingInvites[name] = nil
    if args.accept == true then
        local hasRound, _ = rouletteHasRevolverWithRound(player)
        if not hasRound then
            sendResult(player, "You need a loaded revolver.")
            return
        end
        session.players[#session.players + 1] = name
        session.accepted[name] = true
    end
    -- Start once at least 2 players accepted and no invites pending
    local pendingCount = 0
    for _ in pairs(session.pendingInvites) do pendingCount = pendingCount + 1 end
    if pendingCount == 0 then
        if #session.players >= 2 then
            session.status = "active"
            rouletteBroadcastUpdate(session)
        else
            rouletteBroadcastEnd(session, "no-takers", nil)
        end
    end
end

function CSR_ServerCommands.handleRouletteFire(player, args)
    if not player or not args or not args.sessionId then return end
    local session = rouletteSessions[args.sessionId]
    if not session or session.status ~= "active" then return end
    local turnPlayer = session.players[session.turnIndex]
    if turnPlayer ~= player:getUsername() then return end
    local hasRound, weapon = rouletteHasRevolverWithRound(player)
    if not hasRound or not weapon then
        sendResult(player, "Empty cylinder.")
        return
    end

    -- The revolver's loaded round is an eligibility/roleplay requirement, not
    -- per-turn fuel. Roulette itself is a hidden server roll; consuming ammo
    -- here makes a one-round revolver fail after the first safe click.
    local roll = ZombRand(6) + 1
    local killOutcome = (roll == session.kill)
    local anim = ROULETTE_ANIMS[ZombRand(#ROULETTE_ANIMS) + 1]
    local realDeath = rouletteRealDeathEnabled()

    -- Broadcast outcome to all session players (including the firing one)
    for _, name in ipairs(session.players) do
        local p = rouletteFindPlayer(name)
        if p then
            sendServerCommand(p, "CommonSenseLight", "RouletteOutcome", {
                sessionId = session.id,
                firingPlayer = turnPlayer,
                killOutcome = killOutcome,
                realDeath = realDeath,
                anim = anim,
                message = killOutcome and (turnPlayer .. " drew the bullet.") or (turnPlayer .. ": click."),
            })
        end
    end

    if killOutcome then
        session.status = "ended"
        rouletteBroadcastEnd(session, "kill", turnPlayer)
        if realDeath then
            rouletteApplyRealDeath(player)
        end
        return
    end

    rouletteAdvanceTurn(session)
    rouletteBroadcastUpdate(session)
end

function CSR_ServerCommands.handleRouletteLeave(player, args)
    if not player or not args or not args.sessionId then return end
    local session = rouletteSessions[args.sessionId]
    if not session then return end
    local name = player:getUsername()
    local idx = nil
    for i, n in ipairs(session.players) do if n == name then idx = i; break end end
    if not idx then return end
    table.remove(session.players, idx)
    if idx <= session.turnIndex and session.turnIndex > 1 then
        session.turnIndex = session.turnIndex - 1
    end
    if session.turnIndex > #session.players then session.turnIndex = 1 end
    if #session.players < 2 then
        rouletteBroadcastEnd(session, "abandoned", nil)
    else
        rouletteBroadcastUpdate(session)
    end
end

-- ─────────────────────────────────────────────────────
-- Last-Resort Field Dress — chop a corpse for crude meat + bone.
-- Dedicated CSR food items carry eating penalties; corpse type is server-decided.
-- ─────────────────────────────────────────────────────
local function fieldDressClassifyBody(body)
    if not body then return nil end
    if body.isAnimal and body:isAnimal() then return nil end
    if body.isZombie and body:isZombie() then return "zombie" end
    if body.isSkeleton and body:isSkeleton() then return "zombie" end
    return "human"
end

local function fieldDressMeatType(kind)
    if kind == "human" then
        return "Base.CSR_HumanFlesh"
    end
    return "Base.CSR_ZombieFlesh"
end

local function fieldDressClampInt(value, minValue, maxValue, defaultValue)
    local result = tonumber(value) or defaultValue
    result = math.floor(result)
    if result < minValue then result = minValue end
    if result > maxValue then result = maxValue end
    return result
end

local function fieldDressAgeMeat(meat, freshChance)
    if not meat then return end
    if not instanceof(meat, "Food") then return end
    local roll = ZombRand(100)
    if roll < (freshChance or 15) then return end -- stays fresh
    local off = meat:getOffAge()
    local offMax = meat:getOffAgeMax()
    if off and offMax and offMax > off then
        -- Push age into the rotting band: most of the way between off and offMax.
        local pushed = off + (offMax - off) * (0.55 + ZombRandFloat(0, 0.35))
        meat:setAge(pushed)
    end
end

local function fieldDressAddCharacterStat(player, stat, amount)
    if not player or not CharacterStat or not stat then return false end
    local stats = player.getStats and player:getStats() or nil
    if not stats or not stats.get or not stats.set then return false end
    local current = stats:get(stat)
    current = tonumber(current) or 0
    stats:set(stat, math.min(100, current + amount))
    return true
end

local function fieldDressApplyHumanPenalty(player)
    local appliedUnhappy = CharacterStat and CharacterStat.UNHAPPINESS
        and fieldDressAddCharacterStat(player, CharacterStat.UNHAPPINESS, 30)
    local appliedStress = CharacterStat and CharacterStat.STRESS
        and fieldDressAddCharacterStat(player, CharacterStat.STRESS, 15)

    if not appliedUnhappy or not appliedStress then
        local bd = player:getBodyDamage()
        local stats = player:getStats()
        if not appliedUnhappy and bd and bd.setUnhappynessLevel then
            bd:setUnhappynessLevel(math.min(100, (bd:getUnhappynessLevel() or 0) + 30))
        end
        if not appliedStress and stats and stats.setStress then
            stats:setStress(math.min(1.0, (stats:getStress() or 0) + 0.15))
        end
    end
end

function CSR_ServerCommands.handleFieldDressCorpse(player, args)
    if not player or not args then return end
    local sb = sandbox()
    if sb.EnableLastResortHarvest ~= true then return end
    if args.x == nil or args.y == nil or args.z == nil then return end
    if not isNearPlayer(player, args) then return end

    local body = resolveCorpse(args)
    if not body then return end

    local kind = fieldDressClassifyBody(body)
    if not kind then return end
    if kind == "human" and sb.AllowHumanHarvest ~= true then return end

    local knife = findInventoryItemById(player, args.knifeId)
    if not knife then return end

    local inv = player:getInventory()
    local sq = body:getSquare()

    -- Damage the knife.
    local dmg = fieldDressClampInt(sb.LastResortKnifeDamage, 0, 50, 15)
    if knife.setCondition and knife.getCondition then
        knife:setCondition(math.max((knife:getCondition() or 0) - dmg, 0))
    end
    syncInventoryItem(knife)

    local freshChance = fieldDressClampInt(sb.LastResortFreshChancePct, 0, 100, 15)
    local meatYield = fieldDressClampInt(sb.LastResortMeatYield, 1, 4, 1)
    local meatType = fieldDressMeatType(kind)

    for i = 1, meatYield do
        local meat = inv:AddItem(meatType)
        fieldDressAgeMeat(meat, freshChance)
        if meat then sendAddItemToContainer(inv, meat) end
    end

    if ZombRand(100) < 50 then
        local bone = inv:AddItem("Base.AnimalBone")
        if bone then sendAddItemToContainer(inv, bone) end
    end
    if ZombRand(100) < 20 then
        local large = inv:AddItem("Base.LargeAnimalBone")
        if large then sendAddItemToContainer(inv, large) end
    end

    if kind == "human" then
        fieldDressApplyHumanPenalty(player)
    end

    addSound(player, args.x, args.y, args.z, 10, 10)
    addXp(player, Perks.Butchering, 5)

    if sq and sq.removeCorpse then
        sq:removeCorpse(body, false)
    end
end

-- ============================================================================
-- Power Bar — cable-extension feature.
-- Place a Base.PowerBar on a powered tile, optionally invest ElectricWires
-- for extra reach. Anything inside the resulting Manhattan zone is treated
-- as plugged in (radios, EV chargers).
-- ============================================================================
-- v1.8.34c: B42.17 hasTag is missing on some InventoryItem subclasses
-- (Clothing, ComboItem, Padlock). The previous predicate called
-- it:hasTag("carbattery") inside getAllEvalRecurse, which threw
-- "No implementation found for function: hasTag" the moment iteration
-- touched one of those types -- breaking EV Convert and PowerBar parts
-- checks for any player carrying a worn item or padlock. Vanilla only
-- ships three concrete carbattery types, so match by fullType set --
-- no Java tag binding involved.
local CSR_PB_CARBATTERY_TYPES = {
    ["Base.CarBattery1"] = true,
    ["Base.CarBattery2"] = true,
    ["Base.CarBattery3"] = true,
}

local function csr_pb_countInInventory(inv, fullType)
    if not inv then return 0 end
    -- "Base.CarBattery" is a virtual id: vanilla ships three real
    -- variants (CarBattery1/2/3). Match all three by fullType.
    local matchByCarBattery = (fullType == "Base.CarBattery")
    local function matches(it)
        if not it or not it.getFullType then return false end
        local ft = it:getFullType()
        if matchByCarBattery then
            return CSR_PB_CARBATTERY_TYPES[ft] == true
        end
        return ft == fullType
    end
    -- Recurse into worn bags. The client-side EV panel uses
    -- getAllEvalRecurse, so the server MUST match — otherwise the
    -- player sees "ready" in the UI, clicks Convert, and the server
    -- silently rejects because it didn't see backpack items.
    if inv.getAllEvalRecurse then
        local list = inv:getAllEvalRecurse(matches)
        if list and list.size then return list:size() end
    end
    local n = 0
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if matches(it) then
            n = n + 1
        end
    end
    return n
end

local function csr_pb_consume(inv, fullType, count)
    if not inv or count <= 0 then return 0 end
    local matchByCarBattery = (fullType == "Base.CarBattery")
    local function matches(it)
        if not it or not it.getFullType then return false end
        local ft = it:getFullType()
        if matchByCarBattery then
            return CSR_PB_CARBATTERY_TYPES[ft] == true
        end
        return ft == fullType
    end
    local removed = 0
    -- Prefer recursive removal so we drain worn bags too.
    if inv.getAllEvalRecurse then
        local list = inv:getAllEvalRecurse(matches)
        if list and list.size then
            for i = list:size() - 1, 0, -1 do
                if removed >= count then break end
                local it = list:get(i)
                if it then
                    local owner = it.getContainer and it:getContainer() or inv
                    if owner and owner.Remove then
                        owner:Remove(it)
                        removed = removed + 1
                    end
                end
            end
            if removed >= count then return removed end
        end
    end
    local items = inv:getItems()
    -- Iterate backward — we mutate the list.
    for i = items:size() - 1, 0, -1 do
        if removed >= count then break end
        local it = items:get(i)
        if matches(it) then
            inv:Remove(it)
            removed = removed + 1
        end
    end
    return removed
end

local function csr_pb_broadcastSync()
    local nodes = CSR_PowerBar.serializeAll()
    local chargers = CSR_PowerBar.serializeChargers()
    sendServerCommand("CommonSenseLight", CSR_PowerBar.CMD_SYNC_PUSH,
        { nodes = nodes, chargers = chargers })
end

function CSR_ServerCommands.handlePowerBarPlace(player, args)
    if not player or not args then return end
    if not CSR_PowerBar.isFeatureEnabled() then return end
    if not isNearPlayer(player, args) then return end

    local cell = getCell(); if not cell then return end
    local sq = cell:getGridSquare(args.x, args.y, args.z)
    if not sq or not CSR_PowerBar.canPlaceForUser(sq) then
        sendResult(player, getText("Tooltip_CSR_PowerBarNoPlace") or
            "Place the Power Bar next to a building or inside a generator's range.")
        return
    end

    -- Already a node here?
    if CSR_PowerBar.findNodeAtSquare(args.x, args.y, args.z) then
        sendResult(player, getText("ContextMenu_CSR_PowerBarAlreadyHere") or "A Power Bar is already plugged in here.")
        return
    end

    local inv = player:getInventory()
    if csr_pb_countInInventory(inv, "Base.PowerBar") < 1 then
        sendResult(player, "Power Bar required.")
        return
    end

    local maxW   = CSR_PowerBar.maxWires()
    local desired = math.min(tonumber(args.wires) or 0, maxW)
    local haveW  = csr_pb_countInInventory(inv, "Base.ElectricWire")
    local invest = math.min(desired, haveW)

    -- Consume inventory.
    csr_pb_consume(inv, "Base.PowerBar", 1)
    if invest > 0 then csr_pb_consume(inv, "Base.ElectricWire", invest) end

    local id = CSR_PowerBar.serverNextId()
    local node = {
        id = id, x = args.x, y = args.y, z = args.z,
        wires = invest,
        owner = player.getUsername and tostring(player:getUsername()) or "",
    }
    CSR_PowerBar.nodes[id] = node
    CSR_PowerBar.serverSaveOne(node)
    -- Phantom-generator mode: spawn the hidden IsoGenerator at this tile so
    -- vanilla appliances within ~20 tiles register power. (No-op if disabled.)
    CSR_PowerBar.serverSpawnPhantom(node)
    csr_pb_broadcastSync()
    sendResult(player, (getText("Tooltip_CSR_PowerBarPlaced") or
        "Power Bar plugged in. Reach: %d tile(s).") :format(invest))
end

function CSR_ServerCommands.handlePowerBarUnplug(player, args)
    if not player or not args or not args.id then return end
    local node = CSR_PowerBar.nodes[args.id]
    if not node then return end
    if not isNearPlayer(player, { x = node.x, y = node.y, z = node.z }) then return end

    local inv = player:getInventory()
    if inv then
        inv:AddItem("Base.PowerBar")
        local pct = CSR_PowerBar.returnPct()
        local toReturn = math.floor((node.wires or 0) * pct / 100)
        for i = 1, toReturn do inv:AddItem("Base.ElectricWire") end
    end

    -- Always despawn the phantom (cleanup, even if mode is currently off).
    CSR_PowerBar.serverDespawnPhantom(node)
    CSR_PowerBar.serverDelete(node.id)
    csr_pb_broadcastSync()
    sendResult(player, getText("Tooltip_CSR_PowerBarUnplugged") or "Power Bar unplugged.")
end

function CSR_ServerCommands.handlePowerBarAddWire(player, args)
    if not player or not args or not args.id then return end
    local node = CSR_PowerBar.nodes[args.id]
    if not node then return end
    if not isNearPlayer(player, { x = node.x, y = node.y, z = node.z }) then return end
    local maxW = CSR_PowerBar.maxWires()
    if (node.wires or 0) >= maxW then return end

    local inv = player:getInventory()
    if csr_pb_countInInventory(inv, "Base.ElectricWire") < 1 then return end
    csr_pb_consume(inv, "Base.ElectricWire", 1)

    node.wires = (node.wires or 0) + 1
    CSR_PowerBar.serverSaveOne(node)
    csr_pb_broadcastSync()
    sendResult(player, (getText("Tooltip_CSR_PowerBarReach") or
        "Power Bar reach: %d / %d tiles."):format(node.wires, maxW))
end

function CSR_ServerCommands.handlePowerBarSyncRequest(player, _args)
    if not player then return end
    local nodes = CSR_PowerBar.serializeAll()
    local chargers = CSR_PowerBar.serializeChargers()
    sendServerCommand(player, "CommonSenseLight", CSR_PowerBar.CMD_SYNC_PUSH,
        { nodes = nodes, chargers = chargers })
end

-- ----------------------------------------------------------------------------
-- Cable: connect a floor-dropped CarBatteryCharger to a placed PowerBar.
-- args: { chargerX, chargerY, chargerZ, barId }
-- Wires consumed = Manhattan distance from bar to charger.
-- ----------------------------------------------------------------------------
function CSR_ServerCommands.handlePowerCableConnect(player, args)
    if not player or not args then return end
    if not CSR_PowerBar.isFeatureEnabled() then return end
    local cx, cy, cz = tonumber(args.chargerX), tonumber(args.chargerY), tonumber(args.chargerZ)
    local barId = tonumber(args.barId)
    if not (cx and cy and cz and barId) then return end
    if not isNearPlayer(player, { x = cx, y = cy, z = cz }) then return end
    local node = CSR_PowerBar.nodes[barId]
    if not node then
        sendResult(player, "Power Bar not found.")
        return
    end
    if node.z ~= cz then
        sendResult(player, "Power Bar must be on the same floor.")
        return
    end
    -- Already connected on this tile?
    if CSR_PowerBar.getChargerConnection(cx, cy, cz) then
        sendResult(player, getText("Tooltip_CSR_PowerBarAlreadyConnected") or
            "This charger is already connected.")
        return
    end
    local distance = math.abs(node.x - cx) + math.abs(node.y - cy)
    if distance > (node.wires or 0) then
        sendResult(player, (getText("Tooltip_CSR_PowerBarTooFar") or
            "Out of range. Distance %d, bar reach %d."):format(distance, node.wires or 0))
        return
    end
    -- Verify the floor charger actually exists on that tile.
    local cell = getCell(); if not cell then return end
    local sq = cell:getGridSquare(cx, cy, cz)
    if not sq then return end
    local found = false
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o and instanceof(o, "IsoWorldInventoryObject") then
            local item = o.getItem and o:getItem() or nil
            if item and item.getFullType and item:getFullType() == "Base.CarBatteryCharger" then
                found = true; break
            end
        end
    end
    if not found then
        sendResult(player, "No charger on that tile.")
        return
    end
    CSR_PowerBar.chargers[CSR_PowerBar.chargerKey(cx, cy, cz)] = {
        x = cx, y = cy, z = cz, barId = barId, wires = distance,
    }
    CSR_PowerBar.serverSaveChargers()
    csr_pb_broadcastSync()
    sendResult(player, (getText("Tooltip_CSR_PowerBarCableConnected") or
        "Cable run: %d tile(s). Charger is now energized."):format(distance))
end

-- args: { chargerX, chargerY, chargerZ }
function CSR_ServerCommands.handlePowerCableDisconnect(player, args)
    if not player or not args then return end
    local cx, cy, cz = tonumber(args.chargerX), tonumber(args.chargerY), tonumber(args.chargerZ)
    if not (cx and cy and cz) then return end
    if not isNearPlayer(player, { x = cx, y = cy, z = cz }) then return end
    local conn = CSR_PowerBar.getChargerConnection(cx, cy, cz)
    if not conn then return end
    CSR_PowerBar.chargers[CSR_PowerBar.chargerKey(cx, cy, cz)] = nil
    CSR_PowerBar.serverSaveChargers()
    csr_pb_broadcastSync()
    sendResult(player, getText("Tooltip_CSR_PowerBarCableDisconnected") or
        "Cable disconnected.")
end

function CSR_ServerCommands.handleRadioPlugSync(player, args)
    -- Mirror NepRadioPlugs' MP path: client tells server which placed radio's
    -- battery flag to flip after re-evaluating power state. Server is the
    -- authoritative writer for IsoRadio:getDeviceData() in MP.
    if not player or not args then return end
    if not isNearPlayer(player, args) then return end
    local cell = getCell(); if not cell then return end
    local sq = cell:getGridSquare(args.x, args.y, args.z)
    if not sq then return end
    local ddata = sq.getDeviceData and sq:getDeviceData() or nil
    if not ddata or not ddata.setIsBatteryPowered then return end
    local useBattery = (tonumber(args.useBattery) or 0) == 1
    ddata:setIsBatteryPowered(useBattery)
end

-- ============================================================================
-- EV Vehicle Conversion — convert a fuel vehicle to electric, charge via
-- a CarBatteryCharger placed on a square inside a CSR PowerBar zone.
-- Vehicle is flagged via getModData().csrEV. Charge in csrEVCharge (0..100).
-- Fuel is clamped each tick so vanilla engine logic never sees an empty tank.
-- ============================================================================
local function csr_ev_required()
    local sb = sandbox()
    return {
        batteries = math.max(1, math.min(10, tonumber(sb.EVRequiredBatteries) or 4)),
        wires     = math.max(1, math.min(20, tonumber(sb.EVRequiredWires) or 8)),
        ducttape  = 2,
        chargers  = 1,
    }
end

local function csr_ev_consumeParts(player, vehicle)
    local req = csr_ev_required()
    local need = {
        ["Base.CarBattery"]        = req.batteries,
        ["Base.ElectricWire"]      = req.wires,
        ["Base.DuctTape"]          = req.ducttape,
        ["Base.CarBatteryCharger"] = req.chargers,
    }
    -- Build the list of containers we're willing to draw from: player
    -- inventory first (so worn-bag items get pulled before trunk items),
    -- then every part container on the target vehicle (trunk, glove box,
    -- seats, etc).
    local containers = {}
    if player and player.getInventory then
        table.insert(containers, player:getInventory())
    end
    if vehicle and vehicle.getPartCount then
        local n = vehicle:getPartCount()
        for i = 0, n - 1 do
            local part = vehicle:getPartByIndex(i)
            local cont = part and part.getItemContainer and part:getItemContainer() or nil
            if cont then table.insert(containers, cont) end
        end
    end
    -- Verify totals before mutating anything.
    for ft, count in pairs(need) do
        local total = 0
        for _, cont in ipairs(containers) do
            total = total + csr_pb_countInInventory(cont, ft)
        end
        if total < count then
            return false, ft, count
        end
    end
    -- Consume in container order.
    for ft, count in pairs(need) do
        local remaining = count
        for _, cont in ipairs(containers) do
            if remaining <= 0 then break end
            remaining = remaining - csr_pb_consume(cont, ft, remaining)
        end
    end
    return true
end

function CSR_ServerCommands.handleEVConvert(player, args)
    if not player or not args then return end
    if sandbox().EnableEVConversion ~= true then return end
    local v = getVehicleByArgs(args); if not v then return end
    if v:getModData().csrEV then
        sendResult(player, srvText("Tooltip_CSR_EVAlreadyEV", "Vehicle is already an EV."))
        return
    end

    -- Proximity gate (player to vehicle).
    local px, py = player:getX(), player:getY()
    local vx, vy = v:getX(), v:getY()
    if math.abs(px - vx) > 4 or math.abs(py - vy) > 4 then
        sendResult(player, "Stand next to the vehicle.")
        return
    end

    -- Skill gate.
    local mechReq = math.max(0, math.min(10, tonumber(sandbox().EVConvertMechanicsLevel) or 4))
    local elecReq = math.max(0, math.min(10, tonumber(sandbox().EVConvertElectricalLevel) or 4))
    local mechLvl, elecLvl = 0, 0
    mechLvl = player:getPerkLevel(Perks.Mechanics) or 0
    elecLvl = player:getPerkLevel(Perks.Electricity) or 0
    if mechLvl < mechReq or elecLvl < elecReq then
        sendResult(player,
            (getText("IGUI_CSR_EVConvertSkillPrefix") or "Requires Mechanics ") ..
            tostring(mechReq) ..
            (getText("IGUI_CSR_EVConvertSkillJoin") or " and Electrical ") ..
            tostring(elecReq) .. ".")
        return
    end

    -- Energized-charger gate: vehicle must be parked within 2 tiles of one.
    local vsq = v:getCurrentSquare()
    local hit = vsq and CSR_PowerBar.findEnergizedChargerNear(vsq, 2) or nil
    if not hit then
        sendResult(player, srvText("Tooltip_CSR_EVNeedCharger",
            "Park next to an energized Car Battery Charger to convert."))
        return
    end

    local ok, missingFt, missingCount = csr_ev_consumeParts(player, v)
    if not ok then
        -- Plain concat — getText() returns a Java-string wrapper that
        -- silently no-ops on Lua's :format().
        sendResult(player,
            srvText("Tooltip_CSR_EVMissingPrefix", "Missing parts: ") ..
            tostring(missingCount or 0) .. " x " ..
            tostring(missingFt or ""))
        return
    end

    local md = v:getModData()
    md.csrEV = true
    md.csrEVCharge = 100
    md.csrEVTrunkPenaltyKg = math.max(0, math.min(80, tonumber(sandbox().EVTrunkPenaltyKg) or 25))
    v:transmitModData()
    sendResult(player, srvText("Tooltip_CSR_EVConverted", "Vehicle converted to electric."))
end

function CSR_ServerCommands.handleEVRevert(player, args)
    if not player or not args then return end
    local v = getVehicleByArgs(args); if not v then return end
    local md = v:getModData()
    if not md.csrEV then return end

    local req = csr_ev_required()
    local inv = player:getInventory()
    if inv then
        -- "Base.CarBattery" doesn't exist as a concrete item — refund the
        -- basic variant instead. Player gets half their batteries/wires
        -- back (vanilla pattern: partial recovery on revert).
        for i = 1, math.floor(req.batteries / 2) do inv:AddItem("Base.CarBattery1") end
        for i = 1, math.floor(req.wires / 2)     do inv:AddItem("Base.ElectricWire") end
        inv:AddItem("Base.CarBatteryCharger")
    end
    md.csrEV = nil
    md.csrEVCharge = nil
    md.csrEVTrunkPenaltyKg = nil
    v:transmitModData()
    sendResult(player, srvText("Tooltip_CSR_EVReverted", "Conversion reverted."))
end

-- Server tick: drain/charge EV vehicles. Light: only iterate getVehicleList.
local function csr_ev_serverTick()
    if isClient() then return end
    if sandbox().EnableEVConversion ~= true then return end
    local list = getVehicleList and getVehicleList() or nil
    if not list then return end

    local chargePerHour = math.max(1, math.min(25,
        tonumber(sandbox().EVChargeFromChargerPctPerHour) or 8))
    -- EveryTenMinutes ticks 6× per game-hour.
    local chargePerTick = chargePerHour / 6.0

    for i = 0, list:size() - 1 do
        local v = list:get(i)
        if v then
            local md = v:getModData()
            if md and md.csrEV then
                local charge = tonumber(md.csrEVCharge) or 0

                -- Charging: parked + engine off + adjacent square has CSR power
                -- and a CarBatteryCharger is in the trunk or in range.
                local engineOn = v:isEngineRunning()
                if not engineOn then
                    local sq = v:getCurrentSquare()
                    -- Recharge only when parked within 2 tiles of an energized
                    -- world Car Battery Charger linked to a live Power Bar.
                    if sq and CSR_PowerBar.findEnergizedChargerNear(sq, 2) then
                        charge = math.min(100, charge + chargePerTick)
                    end
                end

                md.csrEVCharge = charge
            end
        end
    end
end

Events.EveryTenMinutes.Add(csr_ev_serverTick)

-- ----------------------------------------------------------------------------
-- Power Bar overload fire risk: cables that exceed their safe length have a
-- per-hour chance of igniting at the bar tile. Chance scales with how close
-- to the maximum reach the bar is, so a fully-extended bar in a wet basement
-- is meaningfully riskier than a 1-tile run.
-- Sandbox: PowerBarOverloadFireChancePctPerHour (0..100, default 0).
-- ----------------------------------------------------------------------------
local function csr_pb_fireTick()
    if isClient() then return end
    if not CSR_PowerBar.isFeatureEnabled() then return end
    local sb = sandbox()
    local maxPct = math.max(0, math.min(100, tonumber(sb.PowerBarOverloadFireChancePctPerHour) or 0))
    if maxPct <= 0 then return end
    local maxW = CSR_PowerBar.maxWires()
    if maxW <= 0 then return end

    local cell = getCell(); if not cell then return end
    for _, n in pairs(CSR_PowerBar.nodes) do
        if n then
            local sq = cell:getGridSquare(n.x, n.y, n.z)
            local live = false
            if sq then
                live = sq:haveElectricity()
            end
            if live and (n.wires or 0) > 0 then
                -- Quadratic scaling: a half-extended bar is ~25% of max chance,
                -- a fully extended bar is at maxPct.
                local r = (n.wires or 0) / maxW
                local chance = maxPct * r * r
                if ZombRand(10000) < (chance * 100) then
                    if IsoFireManager and IsoFireManager.StartFire then
                        IsoFireManager.StartFire(getCell(), sq, true, 50)
                    end
                end
            end
        end
    end
end
Events.EveryHours.Add(csr_pb_fireTick)

-- Phantom-generator tick: ensure hidden IsoGenerators exist for each bar,
-- mirror their on/off state to upstream power, top up fuel/condition, silence
-- their emitter, and clear toxic-fume flags. Cheap (1 entry per placed bar).
local function csr_pb_phantomTick()
    if isClient() then return end
    if not CSR_PowerBar then return end
    if not CSR_PowerBar.isFeatureEnabled() then return end
    CSR_PowerBar.serverTickPhantoms()
end
Events.EveryTenMinutes.Add(csr_pb_phantomTick)

-- Boot: hydrate the PowerBar registry from ModData when the server starts,
-- then re-establish phantom generator references for any persisted nodes.
local function csr_pb_boot()
    if not CSR_PowerBar then return end
    CSR_PowerBar.serverLoad()
    -- Defer the phantom rehydration one tick so the world cell is ready.
    local function once()
        Events.OnTick.Remove(once)
        CSR_PowerBar.serverTickPhantoms()
    end
    Events.OnTick.Add(once)
end
Events.OnServerStarted.Add(csr_pb_boot)
Events.OnGameStart.Add(function()
    -- SP: load from ModData on game start.
    if isServer() or isClient() then return end
    csr_pb_boot()
end)

local function onClientCommand(module, command, player, args)
    if module ~= "CommonSenseLight" then
        return
    end

    if not QUIET_COMMAND_LOG[command] then
        local playerName = player and player.getUsername and player:getUsername() or "unknown"
        print("[CSR] Server received command: " .. tostring(command) .. " from " .. playerName)
    end

    pruneKnowledgeState(getNowMs())

    if isDuplicateRequest(player, command, args) then
        return
    end

    if command == "RequestPlayerMarkers" then
        CSR_ServerCommands.handlePlayerMarkerRequest(player, args)
    elseif command == "RequestZombieDensity" then
        CSR_ServerCommands.handleZombieDensityRequest(player, args)
    elseif command == "LockpickTarget" then
        CSR_ServerCommands.handleLockpick(player, args)
    elseif command == "LockpickVehicleDoor" then
        CSR_ServerCommands.handleLockpickVehicleDoor(player, args)
    elseif command == "UnHotwireVehicle" then
        CSR_ServerCommands.handleUnHotwireVehicle(player, args)
    elseif command == "PryTarget" then
        CSR_ServerCommands.handlePry(player, args)
    elseif command == "BoltCutTarget" then
        CSR_ServerCommands.handleBoltCut(player, args)
    elseif command == "PryVehicleDoor" then
        CSR_ServerCommands.handlePryVehicleDoor(player, args)
    elseif command == "VehicleClaimViolation" then
        if CSR_VehicleClaimServerEnforcer and CSR_VehicleClaimServerEnforcer.handleViolation then
            CSR_VehicleClaimServerEnforcer.handleViolation(player, args)
        end
    elseif command == "StopDropRollExtinguish" then
        CSR_ServerCommands.handleStopDropRollExtinguish(player, args)
    elseif command == "TrunkSpillageTick" then
        CSR_ServerCommands.handleTrunkSpillageTick(player, args)
    elseif command == "ThrowableThrow" then
        CSR_ServerCommands.handleThrowableThrow(player, args)
    elseif command == "IgniteCorpse" then
        CSR_ServerCommands.handleIgniteCorpse(player, args)
    elseif command == "BarricadeWindow" then
        CSR_ServerCommands.handleBarricadeWindow(player, args)
    elseif command == "OpenCan" then
        CSR_ServerCommands.handleOpenCan(player, args)
    elseif command == "OpenJar" then
        CSR_ServerCommands.handleOpenJar(player, args)
    elseif command == "OpenAllCans" then
        CSR_ServerCommands.handleOpenAllCans(player, args)
    elseif command == "OpenAllJars" then
        CSR_ServerCommands.handleOpenAllJars(player, args)
    elseif command == "OpenAmmoBox" then
        CSR_ServerCommands.handleOpenAmmoBox(player, args)
    elseif command == "OpenAllAmmoBoxes" then
        CSR_ServerCommands.handleOpenAllAmmoBoxes(player, args)
    elseif command == "PackAmmoBox" then
        CSR_ServerCommands.handlePackAmmoBox(player, args)
    elseif command == "PackAllAmmoBoxes" then
        CSR_ServerCommands.handlePackAllAmmoBoxes(player, args)
    elseif command == "SawAllLogs" then
        CSR_ServerCommands.handleSawAllLogs(player, args)
    elseif command == "DismantleAllWatches" then
        CSR_ServerCommands.handleDismantleAllWatches(player, args)
    elseif command == "QuickRepair" then
        CSR_ServerCommands.handleQuickRepair(player, args)
    elseif command == "ToolRepair" then
        CSR_ServerCommands.handleToolRepair(player, args)
    elseif command == "DuctTapeRepair" then
        CSR_ServerCommands.handleMaterialRepair(player, args, 25)
    elseif command == "GlueRepair" then
        local gItem = findInventoryItemById(player, args and args.itemId)
        if not CSR_Utils.isClothingItem(gItem) then
            CSR_ServerCommands.handleMaterialRepair(player, args, 20)
        end
    elseif command == "TapeRepair" then
        CSR_ServerCommands.handleMaterialRepair(player, args, 15)
    elseif command == "PatchClothing" then
        CSR_ServerCommands.handlePatchClothing(player, args)
    elseif command == "RepairAllClothing" then
        CSR_ServerCommands.handleRepairAllClothing(player, args)
    elseif command == "TearCloth" then
        CSR_ServerCommands.handleTearCloth(player, args)
    elseif command == "TearAllCloth" then
        CSR_ServerCommands.handleTearAllCloth(player, args)
    elseif command == "ReplaceBattery" then
        CSR_ServerCommands.handleReplaceBattery(player, args)
    elseif command == "RefillLighter" then
        CSR_ServerCommands.handleRefillLighter(player, args)
    elseif command == "MakeBandage" then
        CSR_ServerCommands.handleMakeBandage(player, args)
    elseif command == "DisinfectRag" then
        CSR_ServerCommands.handleDisinfectRag(player, args)
    elseif command == "ClipboardAddPaper" then
        CSR_ServerCommands.handleClipboardAddPaper(player, args)
    elseif command == "ClipboardRemovePaper" then
        CSR_ServerCommands.handleClipboardRemovePaper(player, args)
    elseif command == "ClipboardSave" then
        CSR_ServerCommands.handleClipboardSave(player, args)
    elseif command == "KnowledgeRecipeInvite" then
        CSR_ServerCommands.handleKnowledgeRecipeInvite(player, args)
    elseif command == "KnowledgeRecipeRespond" then
        CSR_ServerCommands.handleKnowledgeRecipeRespond(player, args)
    elseif command == "KnowledgeRecipeComplete" then
        CSR_ServerCommands.handleKnowledgeRecipeComplete(player, args)
    elseif command == "KnowledgeRecipeCancel" then
        CSR_ServerCommands.handleKnowledgeRecipeCancel(player, args)
    elseif command == "KnowledgeLectureStart" then
        CSR_ServerCommands.handleKnowledgeLectureStart(player, args)
    elseif command == "KnowledgeLecturePulse" then
        CSR_ServerCommands.handleKnowledgeLecturePulse(player, args)
    elseif command == "KnowledgeLectureStop" then
        CSR_ServerCommands.handleKnowledgeLectureStop(player, args)
    elseif command == "ClaimVehicle" then
        CSR_ServerCommands.handleClaimVehicle(player, args)
    elseif command == "UnclaimVehicle" then
        CSR_ServerCommands.handleUnclaimVehicle(player, args)
    elseif command == "VehicleAddAllowed" then
        CSR_ServerCommands.handleVehicleAddAllowed(player, args)
    elseif command == "VehicleRemoveAllowed" then
        CSR_ServerCommands.handleVehicleRemoveAllowed(player, args)
    elseif command == "VehicleReissueClaimKey" then
        CSR_ServerCommands.handleVehicleReissueClaimKey(player, args)
    elseif command == "VehicleRemoveClaimHotwire" then
        CSR_ServerCommands.handleVehicleRemoveClaimHotwire(player, args)
    elseif command == "ClaimSafehouse" then
        CSR_ServerCommands.handleClaimSafehouse(player, args)
    elseif command == "ReleaseSafehouse" then
        CSR_ServerCommands.handleReleaseSafehouse(player, args)
    elseif command == "ClaimFactionSafehouse" then
        CSR_ServerCommands.handleClaimFactionSafehouse(player, args)
    elseif command == "ReleaseFactionSafehouse" then
        CSR_ServerCommands.handleReleaseFactionSafehouse(player, args)
    elseif command == "FactionSafehouseTag" then
        CSR_ServerCommands.handleFactionSafehouseTag(player, args)
    elseif command == "GetFactionSafehouseRegistry" then
        CSR_ServerCommands.handleGetFactionSafehouseRegistry(player, args)
    elseif command == "TransferFactionSafehouse" then
        CSR_ServerCommands.handleTransferFactionSafehouse(player, args)
    elseif command == "SetFactionMemberRole" then
        CSR_ServerCommands.handleSetFactionMemberRole(player, args)
    elseif command == "DW_LeftAttack" then
        CSR_ServerCommands.handleDW_LeftAttack(player, args)
    elseif command == "DW_LeftHit" then
        CSR_ServerCommands.handleDW_LeftHit(player, args)
    elseif command == "DW_UnarmedRightHit" then
        CSR_ServerCommands.handleDW_UnarmedRightHit(player, args)
    elseif command == "PurgeFireworks" then
        CSR_ServerCommands.handlePurgeFireworks(player, args)
    elseif command == "NoticeBoardWrite" then
        CSR_ServerCommands.handleNoticeBoardWrite(player, args)
    elseif command == "WhiteboardWrite" then
        CSR_ServerCommands.handleWhiteboardWrite(player, args)
    elseif command == "ShareRallyPoint" then
        CSR_ServerCommands.handleShareRallyPoint(player, args)
    elseif command == "RankingsRequest" then
        if CSR_RankingsServer and CSR_RankingsServer.handleRequest then
            CSR_RankingsServer.handleRequest(player, args)
        end
    elseif command == "SkillJournalGet" then
        if CSR_SkillJournalServer and CSR_SkillJournalServer.handleGet then
            CSR_SkillJournalServer.handleGet(player, args)
        end
    elseif command == "SkillJournalSave" then
        if CSR_SkillJournalServer and CSR_SkillJournalServer.handleSave then
            CSR_SkillJournalServer.handleSave(player, args)
        end
    elseif command == "SkillJournalRecover" then
        if CSR_SkillJournalServer and CSR_SkillJournalServer.handleRecover then
            CSR_SkillJournalServer.handleRecover(player, args)
        end
    elseif command == "SkillJournalAdmin" then
        if CSR_SkillJournalServer and CSR_SkillJournalServer.handleAdmin then
            CSR_SkillJournalServer.handleAdmin(player, args)
        end
    elseif command == "FridgeToggle" then
        CSR_ServerCommands.handleFridgeToggle(player, args)
    elseif command == "PlaceGroundMark" then
        if CSR_GroundMarkingServer then CSR_GroundMarkingServer.handlePlace(player, args) end
    elseif command == "RemoveGroundMark" then
        if CSR_GroundMarkingServer then CSR_GroundMarkingServer.handleRemove(player, args) end
    elseif command == "BarrelCap" then
        CSR_ServerCommands.handleBarrelCap(player, args)
    elseif command == "FireTrailPaint" then
        CSR_ServerCommands.handleFireTrailPaint(player, args)
    elseif command == "FireTrailIgnite" then
        CSR_ServerCommands.handleFireTrailIgnite(player, args)
    elseif command == "BinksScoopDung" then
        CSR_ServerCommands.handleBinksScoopDung(player, args)
    elseif command == "WashAll" then
        CSR_ServerCommands.handleWashAll(player, args)
    elseif command == "BathSetWater" then
        CSR_ServerCommands.handleBathSetWater(player, args)
    elseif command == "BathComplete" then
        CSR_ServerCommands.handleBathComplete(player, args)
    elseif command == "MassageHealStrain" then
        CSR_ServerCommands.handleMassageHealStrain(player, args)
    elseif command == "JarCap" then
        CSR_ServerCommands.handleJarCap(player, args)
    elseif command == "RouletteCreate" then
        CSR_ServerCommands.handleRouletteCreate(player, args)
    elseif command == "RouletteRespond" then
        CSR_ServerCommands.handleRouletteRespond(player, args)
    elseif command == "RouletteFire" then
        CSR_ServerCommands.handleRouletteFire(player, args)
    elseif command == "RouletteLeave" then
        CSR_ServerCommands.handleRouletteLeave(player, args)
    elseif command == "FieldDressCorpse" then
        CSR_ServerCommands.handleFieldDressCorpse(player, args)
    elseif command == "PowerBarPlace" then
        CSR_ServerCommands.handlePowerBarPlace(player, args)
    elseif command == "PowerBarUnplug" then
        CSR_ServerCommands.handlePowerBarUnplug(player, args)
    elseif command == "PowerBarAddWire" then
        CSR_ServerCommands.handlePowerBarAddWire(player, args)
    elseif command == "PowerBarSyncRequest" then
        CSR_ServerCommands.handlePowerBarSyncRequest(player, args)
    elseif command == "PowerBarCableConnect" then
        CSR_ServerCommands.handlePowerCableConnect(player, args)
    elseif command == "PowerBarCableDisconnect" then
        CSR_ServerCommands.handlePowerCableDisconnect(player, args)
    elseif command == "PowerLinePaint" then
        CSR_ServerCommands.handlePowerLinePaint(player, args)
    elseif command == "PowerLineEnd" then
        CSR_ServerCommands.handlePowerLineEnd(player, args)
    elseif command == "PowerLineCancel" then
        CSR_ServerCommands.handlePowerLineCancel(player, args)
    elseif command == "PowerLineRemove" then
        CSR_ServerCommands.handlePowerLineRemove(player, args)
    elseif command == "PowerLineToggle" then
        CSR_ServerCommands.handlePowerLineToggle(player, args)
    elseif command == "OutfitSetSave" then
        CSR_ServerCommands.handleOutfitSetSave(player, args)
    elseif command == "OutfitSetDelete" then
        CSR_ServerCommands.handleOutfitSetDelete(player, args)
    elseif command == "OutfitCapacityBonus" then
        CSR_ServerCommands.handleOutfitCapacityBonus(player, args)
    elseif command == "OutfitWardrobeConvert" then
        CSR_ServerCommands.handleOutfitWardrobeConvert(player, args)
    elseif command == "OutfitWardrobeRevert" then
        CSR_ServerCommands.handleOutfitWardrobeRevert(player, args)
    elseif command == "OutfitWardrobeSyncRequest" then
        CSR_ServerCommands.handleOutfitWardrobeSyncRequest(player, args)
    elseif command == "RadioPlugSync" then
        CSR_ServerCommands.handleRadioPlugSync(player, args)
    elseif command == "EVConvert" then
        CSR_ServerCommands.handleEVConvert(player, args)
    elseif command == "EVRevert" then
        CSR_ServerCommands.handleEVRevert(player, args)
    elseif command == "KnoxCallSupport" then
        CSR_ServerCommands.handleKnoxCallSupport(player, args)
    elseif command == "RoofClimbSet" then
        CSR_ServerCommands.handleRoofClimbSet(player, args)
    elseif command == "RoofClimbClear" then
        CSR_ServerCommands.handleRoofClimbClear(player, args)
    elseif command == "RoofClimbRequestRoster" then
        CSR_ServerCommands.handleRoofClimbRequestRoster(player, args)
    elseif command == "CSR_PadlockInstall" then
        CSR_PadlockServer.handleInstall(player, args)
    elseif command == "CSR_PadlockRemove" then
        CSR_PadlockServer.handleRemove(player, args)
    elseif command == "CSR_PadlockBreak" then
        CSR_PadlockServer.handleBreak(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)

-- ============================================================================
-- Zombie density: server-driven push.
-- One zombie scan per ZOMBIE_DENSITY_SERVER_PUSH_TICKS, then per-player grid
-- bucketing + broadcast. Replaces the old client-pull model so a busy MP server
-- with many players keeps a fixed scan budget instead of N requests/window.
-- ============================================================================
local _zdensityPushCounter = 0

local function pushZombieDensityToAllPlayers()
    if isClient() then return end
    if sandbox().EnableZombieDensityOverlay == false then return end
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players or players:size() == 0 then return end

    -- Trigger one shared scan via the existing handler path on the first player;
    -- subsequent per-player calls within the same ZOMBIE_SCAN_SHARE_MS window
    -- reuse _zombieScanCache for free.
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p.getModData then
            local md = p:getModData()
            -- Player can opt out via client flag; reset SERVER_MIN_TICKS guard each push.
            if md and md.CSRZombieDensityOptIn ~= false then
                local key = markerKey(p)
                if zombieDensityRequests[key] then
                    zombieDensityRequests[key] = nil
                end
                CSR_ServerCommands.handleZombieDensityRequest(p, { requestSeq = 0 })
            end
        end
    end
end

local function onZombieDensityServerTick()
    _zdensityPushCounter = _zdensityPushCounter + 1
    local interval = CSR_Config.ZOMBIE_DENSITY_SERVER_PUSH_TICKS or 25
    if _zdensityPushCounter < interval then return end
    _zdensityPushCounter = 0
    pushZombieDensityToAllPlayers()
end

-- Zombie density overlay feature is disabled; tick registration removed to avoid
-- pushing ZombieDensityCells packets to clients that no longer have the overlay module.

-- ============================================================================
-- Knox Syndicate: server-authoritative support call.
-- 90s helicopter strafe that culls nearby zombies + emits world sound that
-- attracts more. Per-player cooldown stored in player ModData.
-- ============================================================================

local KnoxActive = {} -- [username] = { player, endTick, nextShotTick, square }

local function knoxBroadcastReject(player, reasonKey)
    sendServerCommand(player, "CommonSenseLight", "KnoxCallReject",
        { reason = reasonKey })
end

function CSR_ServerCommands.handleKnoxCallSupport(player, args)
    if not (player and CSR_KnoxSyndicate and CSR_KnoxSyndicate.isEnabled()) then
        return
    end
    local md = player:getModData()
    local now = CSR_KnoxSyndicate.gameHour()
    local last = tonumber(md.csrKnoxLastHour or 0) or 0
    if (last + CSR_KnoxSyndicate.cooldownHours()) > now then
        knoxBroadcastReject(player, "IGUI_CSR_KnoxCallCooldown")
        return
    end

    -- Server-side frequency re-validation. Either a tuned hand radio in
    -- the player's inventory or a tuned vehicle radio device counts.
    local tuned = false
    local inv = player:getInventory()
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            if CSR_KnoxSyndicate.isTunedHandRadio(items:get(i)) then
                tuned = true; break
            end
        end
    end
    if not tuned then
        local veh = player:getVehicle()
        if veh then
            for i = 0, veh:getPartCount() - 1 do
                local part = veh:getPartByIndex(i)
                local dd = part and part.getDeviceData and part:getDeviceData()
                if CSR_KnoxSyndicate.isTunedDeviceData(dd) then
                    tuned = true; break
                end
            end
        end
    end
    if not tuned then
        knoxBroadcastReject(player, "IGUI_CSR_KnoxNotTuned")
        return
    end

    -- Outdoor / line-of-sight check
    local sq = player:getCurrentSquare()
    if not sq then return end
    if not sq:isOutside() then
        if not player:getVehicle() then
            knoxBroadcastReject(player, "IGUI_CSR_KnoxCallNoSignal")
            return
        end
    end

    md.csrKnoxLastHour = now
    -- Sync the cooldown stamp to the client so the right-click option greys
    -- out immediately in MP. Without this the player only sees the cooldown
    -- after a relog because client-side ModData stays stale.
    if isServer() and player.transmitModData then
        player:transmitModData()
    end

    local username = player:getUsername() or tostring(player)
    KnoxActive[username] = {
        player        = player,
        endTime       = getTimestampMs() + (CSR_KnoxSyndicate.durationSec() * 1000),
        nextShotTime  = getTimestampMs(),
        shotCount     = 0,
    }

    sendServerCommand(player, "CommonSenseLight", "KnoxCallStarted",
        { durationSec = CSR_KnoxSyndicate.durationSec() })
end

local function knoxKillNearestZombie(player, range, noiseRadius)
    local sq = player:getCurrentSquare()
    if not sq then return false end
    local cell = sq:getCell()
    if not cell then return false end
    local px, py = sq:getX(), sq:getY()
    local objs = cell:getObjectListForLua()
    if not objs then return false end

    local bestZ, bestD = nil, range * range + 1
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if instanceof(o, "IsoZombie") and o.isAlive and o:isAlive() then
            local zsq = o:getCurrentSquare()
            if zsq then
                local dx = zsq:getX() - px
                local dy = zsq:getY() - py
                local d  = dx * dx + dy * dy
                if d <= range * range and d < bestD then
                    bestZ, bestD = o, d
                end
            end
        end
    end

    if bestZ then
        -- Belt-and-braces: setHealth(0) is the canonical kill, but on some
        -- engine builds the zombie still needs an explicit death transition
        -- to actually drop and become a corpse the same tick.
        bestZ:setHealth(0)
        if bestZ.becomeCorpseSilently then
            bestZ:becomeCorpseSilently()
        end
        if noiseRadius > 0 then
            addSound(player, sq:getX(), sq:getY(), sq:getZ(), noiseRadius, noiseRadius)
        end
        return true
    end
    return false
end

local function knoxTick()
    if not (CSR_KnoxSyndicate and CSR_KnoxSyndicate.isEnabled()) then
        KnoxActive = {}
        return
    end
    local now = getTimestampMs()
    local interval = CSR_KnoxSyndicate.killIntervalSec() * 1000
    local range = CSR_KnoxSyndicate.rangeTiles()
    local noise = CSR_KnoxSyndicate.noiseRadius()

    for username, state in pairs(KnoxActive) do
        local p = state.player
        if not p or now >= state.endTime then
            if p then
                sendServerCommand(p, "CommonSenseLight", "KnoxCallEnded", {})
            end
            KnoxActive[username] = nil
        else
            if now >= state.nextShotTime then
                local hit = knoxKillNearestZombie(p, range, noise)
                state.shotCount = (state.shotCount or 0) + 1
                state.nextShotTime = now + interval
                -- Even if no zombie was in range, still fire a "warning shot"
                -- audio cue so the player feels the chopper above. Every 4th
                -- shot is a heavy precision round (sniper).
                local heavy = (state.shotCount % 4 == 0)
                sendServerCommand(p, "CommonSenseLight", "KnoxCallShot",
                    { heavy = heavy, hit = hit })
            end
        end
    end
end

if Events and Events.OnTick and not CSR_ServerCommands._knoxTickRegistered then
    CSR_ServerCommands._knoxTickRegistered = true
    -- Throttle: only every ~30 ticks (~1s @ 30fps server)
    local _knoxCounter = 0
    Events.OnTick.Add(function()
        _knoxCounter = _knoxCounter + 1
        if _knoxCounter >= 30 then
            _knoxCounter = 0
            knoxTick()
        end
    end)
end

-- =========================================================================
-- Bath water state (server-authoritative mirror)
-- =========================================================================

local function getSquareFromBathArgs(args)
    if not args or not getCell then return nil end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z or 0)
    if not x or not y then return nil end
    local cell = getCell()
    if not cell or not cell.getGridSquare then return nil end
    return cell:getGridSquare(x, y, z)
end

local function getSpriteName(obj)
    local spr = obj and obj.getSprite and obj:getSprite() or nil
    return spr and spr.getName and spr:getName() or nil
end

local function findBathTarget(args)
    local square = getSquareFromBathArgs(args)
    if not square then return nil end
    local objects = square.getObjects and square:getObjects() or nil
    if not objects then return nil end
    local wantedSprite = tostring(args.sprite or "")
    local fallback = nil
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and CSR_BathWater and CSR_BathWater.isTubObject and CSR_BathWater.isTubObject(obj) then
            if wantedSprite == "" or getSpriteName(obj) == wantedSprite then
                return obj
            end
            fallback = fallback or obj
        end
    end
    return fallback
end

function CSR_ServerCommands.handleBathSetWater(player, args)
    if not player or not args then return end
    local tub = findBathTarget(args)
    if not tub then return end
    local sq = tub.getSquare and tub:getSquare() or nil
    if not sq then return end
    if math.abs(player:getX() - sq:getX()) > 4
        or math.abs(player:getY() - sq:getY()) > 4
        or math.abs(player:getZ() - sq:getZ()) > 2 then
        return
    end
    local amount = tonumber(args.amount)
    if amount == nil then return end
    if CSR_BathWater and CSR_BathWater.applyLocal then
        local current = CSR_BathWater.getAmount and CSR_BathWater.getAmount(tub) or 0
        if amount > current and CSR_BathWater.squareHasRunningWater then
            local playerSquare = player.getCurrentSquare and player:getCurrentSquare() or nil
            local hasWater = CSR_BathWater.squareHasRunningWater(sq)
                or CSR_BathWater.squareHasRunningWater(playerSquare)
            if not hasWater then return end
        end
        CSR_BathWater.applyLocal(tub, amount)
    end
end

local function bathPlayerNearTub(player, tub)
    local sq = tub and tub.getSquare and tub:getSquare() or nil
    if not player or not sq then return false end
    return math.abs(player:getX() - sq:getX()) <= 4
        and math.abs(player:getY() - sq:getY()) <= 4
        and math.abs(player:getZ() - sq:getZ()) <= 2
end

local function bathCleanBody(player)
    if not player or not BloodBodyPartType or not BloodBodyPartType.MAX then return end
    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        if player.setBloodLevel then player:setBloodLevel(part, 0) end
        if player.setDirtLevel then player:setDirtLevel(part, 0) end
        local visual = player.getHumanVisual and player:getHumanVisual() or nil
        if visual then
            visual:setBlood(part, 0)
            visual:setDirt(part, 0)
        end
    end
end

local function bathClearMakeup(player)
    if not player or not ItemBodyLocation then return end
    local locations = {
        ItemBodyLocation.MAKE_UP_FULL_FACE,
        ItemBodyLocation.MAKE_UP_EYES,
        ItemBodyLocation.MAKE_UP_EYES_SHADOW,
        ItemBodyLocation.MAKE_UP_LIPS,
    }
    for i = 1, #locations do
        local loc = locations[i]
        local item = loc and player.getWornItem and player:getWornItem(loc) or nil
        if item then
            player:removeWornItem(item)
            local inv = player.getInventory and player:getInventory() or nil
            if inv then inv:Remove(item) end
        end
    end
end

local function bathClearMuscleStrain(player)
    if not player or not BodyPartType or not BodyPartType.MAX then return end
    local bd = player.getBodyDamage and player:getBodyDamage() or nil
    if not bd then return end
    local fitness = player.getFitness and player:getFitness() or nil
    for i = 0, BodyPartType.MAX:index() - 1 do
        local bpType = BodyPartType.FromIndex(i)
        local part = bd:getBodyPart(bpType)
        if part and part.getStiffness and part:getStiffness() > 0 then
            part:setStiffness(0)
            if fitness and fitness.removeStiffnessValue then
                fitness:removeStiffnessValue(BodyPartType.ToString(bpType))
            end
        end
    end
end

local function bathSyncPlayer(player)
    if not player then return end
    if player.resetModelNextFrame then player:resetModelNextFrame() end
    if syncVisuals then syncVisuals(player) end
    if sendHumanVisual then sendHumanVisual(player) end
    if player.sendVisual then player:sendVisual() end
    if player.sendBloodBodyPartSync then player:sendBloodBodyPartSync() end
    if player.sendInventory then player:sendInventory() end
end

function CSR_ServerCommands.handleBathComplete(player, args)
    if not player or not args then return end
    if sandbox().EnableBathing == false then return end
    local tub = findBathTarget(args)
    if not tub or not bathPlayerNearTub(player, tub) then return end

    local consumeWater = tonumber(args.consumeWater) or 0
    if consumeWater > 0 and CSR_BathWater and CSR_BathWater.getAmount and CSR_BathWater.applyLocal then
        local current = CSR_BathWater.getAmount(tub)
        if current < consumeWater then
            sendResult(player, "Not enough bath water.")
            return
        end
        CSR_BathWater.applyLocal(tub, current - consumeWater)
    end

    bathCleanBody(player)
    bathClearMakeup(player)

    local bd = player.getBodyDamage and player:getBodyDamage() or nil
    if bd then
        if bd.getColdStrength and bd.setHasACold and bd:getColdStrength() < 1 then
            bd:setHasACold(false)
        end
        if bd.decreaseBodyWetness then bd:decreaseBodyWetness(100) end
    end

    local stats = player.getStats and player:getStats() or nil
    if stats then
        if stats.remove and CharacterStat then
            if CharacterStat.BOREDOM then stats:remove(CharacterStat.BOREDOM, 0.1) end
            if CharacterStat.UNHAPPINESS then stats:remove(CharacterStat.UNHAPPINESS, 0.1) end
        end
        if stats.setEndurance and stats.getEndurance then
            stats:setEndurance(math.min(1.0, (tonumber(stats:getEndurance()) or 0) + 0.2))
        end
    end

    if sandbox().BathingClearsMuscleStrain ~= false then
        bathClearMuscleStrain(player)
    end

    bathSyncPlayer(player)
end

-- =========================================================================
-- Roof Climb persistence (server-authoritative)
-- =========================================================================

local function isRoofPeerVisualSyncEnabled()
    return sandbox().RoofClimbPeerVisualSync == true
end

local function sendRoofClimbPeerState(recipient, roofPlayer, active, vehicleId)
    if not recipient or not roofPlayer or not sendServerCommand then return end
    local onlineId = roofPlayer.getOnlineID and roofPlayer:getOnlineID() or nil
    if not onlineId then return end
    sendServerCommand(recipient, "CommonSenseLight", "RoofClimbPeerSync", {
        playerOnlineID = onlineId,
        vehicleId = tonumber(vehicleId) or -1,
        active = active == true,
    })
end

local function broadcastRoofClimbPeerState(roofPlayer, active, vehicleId)
    if not isRoofPeerVisualSyncEnabled() then return end
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return end
    for i = 0, players:size() - 1 do
        sendRoofClimbPeerState(players:get(i), roofPlayer, active, vehicleId)
    end
end

local function sendRoofClimbRoster(recipient)
    if not isRoofPeerVisualSyncEnabled() then return end
    if not recipient then return end
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return end
    for i = 0, players:size() - 1 do
        local candidate = players:get(i)
        if candidate and candidate ~= recipient then
            local md = candidate.getModData and candidate:getModData() or nil
            local state = md and md.csrOnVehicleRoof or nil
            if state and state.vehicleId then
                sendRoofClimbPeerState(recipient, candidate, true, state.vehicleId)
            end
        end
    end
end

function CSR_ServerCommands.handleRoofClimbSet(player, args)
    if not player or not args or not args.vehicleId then return end
    local vehicleId = tonumber(args.vehicleId)
    if not vehicleId then return end
    local v = getVehicleById and getVehicleById(vehicleId) or nil
    if not v then return end
    -- Proximity sanity check: server rejects if player is far from the vehicle.
    if math.abs(player:getX() - v:getX()) > 4
        or math.abs(player:getY() - v:getY()) > 4
        or math.abs(player:getZ() - v:getZ()) > 2 then
        return
    end
    local md = player:getModData()
    md.csrOnVehicleRoof = { vehicleId = vehicleId }
    if player.transmitModData then player:transmitModData() end
    broadcastRoofClimbPeerState(player, true, vehicleId)
    sendRoofClimbRoster(player)
end

function CSR_ServerCommands.handleRoofClimbClear(player, args)
    if not player then return end
    local md = player:getModData()
    local vehicleId = md.csrOnVehicleRoof and md.csrOnVehicleRoof.vehicleId or nil
    md.csrOnVehicleRoof = nil
    if player.transmitModData then player:transmitModData() end
    broadcastRoofClimbPeerState(player, false, vehicleId)
end

function CSR_ServerCommands.handleRoofClimbRequestRoster(player, args)
    sendRoofClimbRoster(player)
end

return CSR_ServerCommands
