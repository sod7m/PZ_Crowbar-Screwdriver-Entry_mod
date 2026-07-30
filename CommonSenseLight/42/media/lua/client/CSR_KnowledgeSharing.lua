
require "CSR_KnowledgeData"
require "CSR_FeatureFlags"
require "CSR_Config"
require "CSR_Utils"

CSR_KnowledgeSharing = CSR_KnowledgeSharing or {}

if not CSR_KnowledgeData or not CSR_FeatureFlags or not CSR_Config or not CSR_Utils then
    return CSR_KnowledgeSharing
end

local function getNearbyPlayers(playerObj)
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    local found = {}
    if not playerObj or not players then
        return found
    end

    for i = 0, players:size() - 1 do
        local other = players:get(i)
        if other and other ~= playerObj and not other:isDead() and other:getZ() == playerObj:getZ() then
            local dist = IsoUtils.DistanceTo(playerObj:getX(), playerObj:getY(), other:getX(), other:getY())
            if dist <= CSR_Config.KNOWLEDGE_RANGE then
                found[#found + 1] = other
            end
        end
    end

    table.sort(found, function(a, b)
        return string.lower(a:getUsername()) < string.lower(b:getUsername())
    end)

    return found
end

local function createTooltip(lines)
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip.description = table.concat(lines, " <LINE>")
    return tooltip
end

local function setOptionTooltip(option, lines)
    if option and lines and #lines > 0 then
        option.toolTip = createTooltip(lines)
    end
end

local function getLectureDisplay(lectureData)
    return lectureData and lectureData.displayName or "Lecture"
end

function CSR_KnowledgeSharing.proposeRecipeLesson(worldobjects, playerObj, targetID, recipeKey)
    if not playerObj or not targetID or not recipeKey then
        return
    end

    sendClientCommand(playerObj, "CommonSenseLight", "KnowledgeRecipeInvite", {
        targetID = targetID,
        recipeKey = recipeKey,
        requestId = CSR_Utils.makeRequestId(playerObj, "KnowledgeRecipeInvite"),
        requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
    })
end

function CSR_KnowledgeSharing.startRecipeLesson(args)
    if not CSR_KnowledgeRecipeAction then
        return
    end

    local playerObj = getPlayer()
    if not playerObj or not args or not args.targetID or not args.recipeKey or not args.sessionId then
        return
    end

    ISTimedActionQueue.add(CSR_KnowledgeRecipeAction:new(playerObj, args.targetID, args.recipeKey, args.sessionId))
end

function CSR_KnowledgeSharing.showRecipeInvite(args)
    local me = getPlayer()
    if not me or not args or not args.teacherID or not args.recipeKey then
        return
    end

    local title = args.recipeName or "this lesson"
    local prompt = string.format("%s wants to teach you %s.\n\nAccept the lesson?", args.teacherName or "Someone", title)
    local modal = ISModalDialog:new(0, 0, 320, 140, prompt, true, nil, function(_, button)
        sendClientCommand(me, "CommonSenseLight", "KnowledgeRecipeRespond", {
            teacherID = args.teacherID,
            recipeKey = args.recipeKey,
            accept = button and button.internal == "YES",
            requestId = CSR_Utils.makeRequestId(me, "KnowledgeRecipeRespond"),
            requestTimestamp = getTimestampMs and getTimestampMs() or os.time() * 1000,
        })
    end)
    modal:initialise()
    modal:addToUIManager()
end

function CSR_KnowledgeSharing.addWorldOptions(playerNum, context, worldobjects, test)
    if test or not CSR_FeatureFlags.isKnowledgeSharingEnabled() then
        return
    end

    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then
        return
    end

    local nearbyPlayers = getNearbyPlayers(playerObj)
    if #nearbyPlayers == 0 then
        return
    end

    local root = context:addOption(getText("IGUI_CSR_KnowledgeRoot") or "Knowledge Sharing", worldobjects, nil)
    local rootMenu = ISContextMenu:getNew(context)
    context:addSubMenu(root, rootMenu)

    if #nearbyPlayers > 0 then
        local recipeRoot = rootMenu:addOption(getText("IGUI_CSR_TeachRecipe") or "Teach Recipe", worldobjects, nil)
        local recipeMenu = ISContextMenu:getNew(rootMenu)
        rootMenu:addSubMenu(recipeRoot, recipeMenu)

        for _, other in ipairs(nearbyPlayers) do
            local playerOption = recipeMenu:addOption(other:getUsername(), worldobjects, nil)
            local playerMenu = ISContextMenu:getNew(recipeMenu)
            recipeMenu:addSubMenu(playerOption, playerMenu)

            for _, recipeData in ipairs(CSR_KnowledgeData.RECIPES) do
                local canTeach, reason = CSR_KnowledgeData.canTeachRecipe(playerObj, other, recipeData)
                local teachLabel = (getText("IGUI_CSR_TeachPrefix") or "Teach") .. " " .. (recipeData.displayName or "")
                local option = playerMenu:addOption(teachLabel, worldobjects, CSR_KnowledgeSharing.proposeRecipeLesson, playerObj, other:getOnlineID(), recipeData.key)
                local lines = {
                    "Teach this recipe directly to a nearby survivor.",
                    recipeData.requirementText or "Must know the recipe yourself.",
                }

                if not canTeach then
                    option.notAvailable = true
                    lines[#lines + 1] = reason or "Requirements not met."
                else
                    lines[#lines + 1] = string.format("Target: %s", other:getUsername())
                end

                setOptionTooltip(option, lines)
            end
        end
    end

    if #nearbyPlayers > 0 then
        local lectureRoot = rootMenu:addOption(getText("IGUI_CSR_GiveLecture") or "Give Lecture", worldobjects, nil)
        local lectureMenu = ISContextMenu:getNew(rootMenu)
        rootMenu:addSubMenu(lectureRoot, lectureMenu)

        for _, lectureData in ipairs(CSR_KnowledgeData.LECTURES) do
            local lectureKey = lectureData.key
            local canTeach, reason = CSR_KnowledgeData.canGiveLecture(playerObj, lectureData)
            local lectureLabel = getLectureDisplay(lectureData) .. " " .. (getText("IGUI_CSR_LectureSuffix") or "Lecture")
            local option = lectureMenu:addOption(lectureLabel, worldobjects, function()
                if CSR_KnowledgeLectureAction then
                    ISTimedActionQueue.add(CSR_KnowledgeLectureAction:new(playerObj, lectureKey))
                end
            end)
            local lines = {
                "Give a short lecture that teaches nearby survivors like a live lesson.",
                lectureData.requirementText or "Need the right knowledge and tools.",
                string.format("Nearby listeners: %d", #nearbyPlayers),
            }

            if not canTeach then
                option.notAvailable = true
                lines[#lines + 1] = reason or "Requirements not met."
            else
                local perk = Perks.FromString(lectureData.perkName)
                lines[#lines + 1] = string.format("Students can learn up to level %d.", math.max(0, playerObj:getPerkLevel(perk) - 1))
                local maxStudent = (SandboxVars and SandboxVars.CommonSenseLight and SandboxVars.CommonSenseLight.KnowledgeLectureMaxStudentLevel) or 5
                lines[#lines + 1] = string.format("Lecture cutoff at level %d.", maxStudent)
            end

            setOptionTooltip(option, lines)
        end
    end
end

return CSR_KnowledgeSharing
