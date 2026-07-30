require "TimedActions/ISBaseTimedAction"
require "CSE_Utils"
require "CSE_Config"

CSE_LockpickVehicleDoorAction = ISBaseTimedAction:derive("CSE_LockpickVehicleDoorAction")

function CSE_LockpickVehicleDoorAction:new(character, vehicle, part, tool)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.vehicle = vehicle
    o.part = part
    o.tool = tool
    o.maxTime = CSE_Utils.scaleActionTime(CSE_Config.LOCKPICK_TIME)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    return o
end

function CSE_LockpickVehicleDoorAction:isValid()
    return self.vehicle ~= nil and self.part ~= nil and self.tool ~= nil
end

function CSE_LockpickVehicleDoorAction:update()
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
    self.gruntTimer = (self.gruntTimer or 0) + 1
    if self.gruntTimer >= 120 then
        self.gruntTimer = 0
        local voiceSound = self.character:isFemale() and "VoiceFemaleCorpseLowEffort" or "VoiceMaleCorpseLowEffort"
        self.character:playSound(voiceSound)
    end
end

function CSE_LockpickVehicleDoorAction:start()
    self:setActionAnim("Craft")
    self:setOverrideHandModels(self.tool, nil)
    self.jobType = "Lockpick Vehicle"
    self.gruntTimer = 0
    self.sound = self.character:playSound("DoorIsLocked")
end

function CSE_LockpickVehicleDoorAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function CSE_LockpickVehicleDoorAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end

    if isClient() then
        sendClientCommand(self.character, CSE_Config.MODULE_NAME, "LockpickVehicleDoor", {
            vehicleId = self.vehicle:getId(),
            partId = self.part:getId(),
            screwdriverId = self.tool:getID(),
            requestId = CSE_Utils.makeRequestId(self.character, "LockpickVehicleDoor"),
        })
    else
        local _, message = CSE_Utils.resolveLockpickVehicleAttempt(self.character, self.vehicle, self.part, self.tool)
        self.character:Say(message)
    end

    ISBaseTimedAction.perform(self)
end

return CSE_LockpickVehicleDoorAction
