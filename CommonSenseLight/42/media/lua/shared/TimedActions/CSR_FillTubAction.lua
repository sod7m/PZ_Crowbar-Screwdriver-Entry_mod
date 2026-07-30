--[[
    CSR_FillTubAction
    -----------------
    Timed action: fills a bathtub from working plumbing. Gated on the local
    player's square having running water (or the tub itself if it advertises
    it). Brief animation + pour sound, then sets the tub's water amount to
    its max (or near-max), matching what vanilla "wash all" / "drink" do
    against sinks.

    Falls back to a cheap idle timed action if the player has no anim slot;
    we just need 60-200 ticks of in-place delay so it doesn't feel free.
]]

require "TimedActions/ISBaseTimedAction"
require "CSR_BathWater"

CSR_FillTubAction = ISBaseTimedAction:derive("CSR_FillTubAction")

local function getTubMax(tub)
    return CSR_BathWater and CSR_BathWater.getCapacity(tub) or 100
end

local function getTubAmount(tub)
    return CSR_BathWater and CSR_BathWater.getAmount(tub) or 0
end

function CSR_FillTubAction:isValid()
    if not self.tub or not self.tub:getSquare() then return false end
    local amt = getTubAmount(self.tub)
    local max = getTubMax(self.tub)
    if max > 0 and amt >= max then return false end
    return true
end

function CSR_FillTubAction:waitToStart()
    self.character:faceThisObject(self.tub)
    return self.character:shouldBeTurning()
end

function CSR_FillTubAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Mid")
    -- Pour sound: best-effort. Some installs have WaterDrip; vanilla
    -- "FillContainer" works well for sinks.
    local emitter = self.character.getEmitter and self.character:getEmitter() or nil
    if emitter and emitter.playSound then emitter:playSound("FillContainer") end
end

function CSR_FillTubAction:update()
    self.character:faceThisObject(self.tub)
end

function CSR_FillTubAction:stop()
    ISBaseTimedAction.stop(self)
end

function CSR_FillTubAction:perform()
    if self.tub then
        local max = getTubMax(self.tub)
        if CSR_BathWater and max > 0 then
            CSR_BathWater.setAmount(self.tub, max, self.character, "fill")
        end
    end
    ISBaseTimedAction.perform(self)
end

function CSR_FillTubAction:new(character, tub)
    local o = ISBaseTimedAction.new(self, character)
    o.tub = tub
    o.maxTime = 120
    o.stopOnWalk  = true
    o.stopOnRun   = true
    o.stopOnAim   = true
    -- Opt out of third-party action-duration scalers (e.g. FasterActions) so the
    -- fill pour has time to register visually + audibly.
    o._TWF_FA_SkipScale = true
    return o
end
