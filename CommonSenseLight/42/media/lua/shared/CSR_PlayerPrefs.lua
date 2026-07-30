-- CSR_PlayerPrefs: per-player preference overrides stored in modData.
-- Each pref can override a sandbox setting with a player-local value.
-- nil override = use sandbox default. true/false = explicit player choice.
-- Server-side: getPlayer() returns nil so _overrides stays empty and all
-- feature flag checks fall through to sandbox defaults (correct behaviour).

CSR_PlayerPrefs = {}

-- PREFS registry. Each entry:
--   key         unique string used for modData and internal lookup
--   sandboxKey  SandboxVars.CommonSenseLight field name
--   label       display name shown in the settings panel
--   effectiveFn function returning current effective value (including override)
--   adminLocked optional function returning true when admin controls this flag
CSR_PlayerPrefs.PREFS = {
    {
        key        = "EntryActions",
        sandboxKey = "EnableEntryActions",
        label      = "Entry Actions (Pry/Pick/Cut)",
        effectiveFn = function()
            return CSR_FeatureFlags and CSR_FeatureFlags.isEntryActionsEnabled() or false
        end,
    },
    {
        key        = "WalkingItemActions",
        sandboxKey = "EnableWalkingItemActions",
        label      = "Walking Item Actions",
        effectiveFn = function()
            return CSR_FeatureFlags and CSR_FeatureFlags.isWalkingActionsEnabled() or false
        end,
    },
    {
        key        = "EatAllStack",
        sandboxKey = "EnableEatAllStack",
        label      = "Eat All Stack",
        effectiveFn = function()
            return CSR_FeatureFlags and CSR_FeatureFlags.isEatAllStackEnabled() or false
        end,
    },
    {
        key        = "HideWatermark",
        sandboxKey = "EnableHideWatermark",
        label      = "Hide Watermark",
        effectiveFn = function()
            return CSR_FeatureFlags and CSR_FeatureFlags.isHideWatermarkEnabled() or false
        end,
    },
    {
        key        = "GearSling",
        sandboxKey = "EnableGearSling",
        label      = "Gear Sling (reload required)",
        effectiveFn = function()
            return CSR_FeatureFlags and CSR_FeatureFlags.isGearSlingEnabled() or false
        end,
    },
}

-- Fast lookup by key
CSR_PlayerPrefs._byKey = {}
for _, p in ipairs(CSR_PlayerPrefs.PREFS) do
    CSR_PlayerPrefs._byKey[p.key] = p
end

local MODDATA_PREFIX = "CSRPref_"

-- In-memory overrides: key -> true/false (absent = use sandbox)
CSR_PlayerPrefs._overrides = {}

local function getModData()
    local player = getPlayer and getPlayer() or nil
    return player and player:getModData() or nil
end

-- Returns the raw override for a key, or nil if not overridden.
function CSR_PlayerPrefs.getOverride(key)
    return CSR_PlayerPrefs._overrides[key]
end

-- Set an explicit override (pass nil to clear and revert to sandbox).
function CSR_PlayerPrefs.set(key, value)
    CSR_PlayerPrefs._overrides[key] = value
    local modData = getModData()
    if not modData then return end
    if value == nil then
        modData[MODDATA_PREFIX .. key] = nil
    else
        modData[MODDATA_PREFIX .. key] = value == true
    end
end

-- Toggle a pref using its current effective value as the base.
-- Returns the new effective value.
function CSR_PlayerPrefs.toggle(key)
    local pref = CSR_PlayerPrefs._byKey[key]
    if not pref then return false end
    local current = pref.effectiveFn()
    CSR_PlayerPrefs.set(key, not current)
    return not current
end

-- Clear override for a key (revert to sandbox default).
function CSR_PlayerPrefs.reset(key)
    CSR_PlayerPrefs.set(key, nil)
end

-- Load all per-player overrides from modData. Call on OnGameStart.
function CSR_PlayerPrefs.load()
    CSR_PlayerPrefs._overrides = {}
    local modData = getModData()
    if not modData then return end

    for _, pref in ipairs(CSR_PlayerPrefs.PREFS) do
        local stored = modData[MODDATA_PREFIX .. pref.key]
        if stored ~= nil then
            CSR_PlayerPrefs._overrides[pref.key] = stored == true
        end
    end

end
