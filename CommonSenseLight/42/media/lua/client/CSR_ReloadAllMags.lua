--[[
    CSR_ReloadAllMags.lua (client-only)

    Adds two entry points for "reload every not-full magazine of a given
    type in sequence":

    1. "Reload All Mags" slice on the vanilla hold-R firearm radial
       menu — targets the equipped weapon's magazine type.
    2. "Reload All" right-click context menu option on any magazine in
       the player's inventory — targets the clicked magazine's type.

    Both converge on a shared scheduler (CSR_ReloadAllStep) that walks
    the pending-mag list one at a time, queueing per-mag
    transferIfNeeded + transferBullets + ISLoadBulletsInMagazine.

    Gated by sandbox option `EnableReloadAllMags`.
]]

if isServer() and not isClient() then return end

require "CSR_FeatureFlags"
require "ISUI/ISFirearmRadialMenu"
require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISTimedActionQueue"

local function isModActive(id)
    local mods = getActivatedMods and getActivatedMods() or nil
    return mods and mods:contains(id) == true
end

local function isGunworksReloadActive()
    return isModActive("SWMG") or isModActive("MarzGuns")
end

local function isGunworksItemKey(value)
    if not value then return false end
    local key = string.lower(tostring(value))
    return key:find("^marzguns%.") ~= nil
        or key:find("^marzguns:") ~= nil
        or key:find("^swmg%.") ~= nil
        or key:find("^swmg:") ~= nil
end

local function isGunworksReloadItem(item)
    if not isGunworksReloadActive() or not item then return false end
    if item.getFullType and isGunworksItemKey(item:getFullType()) then return true end

    local ammoType = item.getAmmoType and item:getAmmoType() or nil
    local ammoKey = ammoType and ammoType.getItemKey and ammoType:getItemKey() or nil
    if isGunworksItemKey(ammoKey) then return true end

    local md = item.getModData and item:getModData() or nil
    return md and (md.AmmoList ~= nil or md.MagazineType ~= nil or md.MagazineTypeLastIndex ~= nil) or false
end

-- ── Predicate / collectors ──────────────────────────────────────────────────
-- Vanilla parity: ISFirearmRadialMenu.lua line 82 predicateNotFullMagazine.
local function predicateNotFullMagazine(item, magazineType)
    if isGunworksReloadItem(item) or isGunworksItemKey(magazineType) then return false end
    return (item:getType() == magazineType or item:getFullType() == magazineType)
        and item:getCurrentAmmoCount() < item:getMaxAmmo()
end

local function collectNotFullMags(playerObj, magazineType)
    local result = {}
    if not (playerObj and magazineType) then return result end
    local inventory = playerObj:getInventory()
    if not inventory then return result end

    local mags = inventory:getAllTypeEvalRecurse(magazineType, function(item)
        return predicateNotFullMagazine(item, magazineType)
    end)
    if not mags then return result end

    for i = 0, mags:size() - 1 do
        result[#result + 1] = mags:get(i)
    end

    -- Fullest-first: maximises ready firepower if the chain is interrupted.
    table.sort(result, function(a, b)
        return a:getCurrentAmmoCount() > b:getCurrentAmmoCount()
    end)
    return result
end

local function countAmmoInInventory(playerObj, ammoItemKey)
    if not (playerObj and ammoItemKey) then return 0 end
    local inventory = playerObj:getInventory()
    if not inventory then return 0 end
    return inventory:getItemCountRecurse(ammoItemKey) or 0
end

-- ── Scheduler timed action ─────────────────────────────────────────────────
CSR_ReloadAllStep = ISBaseTimedAction:derive("CSR_ReloadAllStep")

function CSR_ReloadAllStep:new(character, pendingMags, ammoItemKey)
    local o = ISBaseTimedAction.new(self, character)
    o.pendingMags = pendingMags or {}
    o.ammoItemKey = ammoItemKey
    o.maxTime = 1
    o.stopOnWalk = false
    o.stopOnRun = true
    o.stopOnAim = false
    o.useProgressBar = false
    o.caloriesModifier = 1
    return o
end

function CSR_ReloadAllStep:isValid()
    return self.character ~= nil
end

function CSR_ReloadAllStep:start() end
function CSR_ReloadAllStep:update() end

function CSR_ReloadAllStep:stop()
    ISBaseTimedAction.stop(self)
end

function CSR_ReloadAllStep:perform()
    local pending = self.pendingMags or {}
    local currentMag = table.remove(pending, 1)
    local playerObj = self.character

    if currentMag and playerObj then
        local inventory = playerObj:getInventory()
        local magStillHere = inventory and inventory:containsID(currentMag:getID())

        if magStillHere then
            local magMax = currentMag:getMaxAmmo() or 0
            local magCurrent = currentMag:getCurrentAmmoCount() or 0

            if magMax > magCurrent then
                local ammoCount = ISInventoryPaneContextMenu.transferBullets(
                    playerObj, self.ammoItemKey, magCurrent, magMax)

                if ammoCount and ammoCount > 0 then
                    ISTimedActionQueue.add(
                        ISLoadBulletsInMagazine:new(playerObj, currentMag, ammoCount))
                end
                if not ammoCount or ammoCount <= 0 then
                    pending = {}
                end
            end
        end
    end

    if #pending > 0 and playerObj then
        local inventory = playerObj:getInventory()
        local stillHasBullets = inventory and inventory:containsWithModule(self.ammoItemKey)
        if stillHasBullets then
            local nextMag = pending[1]
            ISInventoryPaneContextMenu.transferIfNeeded(playerObj, nextMag)
            ISTimedActionQueue.add(
                CSR_ReloadAllStep:new(playerObj, pending, self.ammoItemKey))
        end
    end

    ISBaseTimedAction.perform(self)
end

-- ── Chain kickoff ──────────────────────────────────────────────────────────
local function startReloadAllChain(playerObj, magazineType)
    if not (playerObj and magazineType) then return end
    if isGunworksReloadActive() and isGunworksItemKey(magazineType) then return end
    local freshMags = collectNotFullMags(playerObj, magazineType)
    if #freshMags == 0 then return end
    local ammoType = freshMags[1]:getAmmoType()
    if not ammoType then return end
    local freshAmmoKey = ammoType:getItemKey()
    if not freshAmmoKey then return end

    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, freshMags[1])
    ISTimedActionQueue.add(
        CSR_ReloadAllStep:new(playerObj, freshMags, freshAmmoKey))
end

-- ── Radial slice ───────────────────────────────────────────────────────────
local function addReloadAllSlice(frm)
    if not CSR_FeatureFlags.isReloadAllMagsEnabled() then return end
    local playerObj = frm and frm.character or nil
    local weapon = frm and frm.getWeapon and frm:getWeapon() or nil
    if not (playerObj and weapon) then return end
    if isGunworksReloadItem(weapon) then return end

    local magazineType = weapon.getMagazineType and weapon:getMagazineType() or nil
    if not magazineType then return end
    if isGunworksReloadActive() and isGunworksItemKey(magazineType) then return end

    local notFullMags = collectNotFullMags(playerObj, magazineType)
    if #notFullMags < 2 then return end

    local sampleMag = notFullMags[1]
    local ammoItemKey = sampleMag and sampleMag:getAmmoType() and sampleMag:getAmmoType():getItemKey() or nil
    if not ammoItemKey then return end
    local bulletCount = countAmmoInInventory(playerObj, ammoItemKey)
    if bulletCount <= 0 then return end

    local menu = getPlayerRadialMenu(frm.playerNum or playerObj:getPlayerNum())
    if not menu then return end

    local label = string.format("Reload All Mags\n%d mags \194\183 %d rounds", #notFullMags, bulletCount)
    -- Reuse vanilla's bullets-into-magazine icon for visual continuity.
    local icon = getTexture and getTexture("media/ui/FirearmRadial_BulletsIntoMagazine.png") or nil

    menu:addSlice(label, icon, function()
        startReloadAllChain(playerObj, magazineType)
    end)
end

local function patchFirearmRadialFill()
    if _G.__CSR_ReloadAllRadialPatched then return end
    if not (ISFirearmRadialMenu and ISFirearmRadialMenu.fillMenu) then return end

    local vanillaFillMenu = ISFirearmRadialMenu.fillMenu
    ISFirearmRadialMenu.fillMenu = function(self, ...)
        local result = vanillaFillMenu(self, ...)
        pcall(addReloadAllSlice, self)
        return result
    end
    _G.__CSR_ReloadAllRadialPatched = true
end

patchFirearmRadialFill()
if Events and Events.OnGameBoot and Events.OnGameBoot.Add then
    Events.OnGameBoot.Add(patchFirearmRadialFill)
end
if Events and Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(patchFirearmRadialFill)
end

-- ── Inventory context menu ─────────────────────────────────────────────────
local function isMagazineItem(item)
    if not (item and item.getMaxAmmo) then return false end
    if instanceof(item, "HandWeapon") then return false end
    local maxAmmo = item:getMaxAmmo()
    return maxAmmo and maxAmmo > 0
end

local function isInPlayerInv(item, playerObj)
    if not (item and item.getContainer and playerObj) then return false end
    local container = item:getContainer()
    if not container then return false end
    return container:isInCharacterInventory(playerObj)
end

local function onReloadAllContextOption(playerObj, magazineType)
    startReloadAllChain(playerObj, magazineType)
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    if not CSR_FeatureFlags.isReloadAllMagsEnabled() then return end
    if not items then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local clickedMag = nil
    for _, entry in ipairs(items) do
        local item = entry
        if type(entry) == "table" and not instanceof(entry, "InventoryItem") then
            item = entry.items and entry.items[1] or nil
        end
        if item and instanceof(item, "InventoryItem") and isMagazineItem(item) then
            clickedMag = item
            break
        end
    end
    if not clickedMag then return end
    if isGunworksReloadItem(clickedMag) then return end
    if not isInPlayerInv(clickedMag, playerObj) then return end

    local magazineType = clickedMag:getFullType()
    if not magazineType then return end

    local notFullMags = collectNotFullMags(playerObj, magazineType)
    if #notFullMags < 2 then return end

    local ammoType = notFullMags[1]:getAmmoType()
    if not ammoType then return end
    local ammoKey = ammoType:getItemKey()
    if not ammoKey then return end
    local bulletCount = countAmmoInInventory(playerObj, ammoKey)
    if bulletCount <= 0 then return end

    local label = string.format("Reload All (%d mags, %d rounds)", #notFullMags, bulletCount)
    context:addOption(label, playerObj, onReloadAllContextOption, magazineType)
end

if Events and Events.OnFillInventoryObjectContextMenu and Events.OnFillInventoryObjectContextMenu.Add then
    Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
end
