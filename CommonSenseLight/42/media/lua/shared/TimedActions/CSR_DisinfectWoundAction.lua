require "TimedActions/ISBaseTimedAction"
require "CSR_DisinfectantUtils"

CSR_DisinfectWoundAction = ISBaseTimedAction:derive("CSR_DisinfectWoundAction")

function CSR_DisinfectWoundAction:isValid()
    if ISHealthPanel
        and ISHealthPanel.DidPatientMove
        and ISHealthPanel.DidPatientMove(self.character, self.otherPlayer, self.bandagedPlayerX, self.bandagedPlayerY)
    then
        return false
    end

    if isClient() and self.alcohol then
        self.alcohol = self.character:getInventory():getItemById(self.alcoholId or self.alcohol:getID())
        return self.alcohol ~= nil and CSR_DisinfectantUtils.isDisinfectant(self.alcohol)
    end

    return self.alcohol ~= nil
        and self.character:getInventory():contains(self.alcohol)
        and CSR_DisinfectantUtils.isDisinfectant(self.alcohol)
end

function CSR_DisinfectWoundAction:waitToStart()
    if self.character == self.otherPlayer then
        return false
    end
    self.character:faceThisObject(self.otherPlayer)
    return self.character:shouldBeTurning()
end

function CSR_DisinfectWoundAction:update()
    if self.character ~= self.otherPlayer then
        self.character:faceThisObject(self.otherPlayer)
    end
    if ISHealthPanel and ISHealthPanel.setBodyPartActionForPlayer then
        ISHealthPanel.setBodyPartActionForPlayer(
            self.otherPlayer,
            self.bodyPart,
            self,
            getText("ContextMenu_Disinfect"),
            { disinfect = true }
        )
    end
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function CSR_DisinfectWoundAction:start()
    if isClient() and self.alcoholId then
        self.alcohol = self.character:getInventory():getItemById(self.alcoholId)
    end

    if self.character == self.otherPlayer then
        self:setActionAnim(CharacterActionAnims.Bandage)
        if ISHealthPanel and ISHealthPanel.getBandageType then
            self:setAnimVariable("BandageType", ISHealthPanel.getBandageType(self.bodyPart))
        end
        self.character:reportEvent("EventBandage")
    else
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Mid")
        self.character:reportEvent("EventLootItem")
    end

    self:setOverrideHandModels(nil, nil)
    if self.alcohol ~= nil and self.alcohol:getFullType() == "Base.AlcoholWipes" then
        self.sound = self.character:playSound("FirstAidApplyAlcoholWipes")
    else
        self.sound = self.character:playSound("FirstAidApplyAlcohol")
    end
end

function CSR_DisinfectWoundAction:stop()
    self:stopSound()
    if ISHealthPanel and ISHealthPanel.setBodyPartActionForPlayer then
        ISHealthPanel.setBodyPartActionForPlayer(self.otherPlayer, self.bodyPart, nil, nil, nil)
    end
    ISBaseTimedAction.stop(self)
end

function CSR_DisinfectWoundAction:perform()
    self:stopSound()
    if ISHealthPanel and ISHealthPanel.setBodyPartActionForPlayer then
        ISHealthPanel.setBodyPartActionForPlayer(self.otherPlayer, self.bodyPart, nil, nil, nil)
    end
    ISBaseTimedAction.perform(self)
end

function CSR_DisinfectWoundAction:complete()
    if not self.alcohol or not self.bodyPart then return false end
    if not CSR_DisinfectantUtils.isDisinfectant(self.alcohol) then return false end

    local alcoholPower = CSR_DisinfectantUtils.getAlcoholPower(self.alcohol)
    if alcoholPower <= 0 then return false end

    if not CSR_DisinfectantUtils.drainDisinfectant(
        self.alcohol,
        CSR_DisinfectantUtils.WOUND_DRAIN_AMOUNT
    ) then
        return false
    end

    local addPain = (alcoholPower * 13) - (self.doctorLevel / 2)
    self.bodyPart:setAlcoholLevel(self.bodyPart:getAlcoholLevel() + alcoholPower)
    if not (isMultiplayer() and self.doctor and self.doctor.isHealthCheat and self.doctor:isHealthCheat()) then
        self.bodyPart:setAdditionalPain(self.bodyPart:getAdditionalPain() + addPain)
    end

    if syncBodyPart then
        -- BD_alcoholLevel + BD_additionalPain + BD_IsInfected + BD_WoundInfectionLevel
        syncBodyPart(self.bodyPart, 0x00608200)
    end

    return true
end

function CSR_DisinfectWoundAction:getDuration()
    if self.character:isTimedActionInstant() then
        return 1
    end
    return 120 - (self.doctorLevel * 4)
end

function CSR_DisinfectWoundAction:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end
end

function CSR_DisinfectWoundAction:new(character, otherPlayer, alcohol, bodyPart)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.doctor = character
    o.otherPlayer = otherPlayer
    o.doctorLevel = character:getPerkLevel(Perks.Doctor)
    o.alcohol = alcohol
    o.alcoholId = alcohol and alcohol.getID and alcohol:getID() or nil
    o.bodyPart = bodyPart
    o.stopOnWalk = bodyPart:getIndex() > BodyPartType.ToIndex(BodyPartType.Groin)
    o.stopOnRun = true
    o.bandagedPlayerX = otherPlayer:getX()
    o.bandagedPlayerY = otherPlayer:getY()
    o.maxTime = o:getDuration()
    return o
end

return CSR_DisinfectWoundAction
