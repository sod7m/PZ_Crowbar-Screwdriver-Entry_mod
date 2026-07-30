require "TimedActions/ISBaseTimedAction"
require "CSR_BathClothingPlan"

CSR_BathClothingAction = ISBaseTimedAction:derive("CSR_BathClothingAction")

local function spriteNameOf(obj)
    local spr = obj and obj.getSprite and obj:getSprite() or nil
    return spr and spr.getName and spr:getName() or ""
end

local function nearBathSpot(character, action)
    if not character or not action then return false end
    local x = tonumber(action.x)
    local y = tonumber(action.y)
    local z = tonumber(action.z or 0)
    if not x or not y then return true end
    return math.abs(character:getX() - x) <= 4
        and math.abs(character:getY() - y) <= 4
        and math.abs(character:getZ() - z) <= 2
end

function CSR_BathClothingAction:isValid()
    return self.character ~= nil
        and type(self.plan) == "string"
        and self.plan ~= ""
        and nearBathSpot(self.character, self)
end

function CSR_BathClothingAction:waitToStart()
    return self.character:shouldBeTurning()
end

function CSR_BathClothingAction:start()
    self:setActionAnim("WearClothing")
    self:setAnimVariable("WearClothingLocation", "Jacket")
    if self.character.reportEvent then
        self.character:reportEvent("EventWearClothing")
    end
    if self.character.playSound then
        self.sound = self.character:playSound("RummageInInventory")
        self.soundNoTrigger = true
    end
end

function CSR_BathClothingAction:update() end

function CSR_BathClothingAction:stopSound()
    if self.sound and self.character and self.character.getEmitter
        and self.character:getEmitter():isPlaying(self.sound) then
        if self.soundNoTrigger then
            self.character:getEmitter():stopSound(self.sound)
        else
            self.character:stopOrTriggerSound(self.sound)
        end
    end
end

function CSR_BathClothingAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function CSR_BathClothingAction:perform()
    self:stopSound()
    if nearBathSpot(self.character, self) then
        if self.mode == "undress" then
            CSR_BathClothingPlan.applyUndress(self.character, self.plan)
        elseif self.mode == "redress" then
            CSR_BathClothingPlan.applyRedress(self.character, self.plan)
        end
    end
    ISBaseTimedAction.perform(self)
end

function CSR_BathClothingAction:new(character, mode, tub, plan, time)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.mode = mode
    o.plan = plan or ""
    local sq = tub and tub.getSquare and tub:getSquare() or nil
    if sq then
        o.x = sq:getX()
        o.y = sq:getY()
        o.z = sq:getZ()
    end
    o.sprite = spriteNameOf(tub)
    o.maxTime = time or 35
    o.stopOnWalk = true
    o.stopOnRun = true
    if character:isTimedActionInstant() then o.maxTime = 1 end
    o._TWF_FA_SkipScale = true
    return o
end
