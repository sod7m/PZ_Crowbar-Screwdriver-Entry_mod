require "TimedActions/ISBaseTimedAction"
require "CSE_Utils"
require "CSE_Config"

CSE_LockpickOpenAction = ISBaseTimedAction:derive("CSE_LockpickOpenAction")

function CSE_LockpickOpenAction:new(character, target, tool)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.target = target
    o.tool = tool
    o.maxTime = CSE_Utils.scaleActionTime(CSE_Config.LOCKPICK_TIME)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    return o
end

function CSE_LockpickOpenAction:isValid()
    if not self.tool or self.tool:getCondition() <= 0 then
        return false
    end
    if not CSE_Utils.canLockpickWorldTarget(self.target, self.character) then
        return false
    end

    local sq = self.target and self.target.getSquare and self.target:getSquare() or nil
    if not sq then return false end
    return self.character:DistToSquared(sq:getX() + 0.5, sq:getY() + 0.5) <= 4
end

function CSE_LockpickOpenAction:update()
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
    self.gruntTimer = (self.gruntTimer or 0) + 1
    if self.gruntTimer >= 120 then
        self.gruntTimer = 0
        local voiceSound = self.character:isFemale() and "VoiceFemaleCorpseLowEffort" or "VoiceMaleCorpseLowEffort"
        self.character:playSound(voiceSound)
    end
end

function CSE_LockpickOpenAction:start()
    self:setActionAnim("Craft")
    self:setOverrideHandModels(self.tool, nil)
    self.jobType = "Lockpick"
    self.gruntTimer = 0
    self.sound = self.character:playSound("DoorIsLocked")
end

function CSE_LockpickOpenAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function CSE_LockpickOpenAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end

    if isClient() then
        local square = self.target:getSquare()
        sendClientCommand(self.character, CSE_Config.MODULE_NAME, "LockpickTarget", {
            x = square:getX(),
            y = square:getY(),
            z = square:getZ(),
            objectIndex = self.target.getObjectIndex and self.target:getObjectIndex() or -1,
            sprite = self.target.getSprite and self.target:getSprite() and self.target:getSprite():getName() or "",
            screwdriverId = self.tool:getID(),
            requestId = CSE_Utils.makeRequestId(self.character, "LockpickTarget"),
        })
    else
        local _, message = CSE_Utils.resolveLockpickAttempt(self.character, self.target, self.tool)
        self.character:Say(message)
    end

    ISBaseTimedAction.perform(self)
end

return CSE_LockpickOpenAction
