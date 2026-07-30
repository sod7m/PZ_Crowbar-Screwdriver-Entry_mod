require "TimedActions/ISBaseTimedAction"
require "CSR_Config"
require "CSR_FeatureFlags"
require "CSR_KnowledgeData"
require "CSR_Utils"

CSR_KnowledgeLectureAction = ISBaseTimedAction:derive("CSR_KnowledgeLectureAction")

function CSR_KnowledgeLectureAction:new(character, lectureKey)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.lectureKey = lectureKey
    o.lectureData = CSR_KnowledgeData.getLecture(lectureKey)
    o.sessionId = CSR_Utils.makeRequestId(character, "KnowledgeLecture")
    o.maxTime = (SandboxVars and SandboxVars.CommonSenseLight and SandboxVars.CommonSenseLight.KnowledgeLectureTime) or CSR_Config.KNOWLEDGE_LECTURE_TIME
    o.stopOnWalk = true
    o.stopOnRun = true
    o.pulseCounter = 0
    return o
end

function CSR_KnowledgeLectureAction:isValid()
    if not self.character or not self.lectureData then return false end
    local canTeach = CSR_FeatureFlags.isKnowledgeSharingEnabled()
        and CSR_KnowledgeData.canGiveLecture(self.character, self.lectureData)
    return canTeach == true
end

function CSR_KnowledgeLectureAction:update()
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
    self.pulseCounter = self.pulseCounter + 1

    if self.pulseCounter >= CSR_Config.KNOWLEDGE_LECTURE_PULSE_TICKS then
        self.pulseCounter = 0

        local lines = self.lectureData and self.lectureData.lines or nil
        if lines and #lines > 0 then
            self.character:Say(lines[ZombRand(#lines) + 1])
        end

        if isClient() then
            sendClientCommand(self.character, "CommonSenseLight", "KnowledgeLecturePulse", {
                lectureKey = self.lectureKey,
                sessionId = self.sessionId,
                x = self.character:getX(),
                y = self.character:getY(),
                z = self.character:getZ(),
                requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
            })
        end
    end
end

function CSR_KnowledgeLectureAction:start()
    self:setActionAnim("Read")
    if isClient() then
        sendClientCommand(self.character, "CommonSenseLight", "KnowledgeLectureStart", {
            lectureKey = self.lectureKey,
            sessionId = self.sessionId,
            requestId = CSR_Utils.makeRequestId(self.character, "KnowledgeLectureStart"),
            requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
        })
    end
end

function CSR_KnowledgeLectureAction:perform()
    if isClient() then
        sendClientCommand(self.character, "CommonSenseLight", "KnowledgeLectureStop", {
            lectureKey = self.lectureKey,
            sessionId = self.sessionId,
            requestId = CSR_Utils.makeRequestId(self.character, "KnowledgeLectureStop"),
            requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
        })
    end

    ISBaseTimedAction.perform(self)
end

function CSR_KnowledgeLectureAction:stop()
    if isClient() and self.sessionId then
        sendClientCommand(self.character, "CommonSenseLight", "KnowledgeLectureStop", {
            lectureKey = self.lectureKey,
            sessionId = self.sessionId,
            requestId = CSR_Utils.makeRequestId(self.character, "KnowledgeLectureStop"),
            requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
        })
    end

    ISBaseTimedAction.stop(self)
end

return CSR_KnowledgeLectureAction
