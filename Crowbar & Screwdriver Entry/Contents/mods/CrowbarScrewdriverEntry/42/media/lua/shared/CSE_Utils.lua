require "CSE_Config"
require "CSE_FenceData"

CSE_Utils = {}

local function sandbox()
    return SandboxVars and SandboxVars.CrowbarScrewdriverEntry or {}
end

-- ============================================================
-- Tool detection
-- ============================================================

-- Recursively walks a player's inventory (including nested bags) and returns
-- the matching item with the lowest condition, so a beat-up spare gets used
-- up before a pristine one.
function CSE_Utils.findPreferredInventoryItem(player, matcher)
    if not player or not matcher then
        return nil
    end

    local inventory = player:getInventory()
    if not inventory then
        return nil
    end

    local best = nil
    local visited = {}

    local function searchContainer(container)
        if not container or visited[container] then return end
        visited[container] = true
        local items = container.getItems and container:getItems() or nil
        if not items then return end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and matcher(item) then
                if not best then
                    best = item
                else
                    local bestCond = best.getCondition and best:getCondition() or nil
                    local itemCond = item.getCondition and item:getCondition() or nil
                    if bestCond and itemCond and itemCond < bestCond then
                        best = item
                    end
                end
            end
            local subInv = item and item.getInventory and item:getInventory() or nil
            if subInv then
                searchContainer(subInv)
            end
        end
    end

    searchContainer(inventory)
    return best
end

function CSE_Utils.findPreferredInventoryItemByTypes(player, types)
    return CSE_Utils.findPreferredInventoryItem(player, function(item)
        if not item or not item.getType then return false end
        local itemType = item:getType()
        for i = 1, #types do
            if itemType == types[i] then return true end
        end
        return false
    end)
end

function CSE_Utils.findInventoryItemById(player, itemId)
    if not player or not itemId then return nil end
    local inventory = player:getInventory()
    if not inventory then return nil end

    local visited = {}
    local function search(container)
        if not container or visited[container] then return nil end
        visited[container] = true
        local items = container.getItems and container:getItems() or nil
        if not items then return nil end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and item.getID and item:getID() == itemId then
                return item
            end
        end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            local subInv = item and item.getInventory and item:getInventory() or nil
            if subInv then
                local found = search(subInv)
                if found then return found end
            end
        end
        return nil
    end

    return search(inventory)
end

function CSE_Utils.hasCrowbar(player)
    if not player or not player.getInventory then return nil end
    local inv = player:getInventory()
    local item = inv:FindAndReturn("Crowbar")
    if item then return item end
    if ItemTag and ItemTag.CROWBAR and inv.getFirstTagRecurse then
        return inv:getFirstTagRecurse(ItemTag.CROWBAR)
    end
    if ItemTag and ItemTag.PRY_BAR and inv.getFirstTagRecurse then
        return inv:getFirstTagRecurse(ItemTag.PRY_BAR)
    end
    return nil
end

local SCREWDRIVER_TYPES = { "Screwdriver", "Screwdriver_Old", "Screwdriver_Improvised" }

function CSE_Utils.isScrewdriver(item)
    if not item or not item.getType then return false end
    local itemType = item:getType()
    for i = 1, #SCREWDRIVER_TYPES do
        if itemType == SCREWDRIVER_TYPES[i] then return true end
    end
    return false
end

function CSE_Utils.hasScrewdriver(player)
    return CSE_Utils.findPreferredInventoryItemByTypes(player, SCREWDRIVER_TYPES)
end

local BOLT_CUTTER_TYPES = { "BoltCutters" }

function CSE_Utils.hasBoltCutters(player)
    local item = CSE_Utils.findPreferredInventoryItemByTypes(player, BOLT_CUTTER_TYPES)
    if item then return item end

    -- B42 also lets other mods mark their own cutters with the vanilla tag.
    -- ItemTag.get throws on an unregistered ResourceLocation, hence the pcall.
    if not player or not player.getInventory then return nil end
    local inv = player:getInventory()
    if inv and inv.getFirstTagRecurse and ItemTag and ItemTag.get and ResourceLocation and ResourceLocation.of then
        local ok, tag = pcall(function() return ItemTag.get(ResourceLocation.of("base:boltcutters")) end)
        if ok and tag then
            return inv:getFirstTagRecurse(tag)
        end
    end

    return nil
end

-- ============================================================
-- Timing
-- ============================================================

-- Every entry action runs its base duration through here, so a single
-- sandbox knob speeds up or drags out prying, lockpicking and cutting alike.
function CSE_Utils.scaleActionTime(baseTime, extraMultiplier)
    local mult = tonumber(sandbox().ActionTimeMultiplier) or 1.0
    if mult <= 0 then mult = 1.0 end

    extraMultiplier = tonumber(extraMultiplier) or 1.0
    if extraMultiplier <= 0 then extraMultiplier = 1.0 end

    return math.max(CSE_Config.MIN_ACTION_TIME, math.floor(baseTime * mult * extraMultiplier))
end

-- ============================================================
-- World target validity
-- ============================================================

local function isDoorObject(target)
    return instanceof(target, "IsoDoor")
        or (instanceof(target, "IsoThumpable") and target.isDoor and target:isDoor())
end

local function isDoorClosed(target)
    return target and target.IsOpen and not target:IsOpen()
end

function CSE_Utils.isBarricadedForPlayer(target, character)
    if not target or not character or not target.getBarricadeForCharacter then
        return false
    end
    return target:getBarricadeForCharacter(character) ~= nil
end

-- Doors/gates the base game marks "forceLocked" require a matching key even
-- after setLocked(false) — vanilla security/vault doors work this way. We
-- detect the tile property so pry/lockpick can hand the player a matching
-- key instead of silently failing to open.
function CSE_Utils.hasForceLockedProperty(target)
    local spriteObj = target and target.getSprite and target:getSprite() or nil
    if not spriteObj or not spriteObj.getProperties then return false end
    local props = spriteObj:getProperties()
    if not props or not props.has then return false end
    local ok, has = pcall(function() return props:has("forceLocked") end)
    return ok and has == true
end

-- After a successful force-entry, a forceLocked door re-locks itself the
-- next time it closes. We tag it in modData so the context menu can offer
-- "Force Open Again" instead of just "locked, nothing to do here".
function CSE_Utils.isPryRetryTarget(target)
    if not isDoorObject(target) or not isDoorClosed(target) then return false end
    return CSE_Utils.wasForcedBefore(target) or CSE_Utils.hasForceLockedProperty(target)
end

-- True once this door has been forced at least once, whatever the tool was.
-- The reinforced-door gates below test this directly rather than going
-- through isPryRetryTarget: that one also returns true for any door with the
-- forceLocked property, so gating on it could never block a first attempt.
function CSE_Utils.wasForcedBefore(target)
    local md = target and target.getModData and target:getModData() or nil
    return md ~= nil and md.cseForced == true
end

-- Shared gate for reinforced/security (forceLocked) doors: an admin can put
-- them off-limits entirely, or behind a Strength requirement. Doors already
-- forced once are exempt so re-entry never gets walled off retroactively.
--
-- minStrength is passed in rather than read here because the requirement is
-- about muscling a crowbar; a tool with its own mechanical advantage passes 0.
function CSE_Utils.canBreakReinforcedDoor(target, player, enabled, minStrength)
    if not CSE_Utils.hasForceLockedProperty(target) then return true end
    if CSE_Utils.wasForcedBefore(target) then return true end

    if enabled ~= true then
        return false, "Reinforced doors disabled"
    end

    minStrength = tonumber(minStrength) or 0
    if minStrength > 0 and player and player.getPerkLevel and player:getPerkLevel(Perks.Strength) < minStrength then
        return false, "Need more strength"
    end

    return true
end

function CSE_Utils.isGarageDoor(target)
    if not target then return false end

    if instanceof(target, "IsoDoor") and IsoDoor and IsoDoor.getGarageDoorFirst then
        if IsoDoor.getGarageDoorFirst(target) then return true end
    end

    local sq = target.getSquare and target:getSquare() or nil
    if sq and sq.getGarageDoor then
        if sq:getGarageDoor(true) or sq:getGarageDoor(false) then return true end
    end

    local sprite = target.getSprite and target:getSprite() or nil
    if sprite and sprite.getName then
        local name = sprite:getName() or ""
        if string.find(name, "garage", 1, true) or string.find(name, "industry_truck", 1, true) then
            return true
        end
    end

    if buildUtil and buildUtil.getGarageDoorObjects then
        local objects = buildUtil.getGarageDoorObjects(target)
        if objects and #objects > 0 then return true end
    end

    return false
end

-- A closed, locked door/gate or a closed, locked window: anything the
-- crowbar or screwdriver could plausibly work on.
function CSE_Utils.isPryTarget(target)
    if not target then return false end

    if isDoorObject(target) then
        if not isDoorClosed(target) then return false end
        return (target.isLocked and target:isLocked())
            or (target.isLockedByKey and target:isLockedByKey())
            or CSE_Utils.isPryRetryTarget(target)
    end

    if instanceof(target, "IsoWindow") then
        if target:IsOpen() or (target.isSmashed and target:isSmashed()) then
            return false
        end
        if target.isPermaLocked and target:isPermaLocked() then
            return false
        end
        return (target.isLocked and target:isLocked()) or false
    end

    return false
end

function CSE_Utils.canPryWorldTarget(target, player)
    if not CSE_Utils.isPryTarget(target) then
        return false, "Not a pry target"
    end
    if CSE_Utils.isBarricadedForPlayer(target, player) then
        return false, "Target is barricaded"
    end

    if instanceof(target, "IsoWindow") then
        return true
    end

    if CSE_Utils.isGarageDoor(target) and sandbox().EnableGarageDoorPry == false then
        return false, "Garage door prying disabled"
    end

    return CSE_Utils.canBreakReinforcedDoor(
        target, player,
        sandbox().EnableReinforcedDoorPry == true,
        sandbox().ReinforcedDoorStrengthRequired or 8
    )
end

function CSE_Utils.canLockpickWorldTarget(target, player)
    if not target then
        return false, "Not a lockpick target"
    end
    if CSE_Utils.isBarricadedForPlayer(target, player) then
        return false, "Target is barricaded"
    end
    if not isDoorObject(target) then
        return false, "Not a door"
    end
    if target:IsOpen() then
        return false, "Door already open"
    end
    return (target.isLocked and target:isLocked()) or (target.isLockedByKey and target:isLockedByKey()) or false
end

-- Bolt cutters go through the lock itself rather than the frame, so unlike
-- prying they don't care whether the door is reinforced - but they're no use
-- on a window, which has nothing to cut.
--
-- forceLocked doors are matched explicitly rather than via isPryRetryTarget:
-- a security door re-locks itself through the sprite property with isLocked
-- still false, but isPryRetryTarget would also match any ordinary door the
-- player once forced, and there is no lock left to cut on one of those.
function CSE_Utils.isBoltCutterTarget(target)
    if not isDoorObject(target) then return false end
    if not isDoorClosed(target) then return false end
    return (target.isLocked and target:isLocked())
        or (target.isLockedByKey and target:isLockedByKey())
        or CSE_Utils.hasForceLockedProperty(target)
end

function CSE_Utils.canBoltCutWorldTarget(target, player)
    if not CSE_Utils.isBoltCutterTarget(target) then
        return false, "Not a bolt cutter target"
    end
    if CSE_Utils.isBarricadedForPlayer(target, player) then
        return false, "Target is barricaded"
    end
    -- Bolt cutters get their own reinforced-door toggle, defaulting to on:
    -- a chain and padlock give way to them even where a crowbar wouldn't.
    return CSE_Utils.canBreakReinforcedDoor(target, player, sandbox().EnableReinforcedDoorBoltCut ~= false)
end

-- Wire-fence panels are plain IsoObjects, not doors or thumpables, so there
-- is no lock state to read - the only reliable signal is the tile sprite,
-- matched against the whitelist in CSE_FenceData.
function CSE_Utils.isFenceCutTarget(target)
    if not target or not CSE_FenceData then return false end
    local sprite = target.getSprite and target:getSprite() or nil
    local name = sprite and sprite.getName and sprite:getName() or nil
    return CSE_FenceData.isCuttableSprite(name)
end

function CSE_Utils.canBoltCutFence(target, player)
    if not CSE_Utils.isFenceCutTarget(target) then
        return false, "Not a fence panel"
    end
    if not (target.getSquare and target:getSquare()) then
        return false, "No square"
    end
    return true
end

function CSE_Utils.findWorldTarget(worldobjects, player, predicate)
    if not predicate then return nil end

    local function distSq(obj)
        local square = obj and obj.getSquare and obj:getSquare() or nil
        if not player or not square then return math.huge end
        return IsoUtils.DistanceToSquared(player:getX(), player:getY(), square:getX() + 0.5, square:getY() + 0.5)
    end

    local best, bestDist = nil, math.huge
    local function consider(obj)
        if obj and predicate(obj) then
            local d = distSq(obj)
            if d < bestDist then
                best, bestDist = obj, d
            end
        end
    end

    for _, obj in ipairs(worldobjects or {}) do
        consider(obj)
    end
    if best then return best end

    -- Right-clicking a door/window sometimes hands us an empty worldobjects
    -- list (the sprite itself has no inventory), so fall back to scanning
    -- the clicked square and its neighbours directly.
    local fetch = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars or nil
    local clickedSquare = fetch and fetch.clickedSquare or nil
    if not clickedSquare or not getCell then return nil end

    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = getCell():getGridSquare(clickedSquare:getX() + dx, clickedSquare:getY() + dy, clickedSquare:getZ())
            if square then
                local objects = square:getObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        consider(objects:get(i))
                    end
                end
            end
        end
    end

    return best
end

-- ============================================================
-- Vehicle door target validity
-- ============================================================

function CSE_Utils.canPryVehiclePart(part)
    if not part or not part.getDoor or not part:getDoor() then return false end
    local partId = part.getId and string.lower(part:getId() or "") or ""
    if partId == "" or partId == "enginedoor" then return false end
    return part:getDoor():isLocked()
end

function CSE_Utils.canLockpickVehiclePart(part)
    return CSE_Utils.canPryVehiclePart(part)
end

function CSE_Utils.findVehicleActionPart(player, vehicle, validator)
    if not player or not vehicle or not validator or not vehicle.getPartCount or not vehicle.getPartByIndex then
        return nil
    end

    if vehicle.getUseablePart then
        local useablePart = vehicle:getUseablePart(player)
        if useablePart and validator(useablePart) then
            return useablePart
        end
    end

    local bestPart, bestDist = nil, math.huge
    for partIndex = 1, vehicle:getPartCount() do
        local part = vehicle:getPartByIndex(partIndex - 1)
        if part and validator(part) then
            local area = part.getArea and part:getArea() or nil
            local areaCenter = area and vehicle.getAreaCenter and vehicle:getAreaCenter(area) or nil
            local dist = math.huge
            if areaCenter and areaCenter.x and areaCenter.y then
                dist = IsoUtils.DistanceToSquared(player:getX(), player:getY(), areaCenter.x, areaCenter.y)
            elseif vehicle.getX and vehicle.getY then
                dist = IsoUtils.DistanceToSquared(player:getX(), player:getY(), vehicle:getX(), vehicle:getY())
            end
            if dist < bestDist then
                bestDist, bestPart = dist, part
            end
        end
    end

    return bestPart
end

-- ============================================================
-- Unlock mechanics
-- ============================================================

-- Clears every lock flag on a door and, if it's a double door or garage
-- door, on every linked panel too - otherwise you'd force one half open
-- and the other half would still read as locked.
function CSE_Utils.unlockTarget(target, character, skipOpen)
    if not target then return false end

    if isDoorObject(target) then
        local linkedDoors, seen = {}, {}
        local function addLinkedDoor(obj)
            if obj and not seen[obj] then
                seen[obj] = true
                table.insert(linkedDoors, obj)
            end
        end

        addLinkedDoor(target)

        if instanceof(target, "IsoDoor") and IsoDoor then
            if IsoDoor.getDoubleDoorObject then
                for i = 1, 4 do
                    local linked = IsoDoor.getDoubleDoorObject(target, i)
                    if linked then addLinkedDoor(linked) else break end
                end
            end
            if IsoDoor.getGarageDoorFirst then
                local garageDoor = IsoDoor.getGarageDoorFirst(target)
                while garageDoor do
                    addLinkedDoor(garageDoor)
                    garageDoor = IsoDoor.getGarageDoorNext and IsoDoor.getGarageDoorNext(garageDoor) or nil
                end
            end
        end

        if instanceof(target, "IsoThumpable") and buildUtil then
            if buildUtil.getDoubleDoorObjects then
                for _, obj in ipairs(buildUtil.getDoubleDoorObjects(target) or {}) do
                    addLinkedDoor(obj)
                end
            end
            if buildUtil.getGarageDoorObjects then
                for _, obj in ipairs(buildUtil.getGarageDoorObjects(target) or {}) do
                    addLinkedDoor(obj)
                end
            end
        end

        for _, doorObj in ipairs(linkedDoors) do
            if doorObj.setLocked then doorObj:setLocked(false) end
            if doorObj.setLockedByKey then doorObj:setLockedByKey(false) end
            if doorObj.setIsLocked then doorObj:setIsLocked(false) end
            if doorObj.setPermaLocked then doorObj:setPermaLocked(false) end
            if doorObj.getModData then
                local md = doorObj:getModData()
                if md then md.cseForced = true end
            end
            if doorObj.syncIsoObject then doorObj:syncIsoObject(false, 0, nil, nil) end
            if doorObj.transmitModData then doorObj:transmitModData() end
        end

        if not skipOpen and character and target.ToggleDoor and not target:IsOpen() then
            local hasForceLocked = CSE_Utils.hasForceLockedProperty(target)

            if hasForceLocked then
                -- Vanilla's ToggleDoor refuses forceLocked doors without a key
                -- matching the door's keyId, even once isLocked is false. Mint
                -- one, use it, then leave a permanent copy on the player so
                -- re-opening after a close never requires prying again.
                local keyId = target.getKeyId and target:getKeyId() or -1
                if not keyId or keyId < 0 then
                    keyId = ZombRand(65534) + 1
                    if target.setKeyId then
                        target:setKeyId(keyId)
                        if target.syncIsoObject then target:syncIsoObject(false, 0, nil, nil) end
                    end
                end

                local inv = character:getInventory()
                local tempKey = instanceItem("Base.Key1")
                if tempKey and tempKey.setKeyId then tempKey:setKeyId(keyId) end
                if tempKey then inv:AddItem(tempKey) end
                target:ToggleDoor(character)
                if tempKey then inv:Remove(tempKey) end

                local permKey = instanceItem("Base.Key1")
                if permKey then
                    permKey:setKeyId(keyId)
                    if permKey.setName then permKey:setName("Forced Key") end
                    if permKey.setCustomName then permKey:setCustomName(true) end
                    local keyring = (inv.FindAndReturn and inv:FindAndReturn("KeyRing"))
                        or (inv.getFirstTypeRecurse and inv:getFirstTypeRecurse("KeyRing"))
                    if keyring and keyring.getInventory then
                        keyring:getInventory():AddItem(permKey)
                    else
                        inv:AddItem(permKey)
                    end
                end
            else
                target:ToggleDoor(character)
            end

            if target.syncIsoObject then target:syncIsoObject(false, 0, nil, nil) end
        end

        return true
    end

    if instanceof(target, "IsoWindow") then
        if target.setPermaLocked then target:setPermaLocked(false) end
        if target.setIsLocked then target:setIsLocked(false) end
        if target.syncIsoObject then target:syncIsoObject(false, 0, nil, nil) end
        if not skipOpen and character and target.ToggleWindow and not target:IsOpen() then
            target:ToggleWindow(character)
            if target.syncIsoObject then target:syncIsoObject(false, 0, nil, nil) end
        end
        return true
    end

    return false
end

-- Removes a cut fence panel from the world and drops its salvage at the
-- player's feet. Recalculating the square (and its neighbours) is what makes
-- the gap actually walkable instead of leaving an invisible barrier behind.
function CSE_Utils.destroyFencePanel(player, target)
    local sq = target and target.getSquare and target:getSquare() or nil
    if not sq then return false end

    local sprite = target.getSprite and target:getSprite() or nil
    local spriteName = sprite and sprite.getName and sprite:getName() or nil
    local drops = CSE_FenceData and CSE_FenceData.getDrops(spriteName) or nil

    if sq.transmitRemoveItemFromSquare then
        sq:transmitRemoveItemFromSquare(target)
    elseif sq.RemoveTileObject then
        sq:RemoveTileObject(target)
    end
    if sq.RecalcProperties then sq:RecalcProperties() end
    if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end

    if drops and sandbox().EnableFenceSalvage ~= false then
        local dropSquare = (player and player.getCurrentSquare and player:getCurrentSquare()) or sq
        for _, drop in ipairs(drops) do
            for _ = 1, (drop.count or 1) do
                dropSquare:AddWorldInventoryItem(drop.type, 0, 0, 0)
            end
        end
    end

    return true
end

function CSE_Utils.unlockVehicleDoorPart(vehicle, part, character, openDoor, breakLock)
    if not vehicle or not part or not part.getDoor or not part:getDoor() then
        return false
    end

    local door = part:getDoor()

    -- Force-unlock directly. toggleLockedDoor requires the player to be
    -- holding the vehicle key and silently no-ops without one.
    door:setLocked(false)
    if breakLock and door.setLockBroken then
        door:setLockBroken(true)
    end

    if openDoor then
        door:setOpen(true)
        -- Play the open animation so the physics model actually moves the
        -- door out of the way; otherwise the state flips but the collision
        -- geometry still blocks entry.
        if vehicle.playPartAnim then vehicle:playPartAnim(part, "Open") end
        if character and vehicle.playPartSound then vehicle:playPartSound(part, character, "Open") end
    end

    if vehicle.transmitPartDoor then vehicle:transmitPartDoor(part) end

    return not door:isLocked()
end

-- ============================================================
-- Success math
-- ============================================================

function CSE_Utils.calculatePrySuccess(player, tool)
    local strength = player:getPerkLevel(Perks.Strength)
    local fitness = player:getPerkLevel(Perks.Fitness)
    local toolCondition = tool:getCondition() / math.max(1, tool:getConditionMax())
    local multiplier = sandbox().PrySuccessMultiplier or 1.0
    local baseChance = 0.25 + (strength * 0.04) + (fitness * 0.02) + (toolCondition * 0.2)
    return math.min(0.95, math.max(0.05, baseChance * multiplier))
end

-- Bolt cutters sit above the crowbar: the tool does the work, so the floor is
-- higher and condition matters more, but a worn-out pair still bites.
function CSE_Utils.calculateBoltCutSuccess(player, tool)
    local strength = player:getPerkLevel(Perks.Strength)
    local fitness = player:getPerkLevel(Perks.Fitness)
    local toolCondition = tool:getCondition() / math.max(1, tool:getConditionMax())
    local multiplier = sandbox().BoltCutSuccessMultiplier or 1.0
    local baseChance = 0.35 + (strength * 0.04) + (fitness * 0.02) + (toolCondition * 0.25)
    return math.min(0.95, math.max(0.08, baseChance * multiplier))
end

function CSE_Utils.calculateLockpickSuccess(player, tool, target)
    local nimble = player:getPerkLevel(Perks.Nimble)
    local mechanics = player.getPerkLevel and player:getPerkLevel(Perks.Mechanics) or 0
    local fitness = player:getPerkLevel(Perks.Fitness)
    local toolCondition = tool:getCondition() / math.max(1, tool:getConditionMax())

    -- B42 dropped SurvivorDesc:getProfession() in favour of
    -- getCharacterProfession(), which returns a CharacterProfession object.
    -- Its getName() is the registry path, so "burglar" without the namespace.
    local professionBonus = 0
    local descriptor = player.getDescriptor and player:getDescriptor() or nil
    local profession = descriptor and descriptor.getCharacterProfession and descriptor:getCharacterProfession() or nil
    local professionName = profession and profession.getName and profession:getName() or nil
    if professionName == "burglar" then
        professionBonus = 0.08
    end

    local targetPenalty = 0
    if target and target.getDoor and target:getDoor() then
        targetPenalty = 0.04
    end
    if target and target.getId then
        local partId = string.lower(target:getId() or "")
        if partId:find("trunk", 1, true) or partId:find("rear", 1, true) then
            targetPenalty = targetPenalty + 0.02
        end
    end

    local multiplier = sandbox().LockpickSuccessMultiplier or 1.0
    local baseChance = 0.16
        + (nimble * 0.045)
        + (mechanics * 0.015)
        + (fitness * 0.01)
        + (toolCondition * 0.18)
        + professionBonus
        - targetPenalty

    return math.min(0.9, math.max(0.04, baseChance * multiplier))
end

-- ============================================================
-- Shared attempt resolution
--
-- Both the singleplayer client path (TimedAction:perform() running local)
-- and the multiplayer server command handler call these so the mechanics
-- (odds, tool wear, injury, noise, unlocking) live in exactly one place.
-- Callers are expected to have already validated distance/feature toggles/
-- the target itself; these functions only resolve the roll and its effects.
-- ============================================================

-- Severity comes from the sandbox; an explicit amount still wins so callers
-- can force a specific value. InjuryDamage = 0 means "bruise-free", which is
-- how an admin disables the damage without disabling the injury chance.
function CSE_Utils.addInjury(player, amount)
    amount = amount or tonumber(sandbox().InjuryDamage) or CSE_Config.INJURY_DAMAGE
    if not player or amount <= 0 then return end
    local hand = ZombRand(2) == 0 and BodyPartType.Hand_L or BodyPartType.Hand_R
    player:getBodyDamage():AddDamage(hand, amount)
end

local failStreaks = setmetatable({}, { __mode = "k" })

local PRY_FAIL_LINES = {
    "Pry failed",
    "Come on...",
    "It won't budge!",
    "This is really jammed...",
    "Son of a...",
    "I'm gonna break this thing!",
    "Why won't this open?!",
}

local BOLT_CUT_FAIL_LINES = {
    "Bolt cut failed",
    "These are tough...",
    "Almost through!",
    "Come on, snap already!",
    "This metal is thick...",
    "One more try!",
    "I need more leverage!",
}

local LOCKPICK_FAIL_LINES = {
    "Lockpick failed",
    "Almost had it...",
    "Slipped again...",
    "This lock is tricky...",
    "Are you kidding me?!",
    "I can't feel the pins!",
    "This is impossible!",
}

local function nextFailLine(player, lines)
    failStreaks[player] = (failStreaks[player] or 0) + 1
    local idx = math.min(failStreaks[player], #lines)
    return lines[idx]
end

local function resetFailStreak(player)
    failStreaks[player] = nil
end

local function damageTool(tool, amount)
    if tool and tool.getCondition and tool.setCondition then
        tool:setCondition(math.max(0, tool:getCondition() - amount))
    end
end

-- Rounds to nearest rather than flooring to 1, so ToolWearOnFailMultiplier
-- can actually reach zero the way the option's 0.0 minimum advertises.
local function applyToolWear(tool, baseAmount)
    local wearMult = tonumber(sandbox().ToolWearOnFailMultiplier) or 1.0
    local wear = math.floor((baseAmount * wearMult) + 0.5)
    if wear > 0 then
        damageTool(tool, wear)
    end
end

-- Returns success(bool), message(string). Applies noise, tool wear and
-- unlock/injury side effects; does not send network messages or play Say().
function CSE_Utils.resolvePryAttempt(player, target, tool)
    local success = ZombRandFloat(0, 1) < CSE_Utils.calculatePrySuccess(player, tool)
    local noiseMult = sandbox().PryNoiseMultiplier or 1.0
    local sq = target:getSquare()

    if success and CSE_Utils.unlockTarget(target, player, false) then
        addSound(player, sq:getX(), sq:getY(), sq:getZ(), CSE_Config.BASE_NOISE_RADIUS * noiseMult, 1)
        resetFailStreak(player)
        return true, "Got it open!"
    end

    applyToolWear(tool, CSE_Config.TOOL_DAMAGE_ON_FAIL)
    addSound(player, sq:getX(), sq:getY(), sq:getZ(), CSE_Config.BASE_NOISE_RADIUS * noiseMult * 0.5, 1)

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        CSE_Utils.addInjury(player)
        return false, "Ouch!"
    end

    return false, nextFailLine(player, PRY_FAIL_LINES)
end

function CSE_Utils.resolveBoltCutAttempt(player, target, tool)
    local success = ZombRandFloat(0, 1) < CSE_Utils.calculateBoltCutSuccess(player, tool)
    local noiseMult = sandbox().BoltCutNoiseMultiplier or 1.0
    local sq = target:getSquare()

    if success and CSE_Utils.unlockTarget(target, player, false) then
        addSound(player, sq:getX(), sq:getY(), sq:getZ(), CSE_Config.BOLT_CUT_NOISE_RADIUS * noiseMult, 1)
        resetFailStreak(player)
        return true, "Cut through!"
    end

    applyToolWear(tool, CSE_Config.TOOL_DAMAGE_ON_FAIL)
    addSound(player, sq:getX(), sq:getY(), sq:getZ(), CSE_Config.BOLT_CUT_NOISE_RADIUS * noiseMult * 0.5, 1)

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        CSE_Utils.addInjury(player)
        return false, "Ouch!"
    end

    return false, nextFailLine(player, BOLT_CUT_FAIL_LINES)
end

function CSE_Utils.resolveFenceCutAttempt(player, target, tool)
    local success = ZombRandFloat(0, 1) < CSE_Utils.calculateBoltCutSuccess(player, tool)
    local noiseMult = sandbox().BoltCutNoiseMultiplier or 1.0
    local sq = target:getSquare()
    -- Grab the coordinates before cutting: once the panel is removed from the
    -- square, target:getSquare() is no longer safe to read.
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()

    if success and CSE_Utils.destroyFencePanel(player, target) then
        addSound(player, x, y, z, CSE_Config.BOLT_CUT_NOISE_RADIUS * noiseMult, 1)
        resetFailStreak(player)
        return true, "Through the wire!"
    end

    applyToolWear(tool, CSE_Config.TOOL_DAMAGE_ON_FAIL)
    addSound(player, x, y, z, CSE_Config.BOLT_CUT_NOISE_RADIUS * noiseMult * 0.5, 1)

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        CSE_Utils.addInjury(player)
        return false, "Ouch!"
    end

    return false, nextFailLine(player, BOLT_CUT_FAIL_LINES)
end

function CSE_Utils.resolveLockpickAttempt(player, target, tool)
    local success = ZombRandFloat(0, 1) < CSE_Utils.calculateLockpickSuccess(player, tool, target)
    local noiseMult = sandbox().LockpickNoiseMultiplier or 0.4
    local sq = target:getSquare()

    if success and CSE_Utils.unlockTarget(target, player, false) then
        addSound(player, sq:getX(), sq:getY(), sq:getZ(), math.max(1, CSE_Config.LOCKPICK_NOISE_RADIUS * noiseMult), 1)
        resetFailStreak(player)
        return true, "Unlocked it"
    end

    applyToolWear(tool, CSE_Config.LOCKPICK_TOOL_DAMAGE_ON_FAIL)
    addSound(player, sq:getX(), sq:getY(), sq:getZ(), math.max(1, CSE_Config.LOCKPICK_NOISE_RADIUS * noiseMult * 0.5), 1)
    return false, nextFailLine(player, LOCKPICK_FAIL_LINES)
end

function CSE_Utils.resolvePryVehicleAttempt(player, vehicle, part, tool)
    local success = ZombRandFloat(0, 1) < CSE_Utils.calculatePrySuccess(player, tool)

    if success then
        CSE_Utils.unlockVehicleDoorPart(vehicle, part, player, true, true)
        resetFailStreak(player)
        return true, "Got it open!"
    end

    applyToolWear(tool, CSE_Config.TOOL_DAMAGE_ON_FAIL)

    if ZombRandFloat(0, 1) < (sandbox().InjuryChance or 0.1) then
        CSE_Utils.addInjury(player)
        return false, "Ouch!"
    end

    return false, nextFailLine(player, PRY_FAIL_LINES)
end

function CSE_Utils.resolveLockpickVehicleAttempt(player, vehicle, part, tool)
    local success = ZombRandFloat(0, 1) < CSE_Utils.calculateLockpickSuccess(player, tool, part)

    if success then
        CSE_Utils.unlockVehicleDoorPart(vehicle, part, player, true, false)
        resetFailStreak(player)
        return true, "Unlocked it"
    end

    applyToolWear(tool, CSE_Config.LOCKPICK_TOOL_DAMAGE_ON_FAIL)
    return false, nextFailLine(player, LOCKPICK_FAIL_LINES)
end

-- ============================================================
-- Networking helper
-- ============================================================

function CSE_Utils.makeRequestId(player, actionName)
    local onlineId = player and player.getOnlineID and player:getOnlineID() or 0
    local stamp = getTimestampMs and getTimestampMs() or os.time() * 1000
    return table.concat({
        tostring(actionName or "CSE"),
        tostring(onlineId),
        tostring(stamp),
        tostring(ZombRand(1000000)),
    }, ":")
end

return CSE_Utils
