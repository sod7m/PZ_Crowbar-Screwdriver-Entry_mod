require "TimedActions/ISBaseTimedAction"
require "CSE_Utils"
require "CSE_Config"

-- One action, two jobs: cutting a padlock/lock mechanism off a door or gate,
-- and cutting a hole through a wire fence panel. They share the odds, the
-- tool wear and the animation, and differ only in what a success does, so
-- isFence just switches the validity check and the resolution call.
CSE_BoltCutAction = ISBaseTimedAction:derive("CSE_BoltCutAction")

local function sandbox()
    return SandboxVars and SandboxVars.CrowbarScrewdriverEntry or {}
end

function CSE_BoltCutAction:new(character, target, tool, isFence)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.target = target
    o.tool = tool
    o.isFence = isFence == true
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    -- Fences stack their own multiplier on top of the global action timing.
    local fenceMult = o.isFence and sandbox().FenceCutTimeMultiplier or 1.0
    o.maxTime = CSE_Utils.scaleActionTime(CSE_Config.BOLT_CUT_TIME, fenceMult)

    return o
end

function CSE_BoltCutAction:isValid()
    if not self.tool or self.tool:getCondition() <= 0 then
        return false
    end

    if self.isFence then
        if not CSE_Utils.canBoltCutFence(self.target, self.character) then return false end
    else
        if not CSE_Utils.canBoltCutWorldTarget(self.target, self.character) then return false end
    end

    local sq = self.target and self.target.getSquare and self.target:getSquare() or nil
    if not sq then return false end
    return self.character:DistToSquared(sq:getX() + 0.5, sq:getY() + 0.5) <= 4
end

function CSE_BoltCutAction:waitToStart()
    self.character:faceThisObject(self.target or self.character)
    return self.character:shouldBeTurning()
end

function CSE_BoltCutAction:update()
    if self.target then
        self.character:faceThisObject(self.target)
    end
    self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
    self.gruntTimer = (self.gruntTimer or 0) + 1
    if self.gruntTimer >= 80 then
        self.gruntTimer = 0
        local voiceSound = self.character:isFemale() and "VoiceFemaleExercise" or "VoiceMaleExercise"
        self.character:playSound(voiceSound)
    end
end

function CSE_BoltCutAction:start()
    -- No dedicated bolt-cutter animation exists in B42; the two-handed
    -- blowtorch pose is the closest fit for working a tool into a lock.
    self:setActionAnim("BlowTorchMid")
    self:setOverrideHandModels(self.tool, nil)
    self.jobType = self.isFence and "Cut Wire Fence" or "Cut Lock"
    self.gruntTimer = 0
    self.sound = self.character:playSound("BeginRemoveBarricadePlankCrowbar")
end

function CSE_BoltCutAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function CSE_BoltCutAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end

    if isClient() then
        local square = self.target:getSquare()
        sendClientCommand(self.character, CSE_Config.MODULE_NAME, "BoltCutTarget", {
            x = square:getX(),
            y = square:getY(),
            z = square:getZ(),
            objectIndex = self.target.getObjectIndex and self.target:getObjectIndex() or -1,
            sprite = self.target.getSprite and self.target:getSprite() and self.target:getSprite():getName() or "",
            toolId = self.tool.getID and self.tool:getID() or nil,
            isFence = self.isFence,
            requestId = CSE_Utils.makeRequestId(self.character, "BoltCutTarget"),
        })
    else
        local resolve = self.isFence and CSE_Utils.resolveFenceCutAttempt or CSE_Utils.resolveBoltCutAttempt
        local success, message = resolve(self.character, self.target, self.tool)
        self.character:Say(message)
        if success then
            self.character:playSound("MetalGateBreak")
        end
    end

    ISBaseTimedAction.perform(self)
end

return CSE_BoltCutAction
