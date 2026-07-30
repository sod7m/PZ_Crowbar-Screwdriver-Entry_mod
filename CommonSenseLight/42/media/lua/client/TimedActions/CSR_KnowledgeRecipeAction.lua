require "TimedActions/ISBaseTimedAction"
require "CSR_Config"
require "CSR_FeatureFlags"
require "CSR_Utils"

CSR_KnowledgeRecipeAction = ISBaseTimedAction:derive("CSR_KnowledgeRecipeAction")

function CSR_KnowledgeRecipeAction:new(character, targetID, recipeKey, sessionId)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.targetID = targetID
    o.recipeKey = recipeKey
    o.sessionId = sessionId
    o.maxTime = (SandboxVars and SandboxVars.CommonSenseLight and SandboxVars.CommonSenseLight.KnowledgeRecipeLessonTime) or CSR_Config.KNOWLEDGE_RECIPE_TIME
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end

function CSR_KnowledgeRecipeAction:isValid()
    if not CSR_FeatureFlags.isKnowledgeSharingEnabled()
            or not self.targetID or not self.recipeKey or not self.sessionId then
        return false
    end
    if not self.character then return false end

    local target = getPlayerByOnlineID and getPlayerByOnlineID(self.targetID) or nil
    if not target or target:isDead() or target:getZ() ~= self.character:getZ() then
        return false
    end

    local distance = IsoUtils.DistanceTo(self.character:getX(), self.character:getY(), target:getX(), target:getY())
    return distance <= (CSR_Config.KNOWLEDGE_RANGE or 6)
end

function CSR_KnowledgeRecipeAction:update()
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function CSR_KnowledgeRecipeAction:start()
    self:setActionAnim("Read")
    self.character:Say("Walk with me through this.")
end

function CSR_KnowledgeRecipeAction:perform()
    if isClient() then
        sendClientCommand(self.character, "CommonSenseLight", "KnowledgeRecipeComplete", {
            targetID = self.targetID,
            recipeKey = self.recipeKey,
            sessionId = self.sessionId,
            requestId = CSR_Utils.makeRequestId(self.character, "KnowledgeRecipeComplete"),
            requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
        })
    end

    ISBaseTimedAction.perform(self)
end

function CSR_KnowledgeRecipeAction:stop()
    if isClient() and self.sessionId then
        sendClientCommand(self.character, "CommonSenseLight", "KnowledgeRecipeCancel", {
            sessionId = self.sessionId,
            targetID = self.targetID,
            recipeKey = self.recipeKey,
            requestId = CSR_Utils.makeRequestId(self.character, "KnowledgeRecipeCancel"),
            requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
        })
    end

    ISBaseTimedAction.stop(self)
end

return CSR_KnowledgeRecipeAction
