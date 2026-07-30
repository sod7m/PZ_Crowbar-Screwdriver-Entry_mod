require "TimedActions/ISBaseTimedAction"
require "CSR_Config"
require "CSR_FeatureFlags"

CSR_WashAllAction = ISBaseTimedAction:derive("CSR_WashAllAction")

local DIRTY_BANDAGE_MAP = {
    ["Base.BandageDirty"] = "Base.Bandage",
    ["Base.RippedSheetsDirty"] = "Base.RippedSheets",
    ["Base.DenimBandageDirty"] = "Base.DenimBandage",
    ["Base.LeatherBandageDirty"] = "Base.LeatherBandage",
}

local function getWaterPerItem()
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    return sb.WashAllWaterPerItem or 0.5
end

local function getSecondsPerItem()
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    return sb.WashAllSecondsPerItem or 30
end

local function getAvailableWater(sink)
    if not sink then return 0 end
    if sink.isWaterSource and sink:isWaterSource() then
        if sink.getWaterAmount then
            local amt = sink:getWaterAmount()
            if amt and amt > 0 then return amt end
        end
        return 9999
    end
    if sink.getFluidContainer then
        local fc = sink:getFluidContainer()
        if fc and fc.getAmount then
            return fc:getAmount() or 0
        end
    end
    if sink.getWaterAmount then
        return sink:getWaterAmount() or 0
    end
    return 0
end

local function consumeWater(sink, amount)
    if not sink or amount <= 0 then return end
    local fc = sink.getFluidContainer and sink:getFluidContainer() or nil
    if fc and fc.removeFluid then fc:removeFluid(amount); return end
    if fc and fc.adjustAmount then fc:adjustAmount(-amount); return end
    if sink.setWaterAmount and sink.getWaterAmount then
        sink:setWaterAmount(math.max((sink:getWaterAmount() or 0) - amount, 0))
    elseif sink.useWater then
        sink:useWater(math.ceil(amount))
    end
    if isClient() and sink.transmitModData then
        sink:transmitModData()
    end
end

local function getCoveredParts(item)
    if not item or not instanceof(item, "Clothing") then return nil end
    if not item.getBloodClothingType or not BloodClothingType or not BloodClothingType.getCoveredParts then return nil end
    local bct = item:getBloodClothingType()
    if not bct then return nil end
    return BloodClothingType.getCoveredParts(bct)
end

-- v1.8.35: vanilla stores blood/dirt on Clothing per BloodBodyPart, NOT
-- as a top-level item flag. The previous detection used hasBlood/hasDirt
-- which always return false for clothing, so Wash Everything found nothing
-- to clean and the menu silently skipped — user sees no option.
local function isItemDirty(item)
    if not item then return false end
    if item.getFullType and DIRTY_BANDAGE_MAP[item:getFullType()] then return true end
    local parts = getCoveredParts(item)
    if parts then
        for j = 0, parts:size() - 1 do
            local pt = parts:get(j)
            if (item.getBlood and item:getBlood(pt) > 0)
                or (item.getDirt and item:getDirt(pt) > 0) then
                return true
            end
        end
        if item.getDirtiness and item:getDirtiness() > 0 then return true end
        return false
    end
    if item.getBloodLevel and item:getBloodLevel() > 0 then return true end
    if item.getDirtiness and item:getDirtiness() > 0 then return true end
    return false
end

local function countDirtyRecursive(inv, visited, count)
    if not inv then return count end
    visited = visited or {}
    if visited[inv] then return count end
    visited[inv] = true
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            if isItemDirty(it) then count = count + 1 end
            if instanceof(it, "InventoryContainer") then
                local sub = it:getInventory()
                if sub then count = countDirtyRecursive(sub, visited, count) end
            end
        end
    end
    return count
end

local function isBodyDirty(character)
    if not character or not character.getBodyDamage then return false end
    local bd = character:getBodyDamage()
    if not bd then return false end
    if BloodBodyPartType and BloodBodyPartType.MAX then
        for i = 0, BloodBodyPartType.MAX:index() - 1 do
            local pt = BloodBodyPartType.FromIndex(i)
            if (character.getBloodPartLevel and character:getBloodPartLevel(pt) > 0)
                or (character.getDirtPartLevel and character:getDirtPartLevel(pt) > 0) then
                return true
            end
        end
    end
    return false
end

local function washItem(item, character, replaceQueue)
    if not item then return end
    local ft = item.getFullType and item:getFullType() or nil
    if ft and DIRTY_BANDAGE_MAP[ft] then
        replaceQueue[#replaceQueue + 1] = { item = item, replacement = DIRTY_BANDAGE_MAP[ft] }
        return
    end
    -- v1.8.35: clothing dirt/blood is per-part. Zero each covered part
    -- explicitly; setBloodLevel(0) alone leaves the per-part visual stains.
    -- These methods are stable B42 bindings — the if-existence check is
    -- already protective, so no pcall layer is needed (May 2026 sweep).
    local parts = getCoveredParts(item)
    if parts and instanceof(item, "Clothing") then
        for j = 0, parts:size() - 1 do
            local pt = parts:get(j)
            if item.setBlood then item:setBlood(pt, 0) end
            if item.setDirt  then item:setDirt(pt, 0) end
        end
        if item.setDirtiness then item:setDirtiness(0) end
        if item.setWetness   then item:setWetness(100) end
        if item.synchWithVisual then item:synchWithVisual() end
    else
        if item.setBloodLevel then item:setBloodLevel(0) end
        if item.setDirtiness  then item:setDirtiness(0) end
    end
end

local function washInventory(inv, character, state, visited)
    if not inv then return end
    visited[inv] = true
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            local water = getWaterPerItem()
            if isItemDirty(it) and state.waterRemaining >= water then
                washItem(it, character, state.replaceQueue)
                state.waterRemaining = state.waterRemaining - water
                state.washedCount = state.washedCount + 1
            end
            if instanceof(it, "InventoryContainer") then
                local sub = it:getInventory()
                if sub and not visited[sub] then washInventory(sub, character, state, visited) end
            end
        end
    end
end

local function washBody(character, state)
    if not character or not BloodBodyPartType or not BloodBodyPartType.MAX then return end
    local cleaned = false
    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        local pt = BloodBodyPartType.FromIndex(i)
        if character.getBloodPartLevel and character:getBloodPartLevel(pt) > 0 then
            if state.waterRemaining >= 0.1 then
                character:setBloodLevel(pt, 0)
                state.waterRemaining = state.waterRemaining - 0.1
                cleaned = true
            end
        end
        if character.getDirtPartLevel and character:getDirtPartLevel(pt) > 0 then
            if state.waterRemaining >= 0.1 then
                character:setDirtLevel(pt, 0)
                state.waterRemaining = state.waterRemaining - 0.1
                cleaned = true
            end
        end
    end
    state.bodyWashed = cleaned
end

local function applyBandageReplacements(character, replaceQueue)
    if #replaceQueue == 0 then return end
    local inv = character:getInventory()
    for i = 1, #replaceQueue do
        local entry = replaceQueue[i]
        local old = entry.item
        if old and old.getContainer and old:getContainer() then
            local container = old:getContainer()
            local wasFavorite = old.isFavorite and old:isFavorite() or false
            container:Remove(old)
            local newItem = inv:AddItem(entry.replacement)
            if newItem and wasFavorite and newItem.setFavorite then
                newItem:setFavorite(true)
            end
        end
    end
end

local function refreshExpiredBandages(character)
    if not character or not character.getBodyDamage then return end
    local bd = character:getBodyDamage()
    if not bd or not bd.getBodyParts then return end
    local parts = bd:getBodyParts()
    for i = 0, parts:size() - 1 do
        local p = parts:get(i)
        if p and p.bandaged and p:bandaged() and p.getBandageLife and p:getBandageLife() <= 0 then
            p:setBandageLife(15.0)
        end
    end
end

function CSR_WashAllAction:isValid()
    return self.character and not self.character:isDead() and self.sink ~= nil
end

function CSR_WashAllAction:start()
    self:setActionAnim("WashClothing")
    if self.character.getEmitter then
        local emit = self.character:getEmitter()
        if emit and emit.playSound then
            emit:playSound("WashClothing")
        end
    end
end

function CSR_WashAllAction:performLocal()
    local character = self.character
    local water = getAvailableWater(self.sink)
    local state = {
        waterRemaining = water,
        washedCount = 0,
        bodyWashed = false,
        replaceQueue = {},
    }

    if self.mode == "self" or self.mode == "all" then
        washBody(character, state)
    end
    if self.mode == "inventory" or self.mode == "all" then
        local visited = {}
        washInventory(character:getInventory(), character, state, visited)
        applyBandageReplacements(character, state.replaceQueue)
        refreshExpiredBandages(character)
    end

    local consumed = water - state.waterRemaining
    if consumed > 0 then
        consumeWater(self.sink, consumed)
    end

    if character.resetModelNextFrame then character:resetModelNextFrame() end
    if isClient() then
        if character.sendVisual then character:sendVisual() end
        if character.sendInventory then character:sendInventory() end
        if character.sendBloodBodyPartSync then character:sendBloodBodyPartSync() end
    end
end

function CSR_WashAllAction:perform()
    if isClient() then
        sendClientCommand(self.character, "CommonSenseLight", "WashAll", {
            x = self.sink:getX(), y = self.sink:getY(), z = self.sink:getZ(),
            mode = self.mode,
        })
    else
        self:performLocal()
    end
    ISBaseTimedAction.perform(self)
end

function CSR_WashAllAction:new(character, sink, mode, dirtyCount)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.sink = sink
    o.mode = mode or "all"
    o.maxTime = 50 + getSecondsPerItem() * math.max(dirtyCount or 0, 1)
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end

CSR_WashAllAction.countDirtyRecursive = countDirtyRecursive
CSR_WashAllAction.isBodyDirty = isBodyDirty
CSR_WashAllAction.getAvailableWater = getAvailableWater

return CSR_WashAllAction
