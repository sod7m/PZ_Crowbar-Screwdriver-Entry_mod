--[[
    CSR_BatheAction
    ----------------
    Timed action for taking a bath in a filled bathtub. Plays the appropriate
    bath animation, drains water from the tub, removes blood/dirt, clears
    wetness, and (per sandbox) clears all muscle strain on completion.
    In MP, the final cleanse/drain is confirmed by the server via
    CommonSenseLight/BathComplete.

    File-scope class for MP safety. All transient state lives on the action
    instance (self.tub, self.partKey, etc.) -- never on file-scope locals.

    Bathtub sprite map (B42 vanilla bathroom_01_*):
      Side-style (Part1-4):  24, 25, 26, 27, 52, 53, 54, 55  -> CSR_Bath_1
      Lying-style (Part5-8): 22, 23, 30, 31, 32, 33          -> CSR_Bath_2
]]

require "TimedActions/ISBaseTimedAction"
require "CSR_BathWater"

CSR_BatheAction = ISBaseTimedAction:derive("CSR_BatheAction")

local POS_OFFSET = 0.1

local function spriteNameOf(obj)
    local spr = obj and obj.getSprite and obj:getSprite() or nil
    return spr and spr.getName and spr:getName() or ""
end

local function bathCommandArgs(action)
    local tub = action and action.tub or nil
    local sq = tub and tub.getSquare and tub:getSquare() or nil
    if not sq then return nil end
    return {
        x = sq:getX(),
        y = sq:getY(),
        z = sq:getZ(),
        sprite = spriteNameOf(tub),
        consumeWater = action.consumeWater or 0,
        requestId = table.concat({
            "bath",
            tostring(action.character and action.character.getOnlineID and action.character:getOnlineID() or 0),
            tostring(sq:getX()),
            tostring(sq:getY()),
            tostring(sq:getZ()),
            tostring(getTimestampMs and getTimestampMs() or os.time()),
        }, ":"),
    }
end

local function sendBathComplete(action)
    if not (isClient and isClient()) then return false end
    if not sendClientCommand then return false end
    local args = bathCommandArgs(action)
    if not args then return false end
    sendClientCommand(action.character, "CommonSenseLight", "BathComplete", args)
    return true
end

local function cleanBodyLocal(char)
    local visual = char and char.getHumanVisual and char:getHumanVisual() or nil
    if not visual or not BloodBodyPartType or not BloodBodyPartType.MAX then return end
    for i = 1, BloodBodyPartType.MAX:index() do
        local part = BloodBodyPartType.FromIndex(i - 1)
        visual:setBlood(part, 0)
        visual:setDirt(part, 0)
    end
end

function CSR_BatheAction:isValid()
    if not self.tub or not self.tub:getSquare() then return false end
    if self.consumeWater > 0 then
        local avail = CSR_BathWater and CSR_BathWater.getAmount(self.tub) or 0
        if avail < self.consumeWater then return false end
    end
    return true
end

function CSR_BatheAction:waitToStart()
    return self.character:shouldBeTurning()
end

function CSR_BatheAction:start()
    -- Save original position so we can restore on stop/perform.
    self.oldX = self.character:getX()
    self.oldY = self.character:getY()
    self.oldZ = self.character:getZ()
    self.oldPrimary = self.character:getPrimaryHandItem()
    self.oldSecondary = self.character:getSecondaryHandItem()

    -- Stash whatever's in hands so we don't clip the bath anim.
    self.character:setPrimaryHandItem(nil)
    self.character:setSecondaryHandItem(nil)
    self:setOverrideHandModels(nil, nil)

    local sq = self.tub:getSquare()
    if not sq then return end
    local tx, ty = sq:getX(), sq:getY()

    -- Snap into / face the tub depending on orientation. Mirrors the visual
    -- intent of the original mod but only happens once at start (not per tick).
    local part = self.partKey
    if part == "Part1" then
        self.character:setX(tx + POS_OFFSET); self.character:setY(ty + POS_OFFSET)
        self.character:faceLocationF(tx, ty + 0.5)
    elseif part == "Part2" then
        self.character:setX(tx + POS_OFFSET); self.character:setY(ty - 1 + POS_OFFSET)
        self.character:faceLocationF(tx, ty + 0.5)
    elseif part == "Part3" then
        self.character:setX(tx + POS_OFFSET); self.character:setY(ty + POS_OFFSET)
        self.character:faceLocationF(tx + 0.5, ty)
    elseif part == "Part4" then
        self.character:setX(tx - 1 + POS_OFFSET); self.character:setY(ty + POS_OFFSET)
        self.character:faceLocationF(tx + 0.5, ty)
    else
        -- Part5-8: lie inside the tub
        self.character:setX(tx + 0.3); self.character:setY(ty + 0.4)
        self.character:faceLocationF(self.oldX, self.oldY)
    end

    if part == "Part1" or part == "Part2" or part == "Part3" or part == "Part4" then
        self:setActionAnim("CSR_Bath_1")
    else
        self:setActionAnim("CSR_Bath_2")
    end

    -- Bumping body wetness via the public BD API.  B42's BodyDamage has
    -- no top-level setWetness -- per-part setWetness lives on each
    -- BodyPart, so we iterate.  Falling-edge soak; perform() clears it.
    local bd = self.character:getBodyDamage()
    if bd and bd.increaseBodyWetness then
        bd:increaseBodyWetness(60)
    end

    -- Spawn water ripple overlay sprites on the tub.
    self:_initWaterOverlay()
end

-- Water-overlay sprite cycling. Adds one or two transient IsoObjects on the
-- tub's square(s) and ticks them through a ripple animation so the tub looks
-- full of moving water during the bath. Cleaned up in stop() / perform().
local SIDE_SPRITE_LOOP_START = 31
local SIDE_SPRITE_LOOP_END   = 44
local LIE_SPRITE_LOOP_START  = 1
local LIE_SPRITE_LOOP_END    = 5
local SPRITE_TICKS_PER_FRAME = 4

local function spawnOverlay(sq, spriteName)
    if not sq or not spriteName then return nil end
    local obj = IsoObject.new(sq, spriteName)
    if not obj then return nil end
    obj:setCustomColor(1, 1, 1, 1)
    sq:AddTileObject(obj)
    return obj
end

local function removeOverlay(sq, obj)
    if sq and obj then
        obj:setCustomColor(1, 1, 1, 0)
        sq:RemoveTileObject(obj)
    end
end

function CSR_BatheAction:_initWaterOverlay()
    local sq = self.tub:getSquare()
    if not sq then return end
    local tx, ty, tz = sq:getX(), sq:getY(), sq:getZ()
    local cell = getCell()
    if not cell then return end
    local part = self.partKey

    self._waterFrame = 0
    self._waterTick = 0

    if part == "Part1" then
        self._waterStart = SIDE_SPRITE_LOOP_START; self._waterEnd = SIDE_SPRITE_LOOP_END
        self._waterPrefix1 = "fol_tub_A_1_"; self._waterPrefix2 = "fol_tub_A_2_"
        self._waterSq1 = sq
        self._waterSq2 = cell:getGridSquare(tx, ty + 1, tz)
    elseif part == "Part2" then
        self._waterStart = SIDE_SPRITE_LOOP_START; self._waterEnd = SIDE_SPRITE_LOOP_END
        self._waterPrefix1 = "fol_tub_A_1_"; self._waterPrefix2 = "fol_tub_A_2_"
        self._waterSq1 = cell:getGridSquare(tx, ty - 1, tz)
        self._waterSq2 = sq
    elseif part == "Part3" then
        self._waterStart = SIDE_SPRITE_LOOP_START; self._waterEnd = SIDE_SPRITE_LOOP_END
        self._waterPrefix1 = "fol_tub_B_1_"; self._waterPrefix2 = "fol_tub_B_2_"
        self._waterSq1 = sq
        self._waterSq2 = cell:getGridSquare(tx + 1, ty, tz)
    elseif part == "Part4" then
        self._waterStart = SIDE_SPRITE_LOOP_START; self._waterEnd = SIDE_SPRITE_LOOP_END
        self._waterPrefix1 = "fol_tub_B_1_"; self._waterPrefix2 = "fol_tub_B_2_"
        self._waterSq1 = cell:getGridSquare(tx - 1, ty, tz)
        self._waterSq2 = sq
    else
        -- Part5-8 lying-style tubs use a single-tile 5-frame ripple.
        self._waterStart = LIE_SPRITE_LOOP_START; self._waterEnd = LIE_SPRITE_LOOP_END
        self._waterPrefix1 = "fol_tub_" .. tostring(part) .. "_"
        self._waterPrefix2 = nil
        self._waterSq1 = sq
        self._waterSq2 = nil
    end

    self._waterFrame = self._waterStart
    self._waterObj1 = spawnOverlay(self._waterSq1, self._waterPrefix1 .. tostring(self._waterFrame))
    if self._waterPrefix2 then
        self._waterObj2 = spawnOverlay(self._waterSq2, self._waterPrefix2 .. tostring(self._waterFrame))
    end
end

function CSR_BatheAction:_tickWaterOverlay()
    if not self._waterObj1 then return end
    self._waterTick = (self._waterTick or 0) + 1
    if self._waterTick < SPRITE_TICKS_PER_FRAME then return end
    self._waterTick = 0
    self._waterFrame = (self._waterFrame or self._waterStart) + 1
    if self._waterFrame > self._waterEnd then self._waterFrame = self._waterStart end
    local f = tostring(self._waterFrame)
    if self._waterObj1 and self._waterPrefix1 then
        self._waterObj1:setSprite(self._waterPrefix1 .. f)
    end
    if self._waterObj2 and self._waterPrefix2 then
        self._waterObj2:setSprite(self._waterPrefix2 .. f)
    end
end

function CSR_BatheAction:_clearWaterOverlay()
    if self._waterObj1 then removeOverlay(self._waterSq1, self._waterObj1); self._waterObj1 = nil end
    if self._waterObj2 then removeOverlay(self._waterSq2, self._waterObj2); self._waterObj2 = nil end
end

function CSR_BatheAction:update()
    -- Tub water ripple animation.
    self:_tickWaterOverlay()

    -- Light comfort tick.
    local bd = self.character:getBodyDamage()
    if bd and bd.getColdStrength and bd.setColdStrength then
        local cs = tonumber(bd:getColdStrength()) or 0
        if cs > 0 then bd:setColdStrength(cs - 0.06) end
    end
    -- Boredom / unhappiness live on the stats object in B42, not on BD.
    local stats = self.character:getStats()
    if stats and stats.remove and CharacterStat then
        if CharacterStat.BOREDOM then stats:remove(CharacterStat.BOREDOM, 0.02) end
        if CharacterStat.UNHAPPINESS then stats:remove(CharacterStat.UNHAPPINESS, 0.02) end
    end
end

local function clearAllMuscleStrain(character)
    local bd = character:getBodyDamage()
    local fitness = character:getFitness()
    local maxIdx = BodyPartType.MAX:index()
    for i = 0, maxIdx - 1 do
        local bpType = BodyPartType.FromIndex(i)
        local part = bd:getBodyPart(bpType)
        if part and part:getStiffness() > 0 then
            part:setStiffness(0)
            if fitness then
                fitness:removeStiffnessValue(BodyPartType.ToString(bpType))
            end
        end
    end
end

function CSR_BatheAction:stop()
    self:_clearWaterOverlay()
    if self.oldX then
        self.character:setX(self.oldX); self.character:setY(self.oldY)
    end
    if self.oldPrimary and self.oldPrimary.getContainer and self.oldPrimary:getContainer() then
        self.character:setPrimaryHandItem(self.oldPrimary)
    end
    if self.oldSecondary and self.oldSecondary.getContainer and self.oldSecondary:getContainer() then
        self.character:setSecondaryHandItem(self.oldSecondary)
    end
    ISBaseTimedAction.stop(self)
end

function CSR_BatheAction:perform()
    local char = self.character
    local bd = char:getBodyDamage()
    local serverSideOnly = (isServer and isServer()) and not (isClient and isClient())

    if serverSideOnly then
        self:_clearWaterOverlay()
        if self.oldX then
            char:setX(self.oldX); char:setY(self.oldY)
        end
        if self.oldPrimary and self.oldPrimary.getContainer and self.oldPrimary:getContainer() then
            char:setPrimaryHandItem(self.oldPrimary)
        end
        if self.oldSecondary and self.oldSecondary.getContainer and self.oldSecondary:getContainer() then
            char:setSecondaryHandItem(self.oldSecondary)
        end
        char:resetModelNextFrame()
        ISBaseTimedAction.perform(self)
        return
    end

    -- Clear blood and dirt on every body part.
    cleanBodyLocal(char)

    -- Cure cold (the soak warms you up).
    if bd:getColdStrength() < 1 then bd:setHasACold(false) end

    -- In MP, the server validates the tub, drains water, and broadcasts the
    -- authoritative player visual. SP keeps the direct local path.
    if not sendBathComplete(self) and self.consumeWater > 0 and self.tub then
        if CSR_BathWater then
            CSR_BathWater.consume(self.tub, self.consumeWater, char, "bathe")
        end
    end

    -- Comfort + endurance bumps.  Boredom / unhappiness are stats in B42.
    local stats = char:getStats()
    if stats then
        if stats.remove and CharacterStat then
            if CharacterStat.BOREDOM then stats:remove(CharacterStat.BOREDOM, 0.1) end
            if CharacterStat.UNHAPPINESS then stats:remove(CharacterStat.UNHAPPINESS, 0.1) end
        end
        if stats.setEndurance and stats.getEndurance then
            stats:setEndurance(math.min(1.0, (tonumber(stats:getEndurance()) or 0) + 0.2))
        end
    end

    -- 100% muscle-strain wipe (sandbox-gated).
    if SandboxVars and SandboxVars.CommonSenseLight
        and SandboxVars.CommonSenseLight.BathingClearsMuscleStrain ~= false then
        clearAllMuscleStrain(char)
    end

    -- Clear water overlay sprites.
    self:_clearWaterOverlay()

    -- Restore position before bath.
    if self.oldX then
        char:setX(self.oldX); char:setY(self.oldY)
    end
    if self.oldPrimary and self.oldPrimary.getContainer and self.oldPrimary:getContainer() then
        char:setPrimaryHandItem(self.oldPrimary)
    end
    if self.oldSecondary and self.oldSecondary.getContainer and self.oldSecondary:getContainer() then
        char:setSecondaryHandItem(self.oldSecondary)
    end
    char:resetModelNextFrame()

    ISBaseTimedAction.perform(self)
end

function CSR_BatheAction:new(character, tub, partKey, consumeWater)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.tub = tub
    o.partKey = partKey
    o.consumeWater = consumeWater or 0
    o.maxTime = 500
    o.stopOnWalk = true
    o.stopOnRun = true
    if character:isTimedActionInstant() then o.maxTime = 1 end
    -- Opt out of third-party action-duration scalers (e.g. FasterActions) so the
    -- bath animation is always given enough time to play visually.
    o._TWF_FA_SkipScale = true
    return o
end
