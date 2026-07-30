require "TimedActions/ISBaseTimedAction"
require "CSE_Utils"
require "CSE_Config"

CSE_PryOpenAction = ISBaseTimedAction:derive("CSE_PryOpenAction")

function CSE_PryOpenAction:new(character, target, tool)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.target = target
    o.tool = tool
    o.maxTime = CSE_Utils.scaleActionTime(CSE_Config.PRY_TIME)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    return o
end

function CSE_PryOpenAction:isValid()
    if not self.tool or self.tool:getCondition() <= 0 then
        return false
    end
    if not CSE_Utils.canPryWorldTarget(self.target, self.character) then
        return false
    end

    local sq = self.target and self.target.getSquare and self.target:getSquare() or nil
    if not sq then return false end
    return self.character:DistToSquared(sq:getX() + 0.5, sq:getY() + 0.5) <= 4
end

function CSE_PryOpenAction:waitToStart()
    self.character:faceThisObject(self.target or self.character)
    return self.character:shouldBeTurning()
end

function CSE_PryOpenAction:update()
    if self.target then
        self.character:faceThisObject(self.target)
    end
    self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
    self.gruntTimer = (self.gruntTimer or 0) + 1
    if self.gruntTimer >= 90 then
        self.gruntTimer = 0
        local voiceSound = self.character:isFemale() and "VoiceFemaleExercise" or "VoiceMaleExercise"
        self.character:playSound(voiceSound)
    end
end

function CSE_PryOpenAction:start()
    self:setActionAnim("RemoveBarricade")
    self:setAnimVariable("RemoveBarricade", "CrowbarMid")
    self:setOverrideHandModels(self.tool, nil)
    self.jobType = "Pry Open"
    self.gruntTimer = 0
    self.sound = self.character:playSound("BeginRemoveBarricadePlankCrowbar")
end

function CSE_PryOpenAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function CSE_PryOpenAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end

    if isClient() then
        local square = self.target:getSquare()
        sendClientCommand(self.character, CSE_Config.MODULE_NAME, "PryTarget", {
            x = square:getX(),
            y = square:getY(),
            z = square:getZ(),
            objectIndex = self.target.getObjectIndex and self.target:getObjectIndex() or -1,
            sprite = self.target.getSprite and self.target:getSprite() and self.target:getSprite():getName() or "",
            crowbarId = self.tool.getID and self.tool:getID() or nil,
            requestId = CSE_Utils.makeRequestId(self.character, "PryTarget"),
        })
    else
        local _, message = CSE_Utils.resolvePryAttempt(self.character, self.target, self.tool)
        self.character:Say(message)
    end

    ISBaseTimedAction.perform(self)
end

return CSE_PryOpenAction
