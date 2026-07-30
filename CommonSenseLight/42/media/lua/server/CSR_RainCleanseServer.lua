-- CSR_RainCleanseServer.lua
-- Server-owned rain cleanup for MP-visible world state: street/exterior blood
-- and vehicle blood. Player body/gear visuals stay client-side for the local
-- player and sync through vanilla character/inventory channels.

require "CSR_FeatureFlags"

CSR_RainCleanseServer = CSR_RainCleanseServer or {}

local MIN_INTENSITY = 0.10
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

local function tileBudgetPerPlayer()
    local v = tonumber(sandbox().RainCleanseTilesPerTick or 8) or 8
    if v < 1 then v = 1 end
    if v > 32 then v = 32 end
    return v * 6
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

local function onlinePlayers()
    local out = {}
    if getOnlinePlayers then
        local list = getOnlinePlayers()
        if list and list.size and list.get then
            for i = 0, list:size() - 1 do
                local player = list:get(i)
                if player then out[#out + 1] = player end
            end
        end
    end
    if #out == 0 and getNumActivePlayers and getSpecificPlayer then
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player then out[#out + 1] = player end
        end
    end
    return out
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

local function cleanExteriorStainsAround(player, intensity)
    if not CSR_FeatureFlags.isRainCleanseExteriorsEnabled() then return 0 end

    local square = player and player.getCurrentSquare and player:getCurrentSquare() or nil
    if not isOutsideSquare(square) then return 0 end
    local cell = getCell and getCell() or nil
    if not cell then return 0 end

    local px, py, pz = square:getX(), square:getY(), square:getZ()
    local radius = 20
    local budget = math.max(1, math.floor(tileBudgetPerPlayer() / 3))
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

local function cleanStreetBloodAround(player, intensity)
    local square = player and player.getCurrentSquare and player:getCurrentSquare() or nil
    if not square or not square.isOutside or not square:isOutside() then return 0 end
    local cell = getCell and getCell() or nil
    if not cell then return 0 end

    local px, py, pz = square:getX(), square:getY(), square:getZ()
    local radius = 24
    local budget = tileBudgetPerPlayer()
    local chanceInt = math.floor(math.min(0.35, 0.10 + intensity * 0.25) * 10000)
    local cleaned = 0

    for _ = 1, budget do
        local x = px + ZombRand(radius * 2 + 1) - radius
        local y = py + ZombRand(radius * 2 + 1) - radius
        local sq = cell:getGridSquare(x, y, pz)
        if sq and sq.isOutside and sq:isOutside()
                and sq.haveBlood and sq:haveBlood()
                and ZombRand(10000) < chanceInt then
            sq:removeBlood(false, false)
            cleaned = cleaned + 1
        end
    end
    return cleaned
end

local function cleanVehicle(vehicle, rmod)
    if not vehicle or not vehicle.getBloodIntensity or not vehicle.setBloodIntensity then return false end
    local changed = false
    for i = 1, #VEHICLE_AREAS do
        local area = VEHICLE_AREAS[i]
        local oldBlood = tonumber(vehicle:getBloodIntensity(area)) or 0
        if oldBlood > 0 then
            vehicle:setBloodIntensity(area, reduceLevel(oldBlood, rmod * 0.012))
            changed = true
        end
    end
    if changed and vehicle.transmitBlood then vehicle:transmitBlood() end
    return changed
end

local function scanVehicleSquare(square, rmod, seen)
    if not square or not square.getMovingObjects then return 0 end
    local objects = square:getMovingObjects()
    if not objects then return 0 end
    local cleaned = 0
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object and instanceof(object, "BaseVehicle") and not seen[object] then
            seen[object] = true
            if cleanVehicle(object, rmod) then cleaned = cleaned + 1 end
        end
    end
    return cleaned
end

local function cleanVehiclesAround(player, rmod)
    local square = player and player.getCurrentSquare and player:getCurrentSquare() or nil
    if not square or not square.isOutside or not square:isOutside() then return 0 end
    local cell = getCell and getCell() or nil
    if not cell then return 0 end

    local px, py, pz = square:getX(), square:getY(), square:getZ()
    local seen = {}
    local cleaned = 0
    for dx = -8, 8 do
        for dy = -8, 8 do
            cleaned = cleaned + scanVehicleSquare(cell:getGridSquare(px + dx, py + dy, pz), rmod, seen)
        end
    end
    return cleaned
end

local function onMinute()
    if not CSR_FeatureFlags.isRainCleanseEnabled() then return end
    local intensity = getActiveIntensity()
    if intensity <= 0 then return end
    local rmod = rainCurve(intensity)
    local players = onlinePlayers()
    for i = 1, #players do
        cleanStreetBloodAround(players[i], intensity)
        cleanExteriorStainsAround(players[i], intensity)
        cleanVehiclesAround(players[i], rmod)
    end
end

Events.EveryOneMinute.Add(onMinute)

return CSR_RainCleanseServer
