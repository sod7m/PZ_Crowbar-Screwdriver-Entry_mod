--[[
    CSR_DryOffAction
    -----------------
    Towel-dry timed action. Uses any vanilla BathTowel from the player's
    inventory. After drying, queues re-equipping any clothing the bath
    routine took off.
]]

require "TimedActions/ISBaseTimedAction"

CSR_DryOffAction = ISBaseTimedAction:derive("CSR_DryOffAction")

local function getTowelAmount(item)
    if not item then return 0 end
    if item.getCurrentUsesFloat then
        local amount = item:getCurrentUsesFloat()
        if amount and amount > 0 then return amount end
    end
    if item.getUsedDelta then
        local amount = item:getUsedDelta()
        if amount and amount > 0 then return amount end
    end
    if item.getDelta then
        local amount = item:getDelta()
        if amount and amount > 0 then return amount end
    end
    return 0
end

local function consumeTowel(item, amount)
    if not item then return end
    amount = amount or getTowelAmount(item)
    if item.setUsedDelta then
        item:setUsedDelta(math.max(0, amount - 0.5))
    elseif item.UseAndSync then
        item:UseAndSync()
    elseif item.Use then
        item:Use()
    end
end

local function hasClothesToReEquip(value)
    if type(value) == "string" then
        return value ~= ""
    end
    return value and #value > 0
end

function CSR_DryOffAction:isValid()
    return self.character:getInventory():contains(self.item)
        and getTowelAmount(self.item) > 0
        and (self.forceRun == true
            or hasClothesToReEquip(self.clothesToReEquip)
            or self.character:getBodyDamage():getWetness() > 0)
end

function CSR_DryOffAction:waitToStart()
    return self.character:shouldBeTurning()
end

function CSR_DryOffAction:start()
    self:setActionAnim("CSR_DrySelf")
end

function CSR_DryOffAction:update() end

function CSR_DryOffAction:stop()
    ISBaseTimedAction.stop(self)
end

function CSR_DryOffAction:perform()
    local bd = self.character:getBodyDamage()
    local amount = getTowelAmount(self.item)
    local wetness = bd.getWetness and bd:getWetness() or 0
    if wetness > 0 or self.forceRun == true then
        bd:decreaseBodyWetness(amount * 100)
        -- Wear the towel down.
        consumeTowel(self.item, amount)
    end

    if type(self.clothesToReEquip) ~= "string"
        and self.clothesToReEquip and #self.clothesToReEquip > 0 then
        for i = 1, #self.clothesToReEquip do
            local cloth = self.clothesToReEquip[i]
            if cloth then
                ISTimedActionQueue.add(ISWearClothing:new(self.character, cloth, 50))
            end
        end
        self.clothesToReEquip = nil
    end

    ISBaseTimedAction.perform(self)
end

function CSR_DryOffAction:new(character, item, time, clothesToReEquip, forceRun)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.item = item
    o.clothesToReEquip = clothesToReEquip or {}
    o.forceRun = forceRun == true
    o.maxTime = time or 180
    o.stopOnWalk = true
    o.stopOnRun = true
    if character:isTimedActionInstant() then o.maxTime = 1 end
    -- Opt out of third-party action-duration scalers (e.g. FasterActions) so the
    -- dry animation has time to play visually.
    o._TWF_FA_SkipScale = true
    return o
end
