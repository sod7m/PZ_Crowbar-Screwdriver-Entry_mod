require "CSR_FeatureFlags"
require "ISUI/ISRadialMenu"

CSR_RadialMenu = CSR_RadialMenu or {}
CSR_RadialMenu.entries = CSR_RadialMenu.entries or {}

local DEFAULT_KEY = Keyboard and Keyboard.KEY_V or 47
local radialKeyBind = nil

if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create then
    local opts = PZAPI.ModOptions:create("CommonSenseLightRadial",
        "Common Sense Reborn - CSR Radial")
    if opts and opts.addKeyBind then
        radialKeyBind = opts:addKeyBind("csrRadialToggle", "Open CSR Radial", DEFAULT_KEY)
    end
end

local function getBoundKey()
    if radialKeyBind and radialKeyBind.getValue then
        return radialKeyBind:getValue()
    end
    return DEFAULT_KEY
end

local function tr(key, fallback)
    local s = getText and getText(key) or nil
    if not s or s == "" or s == key then return fallback end
    return s
end

local function texture(path)
    if not path or not getTexture then return nil end
    return getTexture(path)
end

local function showHalo(playerObj, text)
    if playerObj and playerObj.setHaloNote then
        playerObj:setHaloNote(text, 190, 150, 255, 250)
    end
end

local function hasVehicleFocus(playerObj)
    if not playerObj then return false end
    if playerObj.getVehicle and playerObj:getVehicle() then return true end
    if ISVehicleMenu and ISVehicleMenu.getVehicleToInteractWith then
        return ISVehicleMenu.getVehicleToInteractWith(playerObj) ~= nil
    end
    return false
end

local function addRuntimeEntry(list, id, labelKey, fallback, texPath, available, action, order)
    if not available or not action then return end
    list[#list + 1] = {
        id = id,
        order = order or 100,
        label = tr(labelKey, fallback),
        icon = texture(texPath),
        action = action,
    }
end

local function addBuiltIns(list, playerObj)
    addRuntimeEntry(list, "drink", "IGUI_CSR_Radial_Drink", "Drink",
        "media/ui/Entity/fluid_drop_icon.png",
        CSR_FeatureFlags.isHydrationSenseEnabled(),
        function()
            if CSR_HydrationSense and CSR_HydrationSense.drinkNow then
                CSR_HydrationSense.drinkNow(playerObj, false)
            end
        end,
        10)

    if CSR_FeatureFlags.isHydrationSenseEnabled()
            and CSR_HydrationSense
            and CSR_HydrationSense.togglePlayerEnabled then
        local hydrationOn = CSR_HydrationSense.isPlayerEnabled
            and CSR_HydrationSense.isPlayerEnabled(playerObj)
        list[#list + 1] = {
            id = "hydrationToggle",
            order = 12,
            label = hydrationOn
                and tr("IGUI_CSR_HydrationSense_ToggleOn", "Hydration: On")
                or tr("IGUI_CSR_HydrationSense_ToggleOff", "Hydration: Off"),
            icon = texture("media/ui/Entity/fluid_drop_icon.png"),
            action = function()
                CSR_HydrationSense.togglePlayerEnabled(playerObj)
            end,
        }
    end

    addRuntimeEntry(list, "claims", "IGUI_CSR_Radial_Claims", "Claims",
        "media/ui/CSR_ClaimVehicle.png",
        CSR_ClaimsManagerPanel and CSR_ClaimsManagerPanel.open,
        function()
            CSR_ClaimsManagerPanel.open(playerObj)
        end,
        20)

    addRuntimeEntry(list, "rankings", "IGUI_CSR_Radial_Rankings", "Server Rankings",
        "media/ui/CSR_Rankings/csr_server_rankings_icon_32.png",
        CSR_FeatureFlags.isRankingsEnabled()
            and CSR_RankingsUI and CSR_RankingsUI.toggle,
        function()
            CSR_RankingsUI.toggle()
        end,
        30)

    addRuntimeEntry(list, "journal", "IGUI_CSR_Radial_Journal", "Journal",
        "media/ui/CSR_Journal.png",
        CSR_FeatureFlags.isSkillJournalEnabled()
            and CSR_SkillJournalPanel and CSR_SkillJournalPanel.toggle,
        function()
            CSR_SkillJournalPanel.toggle()
        end,
        40)
end

function CSR_RadialMenu.addEntry(id, entry)
    if not id or not entry then return end
    entry.id = id
    CSR_RadialMenu.entries[id] = entry
end

local function collectEntries(playerObj)
    local list = {}
    addBuiltIns(list, playerObj)

    for id, entry in pairs(CSR_RadialMenu.entries) do
        local available = true
        if entry.isAvailable then
            available = entry.isAvailable(playerObj) == true
        end
        if available and entry.onSelect then
            list[#list + 1] = {
                id = id,
                order = entry.order or 100,
                label = tr(entry.labelKey, entry.label or id),
                icon = texture(entry.texture),
                action = entry.onSelect,
            }
        end
    end

    table.sort(list, function(a, b)
        if a.order == b.order then return tostring(a.id) < tostring(b.id) end
        return a.order < b.order
    end)
    return list
end

function CSR_RadialMenu.open(playerNum)
    if not CSR_FeatureFlags.isCSRRadialMenuEnabled() then return false end

    playerNum = playerNum or 0
    local playerObj = getSpecificPlayer and getSpecificPlayer(playerNum) or getPlayer()
    if not playerObj or playerObj:isDead() then return false end
    if hasVehicleFocus(playerObj) then return false end

    local menu = getPlayerRadialMenu(playerNum)
    if not menu then return false end

    if menu:isReallyVisible() then
        if menu.joyfocus then setJoypadFocus(playerNum, nil) end
        menu:undisplay()
        return true
    end

    menu:clear()
    local entries = collectEntries(playerObj)
    for i = 1, #entries do
        local entry = entries[i]
        menu:addSlice(entry.label, entry.icon, entry.action, playerObj)
    end

    if menu:isEmpty() then
        showHalo(playerObj, tr("IGUI_CSR_Radial_NoActions", "No CSR radial actions available."))
        return false
    end

    menu:setX(getPlayerScreenLeft(playerNum) + getPlayerScreenWidth(playerNum) / 2 - menu:getWidth() / 2)
    menu:setY(getPlayerScreenTop(playerNum) + getPlayerScreenHeight(playerNum) / 2 - menu:getHeight() / 2)
    menu:addToUIManager()

    if getSoundManager then
        getSoundManager():playUISound("UIVehicleMenuOpen")
        menu.sounds.undisplay = "UIVehicleMenuClose"
    end

    if JoypadState.players[playerNum + 1] then
        setJoypadFocus(playerNum, menu)
    end
    return true
end

local function onKeyPressed(key)
    if key ~= getBoundKey() then return end
    CSR_RadialMenu.open(0)
end

if Events and Events.OnKeyPressed and not CSR_RadialMenu._registered then
    CSR_RadialMenu._registered = true
    Events.OnKeyPressed.Add(onKeyPressed)
end

return CSR_RadialMenu
