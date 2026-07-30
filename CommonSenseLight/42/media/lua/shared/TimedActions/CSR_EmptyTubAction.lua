-- Simple timed action to drain CSR's bathtub water state.

require "TimedActions/ISBaseTimedAction"
require "CSR_BathWater"

CSR_EmptyTubAction = ISBaseTimedAction:derive("CSR_EmptyTubAction")

function CSR_EmptyTubAction:isValid()
    if not self.tub or not self.tub:getSquare() then return false end
    return CSR_BathWater and CSR_BathWater.getAmount(self.tub) > 0
end

function CSR_EmptyTubAction:waitToStart()
    self.character:faceThisObject(self.tub)
    return self.character:shouldBeTurning()
end

function CSR_EmptyTubAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Mid")
    local emitter = self.character.getEmitter and self.character:getEmitter() or nil
    if emitter and emitter.playSound then emitter:playSound("FillContainer") end
end

function CSR_EmptyTubAction:update()
    self.character:faceThisObject(self.tub)
end

function CSR_EmptyTubAction:stop()
    ISBaseTimedAction.stop(self)
end

function CSR_EmptyTubAction:perform()
    if self.tub and CSR_BathWater then
        CSR_BathWater.setAmount(self.tub, 0, self.character, "empty")
    end
    ISBaseTimedAction.perform(self)
end

function CSR_EmptyTubAction:new(character, tub)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.tub = tub
    o.maxTime = 90
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    if character:isTimedActionInstant() then o.maxTime = 1 end
    -- Opt out of third-party action-duration scalers (e.g. FasterActions).
    o._TWF_FA_SkipScale = true
    return o
end

return CSR_EmptyTubAction
