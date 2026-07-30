require "TimedActions/ISBaseTimedAction"
require "CSE_Utils"
require "CSE_Config"

CSE_PryVehicleDoorAction = ISBaseTimedAction:derive("CSE_PryVehicleDoorAction")

function CSE_PryVehicleDoorAction:new(character, vehicle, part, tool)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.vehicle = vehicle
    o.part = part
    o.tool = tool
    o.maxTime = CSE_Utils.scaleActionTime(CSE_Config.PRY_TIME)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    return o
end

function CSE_PryVehicleDoorAction:isValid()
    -- Only check that the vehicle/part/tool still exist; the door's lock
    -- state itself changes inside perform(), so re-checking isLocked here
    -- would make the action invalidate itself mid-swing.
    return self.vehicle ~= nil and self.part ~= nil and self.tool ~= nil
end

function CSE_PryVehicleDoorAction:update()
    self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
    self.gruntTimer = (self.gruntTimer or 0) + 1
    if self.gruntTimer >= 90 then
        self.gruntTimer = 0
        local voiceSound = self.character:isFemale() and "VoiceFemaleExercise" or "VoiceMaleExercise"
        self.character:playSound(voiceSound)
    end
end

function CSE_PryVehicleDoorAction:start()
    self:setActionAnim("RemoveBarricade")
    self:setAnimVariable("RemoveBarricade", "CrowbarMid")
    self:setOverrideHandModels(self.tool, nil)
    self.jobType = "Pry Vehicle Door"
    self.gruntTimer = 0
    self.sound = self.character:playSound("BeginRemoveBarricadePlankCrowbar")
end

function CSE_PryVehicleDoorAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function CSE_PryVehicleDoorAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end

    if isClient() then
        sendClientCommand(self.character, CSE_Config.MODULE_NAME, "PryVehicleDoor", {
            vehicleId = self.vehicle:getId(),
            partId = self.part:getId(),
            crowbarId = self.tool:getID(),
            requestId = CSE_Utils.makeRequestId(self.character, "PryVehicleDoor"),
        })
    else
        local _, message = CSE_Utils.resolvePryVehicleAttempt(self.character, self.vehicle, self.part, self.tool)
        self.character:Say(message)
    end

    ISBaseTimedAction.perform(self)
end

return CSE_PryVehicleDoorAction
