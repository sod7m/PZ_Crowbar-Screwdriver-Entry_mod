--[[
    CSR_JarCap — right-click an empty / water-filled jar to seal it with a
    Jar Lid. The lid is consumed and returned on uncap.

    Scope V1 (per spec): jars only, lid stored as flat modData on the
    InventoryItem. No nested-container takeover, no generic "stuff inside"
    storage. Sealed jars are flagged via modData.csrJarSealed and rename
    to "Sealed <name>". The vanilla canning recipes still work because the
    sealed state only applies to plain Base.EmptyJar items the player
    chooses to cap.
]]--

require "CSR_FeatureFlags"
require "TimedActions/CSR_JarCapAction"

CSR_JarCap = CSR_JarCap or {}

local SUPPORTED_TYPES = {
    ["Base.EmptyJar"] = true,
    ["Base.WaterJar"] = true,
    ["Base.WaterJarBleach"] = true,
    ["Base.WaterJarTaintedWater"] = true,
}

local function isFeatureOn()
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    return sb.EnableJarCapping ~= false
end

local function isCappableJar(item)
    if not item or not item.getFullType then return false end
    local ft = item:getFullType()
    if SUPPORTED_TYPES[ft] then return true end
    -- Allow any FluidContainer item whose script category is "WaterContainer"
    -- and whose display matches the jar mesh, but whitelist is the safer path
    -- for V1 to avoid clashing with custom items from other mods.
    return false
end

local function gatherItems(items)
    local out = {}
    for i = 1, #items do
        local entry = items[i]
        local list = entry.items or { entry }
        for j = 1, #list do
            local it = list[j]
            if instanceof(it, "InventoryItem") and isCappableJar(it) then
                out[#out + 1] = it
            end
        end
    end
    return out
end

function CSR_JarCap.onCap(items, player, item)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not item then return end
    ISTimedActionQueue.add(CSR_JarCapAction:new(playerObj, item, true))
end

function CSR_JarCap.onUncap(items, player, item)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not item then return end
    ISTimedActionQueue.add(CSR_JarCapAction:new(playerObj, item, false))
end

function CSR_JarCap.addInventoryOptions(player, context, items)
    if not isFeatureOn() then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end
    local jars = gatherItems(items)
    if #jars == 0 then return end
    -- Use the first selected jar as the action target. Sealed and unsealed
    -- jars get separate options so the player sees the right outcome.
    for i = 1, #jars do
        local jar = jars[i]
        local md = jar:getModData()
        if md and md.csrJarSealed then
            local opt = context:addOption(getText("ContextMenu_CSR_UncapJar"), items, CSR_JarCap.onUncap, player, jar)
            local tip = ISToolTip:new(); tip:initialise()
            tip.description = getText("Tooltip_CSR_UncapJar")
            opt.toolTip = tip
            return
        end
    end

    for i = 1, #jars do
        local jar = jars[i]
        local md = jar:getModData()
        if not (md and md.csrJarSealed) then
            local hasLid = playerObj:getInventory():FindAndReturn("Base.JarLid") ~= nil
            local opt = context:addOption(getText("ContextMenu_CSR_CoverJar"), items, CSR_JarCap.onCap, player, jar)
            local tip = ISToolTip:new(); tip:initialise()
            if not hasLid then
                opt.notAvailable = true
                tip.description = getText("Tooltip_CSR_CoverJarNoLid")
            else
                tip.description = getText("Tooltip_CSR_CoverJar")
            end
            opt.toolTip = tip
            return
        end
    end
end

if Events and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(CSR_JarCap.addInventoryOptions)
end

return CSR_JarCap
