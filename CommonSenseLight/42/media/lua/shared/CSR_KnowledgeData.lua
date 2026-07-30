CSR_KnowledgeData = CSR_KnowledgeData or {}

CSR_KnowledgeData.RECIPES = {
    {
        key = "generator",
        displayName = "Generator Use",
        recipe = "Generator",
        perkName = "Electricity",
        minTeacherLevel = 3,
        requirementText = "Must know the Generator recipe.",
    },
    {
        key = "basic_mechanics",
        displayName = "Basic Mechanics",
        recipe = "Basic Mechanics",
        perkName = "Mechanics",
        minTeacherLevel = 2,
        requirementText = "Must know the Basic Mechanics recipe.",
    },
    {
        key = "intermediate_mechanics",
        displayName = "Intermediate Mechanics",
        recipe = "Intermediate Mechanics",
        perkName = "Mechanics",
        minTeacherLevel = 4,
        requirementText = "Must know the Intermediate Mechanics recipe.",
    },
    {
        key = "advanced_mechanics",
        displayName = "Advanced Mechanics",
        recipe = "Advanced Mechanics",
        perkName = "Mechanics",
        minTeacherLevel = 6,
        requirementText = "Must know the Advanced Mechanics recipe.",
    },
}

CSR_KnowledgeData.LECTURES = {
    {
        key = "mechanics",
        displayName = "Mechanics",
        perkName = "Mechanics",
        minTeacherLevel = 5,
        requireAnyItems = { "Base.Screwdriver", "Base.Screwdriver_Old", "Base.Screwdriver_Improvised" },
        requirementText = "Need Mechanics 5 and a screwdriver.",
        lines = {
            "Listen to the sound of the engine before you touch anything.",
            "Start with the obvious failures before tearing half the car apart.",
            "A loose part tells you more than a broken guess.",
        },
    },
    {
        key = "doctor",
        displayName = "First Aid",
        perkName = "Doctor",
        minTeacherLevel = 5,
        requireAnyItems = { "Base.Bandage", "Base.Disinfectant", "Base.AlcoholWipes" },
        requirementText = "Need First Aid 5 and basic medical supplies.",
        lines = {
            "Clean first, wrap second, panic never.",
            "A good bandage buys time, not miracles.",
            "If you can explain the wound, you can treat it better.",
        },
    },
    {
        key = "electricity",
        displayName = "Electricity",
        perkName = "Electricity",
        minTeacherLevel = 5,
        requireAnyItems = { "Base.Screwdriver", "Base.Screwdriver_Old", "Base.Screwdriver_Improvised" },
        requirementText = "Need Electricity 5 and a screwdriver.",
        lines = {
            "Kill the power in your head before you touch the wires in your hands.",
            "Color means less than where the current actually wants to go.",
            "If it sparks once, remember why before you touch it again.",
        },
    },
    {
        key = "tailoring",
        displayName = "Tailoring",
        perkName = "Tailoring",
        minTeacherLevel = 5,
        requireAllItems = { "Base.Needle" },
        requireAnyItems = { "Base.Thread", "Base.Thread_Aramid", "Base.Thread_Sinew" },
        requirementText = "Need Tailoring 5, a needle, and thread.",
        lines = {
            "Small stitches hold longer than rushed ones.",
            "Patch the stress point, not just the tear you noticed first.",
            "Good thread is quieter than good armor, but just as useful.",
        },
    },
}

local function findByKey(list, key)
    if not key then
        return nil
    end

    for _, entry in ipairs(list) do
        if entry.key == key then
            return entry
        end
    end
    return nil
end

local function hasItemOfType(player, fullType)
    local inventory = player and player.getInventory and player:getInventory() or nil
    return inventory and inventory:FindAndReturn(fullType) ~= nil
end

local function getTeacherLevelRequirement(baseRequirement)
    local sandboxMin = SandboxVars and SandboxVars.CommonSenseLight and SandboxVars.CommonSenseLight.KnowledgeMinTeacherLevel or nil
    if sandboxMin then
        return math.max(baseRequirement or 0, sandboxMin)
    end
    return baseRequirement or 0
end

local function hasAnyRequiredItem(player, itemTypes)
    if not itemTypes or #itemTypes == 0 then
        return true
    end

    for _, fullType in ipairs(itemTypes) do
        if hasItemOfType(player, fullType) then
            return true
        end
    end

    return false
end

local function hasAllRequiredItems(player, itemTypes)
    if not itemTypes or #itemTypes == 0 then
        return true
    end

    for _, fullType in ipairs(itemTypes) do
        if not hasItemOfType(player, fullType) then
            return false
        end
    end

    return true
end

local function knowsRecipe(player, recipeName)
    local recipes = player and player.getKnownRecipes and player:getKnownRecipes() or nil
    return recipes and recipes.contains and recipes:contains(recipeName) or false
end

function CSR_KnowledgeData.getRecipe(key)
    return findByKey(CSR_KnowledgeData.RECIPES, key)
end

function CSR_KnowledgeData.getLecture(key)
    return findByKey(CSR_KnowledgeData.LECTURES, key)
end

function CSR_KnowledgeData.knowsRecipe(player, recipeName)
    return knowsRecipe(player, recipeName)
end

function CSR_KnowledgeData.canTeachRecipe(player, target, recipeData)
    if not player or not target or not recipeData then
        return false, "Need both players present."
    end

    if not knowsRecipe(player, recipeData.recipe) then
        return false, "Teacher does not know this recipe yet."
    end

    if knowsRecipe(target, recipeData.recipe) then
        return false, "Target already knows this recipe."
    end

    return true, nil
end

function CSR_KnowledgeData.canGiveLecture(player, lectureData)
    if not player or not lectureData then
        return false, "Lecture data missing."
    end

    local perk = lectureData.perkName and Perks.FromString(lectureData.perkName) or nil
    local minLevel = getTeacherLevelRequirement(lectureData.minTeacherLevel)
    if perk and player:getPerkLevel(perk) < minLevel then
        return false, lectureData.requirementText or "Teacher level too low."
    end

    if not hasAllRequiredItems(player, lectureData.requireAllItems) then
        return false, lectureData.requirementText or "Missing required tools."
    end

    if not hasAnyRequiredItem(player, lectureData.requireAnyItems) then
        return false, lectureData.requirementText or "Missing required tools."
    end

    return true, nil
end

return CSR_KnowledgeData
