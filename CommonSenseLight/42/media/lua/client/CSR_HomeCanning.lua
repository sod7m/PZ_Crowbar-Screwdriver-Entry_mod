--[[
    CSR_HomeCanning — feature toggle / compat shield for CSR home canning recipes.

    Recipes are declared in CommonSenseLight/42/media/scripts/CSR_HomeCanning.txt.
    All recipe IDs are prefixed with CSR_ so that disabling the feature cannot
    leave save data referencing CSR-only items: every output type is vanilla.

    This file simply hides the recipes from the craft helper menu when:
      * EnableHomeCanning sandbox option is off, OR
      * Another canning mod (e.g. protosMakeCannedGoods) is detected, to avoid
        duplicate context-menu entries.
]]--

require "CSR_FeatureFlags"

local CSR_HomeCanning = {}

local CSR_RECIPE_NAMES = {
    "CSR_MakeCannedEvaporatedMilk",
    "CSR_MakeCannedFruit",
    "CSR_MakeCannedVeggieSoup",
    "CSR_MakeCannedWaterRation",
}

local function isFeatureOn()
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    return sb.EnableHomeCanning ~= false
end

local function isExternalCanningModLoaded()
    if not getActivatedMods then return false end
    local mods = getActivatedMods()
    if not mods then return false end
    for i = 0, mods:size() - 1 do
        local id = mods:get(i)
        if id == "protosMakeCannedGoods" then
            return true
        end
    end
    return false
end

function CSR_HomeCanning.shouldHide()
    if not isFeatureOn() then return true end
    if isExternalCanningModLoaded() then return true end
    return false
end

-- Hide our recipes from the craft helper UI when needed. The recipes are
-- still defined at script load time (we cannot unregister script entries),
-- but hiding them keeps the crafting search clean and prevents duplicate
-- entries when a third-party canning mod is active.
local function applyVisibility()
    if not getScriptManager then return end
    local sm = getScriptManager()
    if not sm or not sm.getRecipe then return end
    local hide = CSR_HomeCanning.shouldHide()
    for _, name in ipairs(CSR_RECIPE_NAMES) do
        local recipe = sm:getRecipe(name)
        if recipe and recipe.setHidden then
            pcall(function() recipe:setHidden(hide) end)
        end
    end
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(applyVisibility)
end

return CSR_HomeCanning
