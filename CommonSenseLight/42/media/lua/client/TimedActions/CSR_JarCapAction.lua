require "TimedActions/ISBaseTimedAction"
require "CSR_Config"
require "CSR_FeatureFlags"
require "CSR_Utils"

CSR_JarCapAction = ISBaseTimedAction:derive("CSR_JarCapAction")

local function findLidRecursive(character)
    local mainInv = character and character:getInventory() or nil
    if not mainInv then return nil end
    local visited = {}
    local function walk(inv)
        if not inv or visited[inv] then return nil end
        visited[inv] = true
        local items = inv:getItems()
        if not items then return nil end
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and it.getFullType and it:getFullType() == "Base.JarLid" then return it end
        end
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and instanceof(it, "InventoryContainer") and it.getInventory then
                local found = walk(it:getInventory())
                if found then return found end
            end
        end
        return nil
    end
    return walk(mainInv)
end

function CSR_JarCapAction:isValid()
    if not self.character or self.character:isDead() then return false end
    self.item = CSR_Utils.findInventoryItemById(self.character, self.itemId, self.expectedType) or self.item
    if not self.item then return false end
    local md = self.item:getModData()
    local sealed = md and md.csrJarSealed == true
    if self.cap then
        if sealed then return false end
        return findLidRecursive(self.character) ~= nil
    else
        return sealed == true
    end
end

function CSR_JarCapAction:start()
    self:setActionAnim("Loot")
    self:setOverrideHandModels(nil, self.item)
end

function CSR_JarCapAction:perform()
    if isClient() then
        sendClientCommand(self.character, "CommonSenseLight", "JarCap", {
            itemId = self.itemId,
            expectedType = self.expectedType,
            cap = self.cap and true or false,
        })
    else
        CSR_JarCapAction.applyLocal(self.character, self.item, self.cap)
    end
    ISBaseTimedAction.perform(self)
end

function CSR_JarCapAction.applyLocal(character, item, cap)
    if not character or not item then return end
    local md = item:getModData()
    if cap then
        if md.csrJarSealed then return end
        local lid = findLidRecursive(character)
        if not lid then return end
        local lidContainer = (lid.getContainer and lid:getContainer()) or character:getInventory()
        lidContainer:Remove(lid)
        md.csrJarSealed = true
        local origName = item.getName and item:getName() or nil
        if origName then md.csrJarOriginalName = origName end
        if item.setName then
            item:setName(getText("IGUI_CSR_JarSealedPrefix") .. " " .. (origName or item:getDisplayName() or "Jar"))
        end
        if item.setCustomName then item:setCustomName(true) end
    else
        if not md.csrJarSealed then return end
        md.csrJarSealed = nil
        if md.csrJarOriginalName and item.setName then
            item:setName(md.csrJarOriginalName)
            md.csrJarOriginalName = nil
            if item.setCustomName then item:setCustomName(false) end
        end
        character:getInventory():AddItem("Base.JarLid")
    end
end

function CSR_JarCapAction:new(character, item, cap)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.item = item
    o.itemId = item and item.getID and item:getID() or nil
    o.expectedType = item and item.getFullType and item:getFullType() or nil
    o.cap = cap and true or false
    o.maxTime = 40
    o.stopOnWalk = false
    o.stopOnRun = true
    return o
end

return CSR_JarCapAction
