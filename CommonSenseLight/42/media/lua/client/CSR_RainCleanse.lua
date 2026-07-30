-- CSR_RainCleanse.lua
-- Outdoor rain/snow gradually washes blood and dirt from players and exposed
-- gear. Ground and vehicle cleanup is server-owned in MP; this client pass is
-- for the local player's body/visual inventory and SP world cleanup.

require "CSR_FeatureFlags"

CSR_RainCleanse = CSR_RainCleanse or {}

local MIN_INTENSITY = 0.10
local MIN_WETNESS = 0.08
local BLOOD_DROP = 0.055
local DIRT_DROP = 0.075
local TILE_ATTEMPTS = 10
local VEHICLE_AREAS = { "Front", "Rear", "Left", "Right" }
local CARDINAL_DIRS = {
    { x = 1, y = 0 },
    { x = -1, y = 0 },
    { x = 0, y = 1 },
    { x = 0, y = -1 },
}

local function sandbox()
    return SandboxVars and SandboxVars.CommonSenseLight or {}
end

local function clamp01(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function asUnit(value)
    value = tonumber(value) or 0
    if value <= 0 then return 0 end
    if value > 1 then value = value / 100 end
    return clamp01(value)
end

local function reduceLevel(value, unitDrop)
    value = tonumber(value) or 0
    if value <= 0 then return 0 end
    local scale = value > 1 and 100 or 1
    local nextValue = value - ((tonumber(unitDrop) or 0) * scale)
    if nextValue < 0 then return 0 end
    return nextValue
end

local function speedMult()
    local v = tonumber(sandbox().RainCleanseSpeedFactor or 1.0) or 1.0
    if v < 0.1 then v = 0.1 end
    if v > 10 then v = 10 end
    return v
end

local function tilesPerTick()
    local v = tonumber(sandbox().RainCleanseTilesPerTick or 8) or 8
    if v < 1 then v = 1 end
    if v > 32 then v = 32 end
    return v
end

local function getActiveIntensity()
    local cm = getClimateManager and getClimateManager() or nil
    if not cm then return 0 end
    local rain = cm.getRainIntensity and tonumber(cm:getRainIntensity()) or 0
    local snow = cm.getSnowIntensity and tonumber(cm:getSnowIntensity()) or 0
    local best = math.max(rain or 0, snow or 0)
    if best < MIN_INTENSITY then return 0 end
    return clamp01(best)
end

local function rainCurve(intensity)
    intensity = clamp01(intensity)
    return (0.25 + intensity * intensity * 1.75) * speedMult()
end

local function isOutsideSquare(square)
    return square and square.isOutside and square:isOutside()
end

local function effectiveWetness(rawWetness, intensity)
    local wet = asUnit(rawWetness)
    if wet < MIN_WETNESS then
        wet = math.max(wet, clamp01(intensity) * 0.35)
    end
    return wet
end

local function hasExteriorStain(square)
    if not square then return false end
    if square.haveBloodWall and square:haveBloodWall() then return true end
    if square.haveGrimeWall and square:haveGrimeWall() then return true end
    return false
end

local function isWeatherExposedWallSquare(square, cell)
    if isOutsideSquare(square) then return true end
    if not hasExteriorStain(square) then return false end
    if not cell or not square.getX or not square.getY or not square.getZ then return false end

    local x, y, z = square:getX(), square:getY(), square:getZ()
    for i = 1, #CARDINAL_DIRS do
        local dir = CARDINAL_DIRS[i]
        if isOutsideSquare(cell:getGridSquare(x + dir.x, y + dir.y, z)) then
            return true
        end
    end
    return false
end

local function cleanExteriorStainSquare(square)
    if not square then return false end
    local changed = false
    if square.haveBloodWall and square:haveBloodWall() and square.removeBlood then
        square:removeBlood(false, false)
        changed = true
    end
    if square.haveGrimeWall and square:haveGrimeWall() and square.removeGrime then
        square:removeGrime()
        changed = true
    end
    return changed
end

local function getDirtiness(item)
    if not item then return 0 end
    if item.getDirtiness then return tonumber(item:getDirtiness()) or 0 end
    if item.getDirtyness then return tonumber(item:getDirtyness()) or 0 end
    return 0
end

local function setDirtiness(item, value)
    if not item then return end
    if item.setDirtiness then item:setDirtiness(value)
    elseif item.setDirtyness then item:setDirtyness(value) end
end

local function materialMultiplier(item)
    if not item then return 1.0 end
    local fabric = item.getFabricType and tostring(item:getFabricType() or "") or ""
    if fabric == "Leather" then return 0.70 end
    if fabric == "Denim" then return 0.85 end
    return 1.0
end

local function syncPlayerVisual(player, bodyChanged, inventoryChanged)
    if not bodyChanged and not inventoryChanged then return end
    if player.resetModelNextFrame then player:resetModelNextFrame() end
    if isClient and isClient() then
        if bodyChanged and player.sendVisual then player:sendVisual() end
        if bodyChanged and player.sendBloodBodyPartSync then player:sendBloodBodyPartSync() end
        if inventoryChanged and player.sendInventory then player:sendInventory() end
    end
end

local function cleanBodyPart(player, visual, part, dropBlood, dropDirt)
    local changed = false
    local oldBlood = visual.getBlood and visual:getBlood(part) or 0
    if oldBlood and oldBlood > 0 then
        local nextBlood = reduceLevel(oldBlood, dropBlood)
        if visual.setBlood then visual:setBlood(part, nextBlood) end
        if player.setBloodLevel then player:setBloodLevel(part, nextBlood) end
        changed = true
    end
    local oldDirt = visual.getDirt and visual:getDirt(part) or 0
    if oldDirt and oldDirt > 0 then
        local nextDirt = reduceLevel(oldDirt, dropDirt)
        if visual.setDirt then visual:setDirt(part, nextDirt) end
        if player.setDirtLevel then player:setDirtLevel(part, nextDirt) end
        changed = true
    end
    return changed
end

local function sweepSkin(player, rmod, intensity)
    if not player or not BloodBodyPartType or not BloodBodyPartType.MAX then return false end
    local visual = player.getHumanVisual and player:getHumanVisual() or nil
    local body = player.getBodyDamage and player:getBodyDamage() or nil
    local parts = body and body.getBodyParts and body:getBodyParts() or nil
    if not visual or not parts then return false end

    local changed = false
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        if bp and bp.getIndex then
            local wet = effectiveWetness(bp.getWetness and bp:getWetness() or 0, intensity)
            if wet >= MIN_WETNESS then
                local part = BloodBodyPartType.FromIndex(bp:getIndex())
                if part then
                    local dropBlood = rmod * wet * BLOOD_DROP
                    local dropDirt = rmod * wet * DIRT_DROP
                    if cleanBodyPart(player, visual, part, dropBlood, dropDirt) then
                        changed = true
                    end
                    if BodyPartType and bp.getType and bp:getType() == BodyPartType.Torso_Upper
                            and BloodBodyPartType.Back then
                        if cleanBodyPart(player, visual, BloodBodyPartType.Back, dropBlood, dropDirt) then
                            changed = true
                        end
                    end
                end
            end
        end
    end
    return changed
end

local function cleanClothingPart(item, visual, part, dropBlood, dropDirt)
    local changed = false
    if item.getBlood and item.setBlood then
        local oldBlood = tonumber(item:getBlood(part)) or 0
        if oldBlood > 0 then
            item:setBlood(part, reduceLevel(oldBlood, dropBlood))
            changed = true
        end
    end
    if item.getDirt and item.setDirt then
        local oldDirt = tonumber(item:getDirt(part)) or 0
        if oldDirt > 0 then
            item:setDirt(part, reduceLevel(oldDirt, dropDirt))
            changed = true
        end
    end
    if visual then
        if visual.getBlood and visual.setBlood then
            local oldBlood = tonumber(visual:getBlood(part)) or 0
            if oldBlood > 0 then
                visual:setBlood(part, reduceLevel(oldBlood, dropBlood))
                changed = true
            end
        end
        if visual.getDirt and visual.setDirt then
            local oldDirt = tonumber(visual:getDirt(part)) or 0
            if oldDirt > 0 then
                visual:setDirt(part, reduceLevel(oldDirt, dropDirt))
                changed = true
            end
        end
    end
    return changed
end

local function sweepClothing(player, rmod, intensity)
    local worn = player and player.getWornItems and player:getWornItems() or nil
    if not worn or not BloodClothingType then return false end
    local changed = false

    for i = 0, worn:size() - 1 do
        local entry = worn:get(i)
        local item = entry and entry.getItem and entry:getItem() or nil
        if item and item.IsClothing and item:IsClothing()
                and not (item.isHidden and item:isHidden()) then
            local clothingType = item.getBloodClothingType and item:getBloodClothingType() or nil
            local covered = clothingType and BloodClothingType.getCoveredParts
                and BloodClothingType.getCoveredParts(clothingType) or nil
            if covered then
                local wet = effectiveWetness(item.getWetness and item:getWetness() or 0, intensity)
                if wet >= MIN_WETNESS then
                    local mult = materialMultiplier(item)
                    local dropBlood = rmod * wet * BLOOD_DROP * mult
                    local dropDirt = rmod * wet * DIRT_DROP * mult
                    local visual = item.getVisual and item:getVisual() or nil
                    local itemChanged = false
                    for j = 0, covered:size() - 1 do
                        if cleanClothingPart(item, visual, covered:get(j), dropBlood, dropDirt) then
                            itemChanged = true
                        end
                    end
                    if itemChanged then
                        changed = true
                        if BloodClothingType.calcTotalBloodLevel then
                            BloodClothingType.calcTotalBloodLevel(item)
                        end
                        if BloodClothingType.calcTotalDirtLevel then
                            BloodClothingType.calcTotalDirtLevel(item)
                        end
                        if item.synchWithVisual then item:synchWithVisual() end
                    end
                end
            end
        end
    end
    return changed
end

local function cleanGearItem(item, rmod, wet)
    if not item or (item.isHidden and item:isHidden()) then return false end
    local changed = false
    local dropBlood = rmod * wet * BLOOD_DROP
    local dropDirt = rmod * wet * DIRT_DROP

    if item.getBloodLevel and item.setBloodLevel then
        local oldBlood = tonumber(item:getBloodLevel()) or 0
        if oldBlood > 0 then
            item:setBloodLevel(reduceLevel(oldBlood, dropBlood))
            changed = true
        end
    end

    local oldDirt = getDirtiness(item)
    if oldDirt > 0 then
        setDirtiness(item, reduceLevel(oldDirt, dropDirt))
        changed = true
    end
    return changed
end

local function itemIsExposed(player, item)
    if not player or not item then return false end
    if item.isEquipped and item:isEquipped() then return true end
    if player.getPrimaryHandItem and player:getPrimaryHandItem() == item then return true end
    if player.getSecondaryHandItem and player:getSecondaryHandItem() == item then return true end
    if item.getAttachedSlot and tonumber(item:getAttachedSlot()) and tonumber(item:getAttachedSlot()) > 0 then
        return true
    end
    return false
end

local function sweepInventoryCategory(player, category, rmod, wet)
    local inv = player and player.getInventory and player:getInventory() or nil
    local items = inv and inv.getItemsFromCategory and inv:getItemsFromCategory(category) or nil
    if not items then return false end
    local changed = false
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if itemIsExposed(player, item) and cleanGearItem(item, rmod, wet) then
            changed = true
        end
    end
    return changed
end

local function sweepHeldAndGear(player, rmod, intensity)
    if not player or not player.getBodyDamage then return false end
    local bd = player:getBodyDamage()
    local rh = bd and bd.getBodyPart and BodyPartType and bd:getBodyPart(BodyPartType.Hand_R) or nil
    local lh = bd and bd.getBodyPart and BodyPartType and bd:getBodyPart(BodyPartType.Hand_L) or nil
    local handWet = math.max(
        asUnit(rh and rh.getWetness and rh:getWetness() or 0),
        asUnit(lh and lh.getWetness and lh:getWetness() or 0),
        clamp01(intensity) * 0.25
    )
    if handWet < MIN_WETNESS then return false end

    local changed = false
    if cleanGearItem(player:getPrimaryHandItem(), rmod, handWet) then changed = true end
    if cleanGearItem(player:getSecondaryHandItem(), rmod, handWet) then changed = true end
    if sweepInventoryCategory(player, "Weapon", rmod, handWet) then changed = true end
    if sweepInventoryCategory(player, "Container", rmod, handWet * 0.8) then changed = true end
    return changed
end

local function sweepGround(intensity)
    if isClient and isClient() then return end
    local cell = getCell and getCell() or nil
    if not cell or not cell.getMinX then return end
    local minX, minY = cell:getMinX(), cell:getMinY()
    local maxX, maxY = cell:getMaxX(), cell:getMaxY()
    if not (minX and maxX and minX < maxX) then return end

    local chanceInt = math.floor(math.min(0.18, intensity * 0.18) * 10000)
    if chanceInt <= 0 then return end

    for _ = 1, tilesPerTick() do
        local square = nil
        for _ = 1, TILE_ATTEMPTS do
            local candidate = cell:getGridSquare(ZombRand(minX, maxX), ZombRand(minY, maxY), 0)
            if candidate and candidate.isOutside and candidate:isOutside() then
                square = candidate
                break
            end
        end
        if square and square.haveBlood and square:haveBlood() and ZombRand(10000) < chanceInt then
            square:removeBlood(false, false)
        end
    end
end

local function sweepExteriorStainsAround(player, intensity)
    if isClient and isClient() then return 0 end
    if not CSR_FeatureFlags.isRainCleanseExteriorsEnabled() then return 0 end

    local square = player and player.getCurrentSquare and player:getCurrentSquare() or nil
    if not isOutsideSquare(square) then return 0 end
    local cell = getCell and getCell() or nil
    if not cell then return 0 end

    local px, py, pz = square:getX(), square:getY(), square:getZ()
    local radius = 20
    local budget = math.max(1, tilesPerTick() * 2)
    local chanceInt = math.floor(math.min(0.25, 0.06 + intensity * 0.19) * 10000)
    local cleaned = 0

    for _ = 1, budget do
        local x = px + ZombRand(radius * 2 + 1) - radius
        local y = py + ZombRand(radius * 2 + 1) - radius
        local sq = cell:getGridSquare(x, y, pz)
        if hasExteriorStain(sq)
                and isWeatherExposedWallSquare(sq, cell)
                and ZombRand(10000) < chanceInt
                and cleanExteriorStainSquare(sq) then
            cleaned = cleaned + 1
        end
    end
    return cleaned
end

local function cleanVehicle(vehicle, rmod)
    if not vehicle then return false end
    local changed = false
    for i = 1, #VEHICLE_AREAS do
        local area = VEHICLE_AREAS[i]
        if vehicle.getBloodIntensity and vehicle.setBloodIntensity then
            local oldBlood = tonumber(vehicle:getBloodIntensity(area)) or 0
            if oldBlood > 0 then
                vehicle:setBloodIntensity(area, reduceLevel(oldBlood, rmod * 0.010))
                changed = true
            end
        end
    end
    if changed and vehicle.transmitBlood then vehicle:transmitBlood() end
    return changed
end

local function sweepVehicleAt(square, rmod, seen)
    if not square or not square.getMovingObjects then return false end
    local objects = square:getMovingObjects()
    if not objects then return false end
    local changed = false
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object and instanceof(object, "BaseVehicle") and not seen[object] then
            seen[object] = true
            if cleanVehicle(object, rmod) then changed = true end
        end
    end
    return changed
end

local function sweepNearbyVehicles(player, rmod)
    if isClient and isClient() then return false end
    local square = player and player.getCurrentSquare and player:getCurrentSquare() or nil
    if not square or not square.isOutside or not square:isOutside() then return false end
    local cell = getCell and getCell() or nil
    if not cell then return false end
    local px, py, pz = square:getX(), square:getY(), square:getZ()
    local seen = {}
    local changed = false
    for dx = -3, 3 do
        for dy = -3, 3 do
            if sweepVehicleAt(cell:getGridSquare(px + dx, py + dy, pz), rmod, seen) then
                changed = true
            end
        end
    end
    return changed
end

local function onTickGround()
    if not CSR_FeatureFlags.isRainCleanseEnabled() then return end
    local intensity = getActiveIntensity()
    if intensity <= 0 then return end
    sweepGround(intensity)
end

local function onMinutePlayers()
    if not CSR_FeatureFlags.isRainCleanseEnabled() then return end
    local intensity = getActiveIntensity()
    if intensity <= 0 then return end
    local rmod = rainCurve(intensity)

    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        local square = player and player.getCurrentSquare and player:getCurrentSquare() or nil
        if square and square.isOutside and square:isOutside() then
            local bodyChanged = sweepSkin(player, rmod, intensity)
            local inventoryChanged = sweepClothing(player, rmod, intensity)
            if sweepHeldAndGear(player, rmod, intensity) then inventoryChanged = true end
            sweepExteriorStainsAround(player, intensity)
            sweepNearbyVehicles(player, rmod)
            syncPlayerVisual(player, bodyChanged, inventoryChanged)
        end
    end
end

Events.OnTick.Add(onTickGround)
Events.EveryOneMinute.Add(onMinutePlayers)

return CSR_RainCleanse
