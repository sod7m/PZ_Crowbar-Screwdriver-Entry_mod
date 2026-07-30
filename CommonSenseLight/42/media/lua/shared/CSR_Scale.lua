-- CSR_Scale.lua
-- Tiny resolution / font-size helper for CSR HUDs and panels.
--
-- PZ has two distinct scaling axes:
--   1. UI font size bucket (Small / Medium / Large), exposed via
--      getCore():getOptionFontSize() and getOptionFontSizeReal().
--      The font heights returned by getTextManager():getFontHeight()
--      already reflect this bucket, so reading FONT_HGT_SMALL etc.
--      after the user changes font size gives the correct value.
--   2. Screen resolution (anything from 720p to 4K). PZ does not auto-
--      scale custom Lua HUDs to resolution; mods must do it themselves.
--
-- This helper exposes a single scale factor that combines both axes
-- relative to a 1080p / Small-font baseline, plus a few common
-- derived values so callers don't repeat the same math.
--
-- Stage 1 scope: helper API + change-event hook only. Callers wire it
-- in one HUD/panel at a time over subsequent updates.
CSR_Scale = CSR_Scale or {}

-- Baseline = 1080p vertical, Small font (~14px line height)
local BASE_HEIGHT = 1080
local BASE_FONT_HGT = 14

local listeners = {}
local cached = {
    factor = 1.0,
    fontBucket = 1,
    screenH = BASE_HEIGHT,
    fontHgtSmall = BASE_FONT_HGT,
}

local function recompute()
    -- Server has no fonts/screen; recompute is purely a visual helper.
    if isServer and isServer() then return end
    local core = getCore()
    if not core then return end

    local screenH = core:getScreenHeight() or BASE_HEIGHT
    local tm = getTextManager()
    local fhSmallRaw = tm and tm:getFontHeight(UIFont.Small)
    local fhSmall = (type(fhSmallRaw) == "number" and fhSmallRaw > 0) and fhSmallRaw or BASE_FONT_HGT

    -- Resolution factor clamped so we don't shrink unreadably on small
    -- screens and don't over-inflate on ultrawide.
    local resFactor = screenH / BASE_HEIGHT
    if resFactor < 0.85 then resFactor = 0.85 end
    if resFactor > 2.0 then resFactor = 2.0 end

    -- Font factor reflects user's chosen UI font size bucket.
    local fontFactor = fhSmall / BASE_FONT_HGT
    if fontFactor < 0.9 then fontFactor = 0.9 end
    if fontFactor > 1.8 then fontFactor = 1.8 end

    -- Combined factor: weight font more (it's user intent), resolution
    -- less (most users at 4K still want compact HUDs).
    local factor = (fontFactor * 0.65) + (resFactor * 0.35)

    cached.factor = factor
    cached.fontBucket = (core.getOptionFontSize and core:getOptionFontSize()) or 1
    cached.screenH = screenH
    cached.fontHgtSmall = fhSmall
end

--- Return the combined scale factor (1.0 at 1080p / Small font).
function CSR_Scale.factor()
    return cached.factor or 1.0
end

--- Scale a baseline pixel value by the current factor and floor it.
function CSR_Scale.px(baseline)
    return math.floor((baseline or 0) * (cached.factor or 1.0) + 0.5)
end

--- Pick the closest font for a given baseline pixel height.
--- Returns one of UIFont.Small / Medium / Large / NewSmall / NewMedium / NewLarge.
function CSR_Scale.font(baselineHgt)
    baselineHgt = baselineHgt or 14
    local target = baselineHgt * (cached.factor or 1.0)
    local tm = getTextManager()
    if not tm then return UIFont.Small end
    local hSmall  = tm:getFontHeight(UIFont.Small)  or 12
    local hMedium = tm:getFontHeight(UIFont.Medium) or 16
    local hLarge  = tm:getFontHeight(UIFont.Large)  or 22
    if target <= (hSmall + hMedium) / 2 then return UIFont.Small end
    if target <= (hMedium + hLarge) / 2 then return UIFont.Medium end
    return UIFont.Large
end

--- Standard padding (~4px baseline).
function CSR_Scale.pad()
    return CSR_Scale.px(4)
end

--- Standard line height for one row of small text.
function CSR_Scale.lineH()
    local tm = getTextManager()
    if not tm then return CSR_Scale.px(14) end
    return (tm:getFontHeight(UIFont.Small) or 12) + CSR_Scale.px(2)
end

--- Icon size used for inline HUD icons (~16px baseline).
function CSR_Scale.iconSize()
    return CSR_Scale.px(16)
end

--- Register a callback that fires when scale changes.
--- Callback signature: function(factor, fontBucket, screenH)
function CSR_Scale.onChange(callback)
    if type(callback) ~= "function" then return end
    table.insert(listeners, callback)
end

--- Force a recompute and notify listeners (for option-change hooks).
function CSR_Scale.refresh()
    local prev = cached.factor
    recompute()
    if math.abs((cached.factor or 1.0) - (prev or 1.0)) > 0.001 then
        for i = 1, #listeners do
            local ok, err = pcall(listeners[i],
                cached.factor, cached.fontBucket, cached.screenH)
            if not ok then
                print("[CSR_Scale] listener error: " .. tostring(err))
            end
        end
    end
end

if Events then
    if Events.OnGameStart then
        Events.OnGameStart.Add(function() CSR_Scale.refresh() end)
    end
    if Events.OnMainMenuEnter then
        Events.OnMainMenuEnter.Add(function() CSR_Scale.refresh() end)
    end
    if Events.OnResolutionChange then
        Events.OnResolutionChange.Add(function() CSR_Scale.refresh() end)
    end
    -- PZ doesn't fire a font-size-changed event reliably; HUDs poll
    -- via :prerender() if they need to react mid-session. The factor
    -- read is cheap (table lookup), so polling is fine.
end

-- Initial computation in case we're loaded mid-session (hot reload).
pcall(recompute)

return CSR_Scale
