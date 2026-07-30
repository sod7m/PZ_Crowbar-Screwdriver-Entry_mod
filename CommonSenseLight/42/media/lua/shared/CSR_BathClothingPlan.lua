CSR_BathClothingPlan = CSR_BathClothingPlan or {}

local MAX_PLAN_ENTRIES = 64

local function itemFullType(item)
    return item and item.getFullType and item:getFullType() or ""
end

function CSR_BathClothingPlan.getWearLocation(item)
    if not item then return nil end
    if item.IsInventoryContainer and item:IsInventoryContainer()
        and item.canBeEquipped and item:canBeEquipped() ~= "" then
        return item:canBeEquipped()
    end
    if item.hasTag and ItemTag and item:hasTag(ItemTag.WEARABLE)
        and item.canBeEquipped and item:canBeEquipped() ~= "" then
        return item:canBeEquipped()
    end
    if item.getBodyLocation and item:getBodyLocation() ~= "" then
        return item:getBodyLocation()
    end
    return nil
end

function CSR_BathClothingPlan.encode(items)
    if not items then return "" end
    local out = {}
    for i = 1, #items do
        local item = items[i]
        local loc = CSR_BathClothingPlan.getWearLocation(item)
        local id = item and item.getID and item:getID() or nil
        if item and loc and id ~= nil then
            out[#out + 1] = table.concat({
                tostring(id),
                tostring(loc),
                itemFullType(item),
            }, "|")
        end
        if #out >= MAX_PLAN_ENTRIES then
            break
        end
    end
    return table.concat(out, ";")
end

function CSR_BathClothingPlan.decode(plan)
    local out = {}
    if type(plan) ~= "string" or plan == "" then return out end
    for raw in string.gmatch(plan, "[^;]+") do
        local id, loc, fullType = raw:match("^([^|]*)|([^|]*)|(.*)$")
        if id and loc and loc ~= "" then
            out[#out + 1] = {
                id = tonumber(id),
                loc = loc,
                fullType = fullType or "",
            }
        end
        if #out >= MAX_PLAN_ENTRIES then
            break
        end
    end
    return out
end

local function sameItem(item, entry)
    if not item or not entry then return false end
    if entry.id and item.getID and item:getID() == entry.id then
        return true
    end
    local loc = CSR_BathClothingPlan.getWearLocation(item)
    local locStr = loc and tostring(loc) or ""
    if locStr ~= entry.loc then return false end
    if entry.fullType == "" then return true end
    return itemFullType(item) == entry.fullType
end

local function findWornItem(player, entry)
    if not player or not player.getWornItems then return nil end
    local worn = player:getWornItems()
    if not worn then return nil end
    for i = 0, worn:size() - 1 do
        local wornEntry = worn:get(i)
        local item = wornEntry and wornEntry.getItem and wornEntry:getItem() or nil
        if sameItem(item, entry) then
            return item
        end
    end
    return nil
end

local function findInventoryItem(player, entry)
    if not player or not entry then return nil end
    local inv = player.getInventory and player:getInventory() or nil
    if not inv then return nil end

    local visited = {}
    local function scan(container)
        if not container or visited[container] then return nil end
        visited[container] = true
        local items = container.getItems and container:getItems() or nil
        if not items then return nil end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if sameItem(item, entry) then
                return item
            end
        end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and instanceof and instanceof(item, "InventoryContainer") then
                local subInv = item.getInventory and item:getInventory() or nil
                local found = scan(subInv)
                if found then return found end
            end
        end
        return nil
    end

    return scan(inv)
end

function CSR_BathClothingPlan.syncPlayer(player)
    if not player then return end
    if sendEquip then sendEquip(player) end
    if triggerEvent then triggerEvent("OnClothingUpdated", player) end
    if player.resetModelNextFrame then player:resetModelNextFrame() end
    if syncVisuals then syncVisuals(player) end
    if sendHumanVisual then sendHumanVisual(player) end
    if player.sendVisual then player:sendVisual() end
    if player.sendInventory then player:sendInventory() end
    if ISInventoryPage then ISInventoryPage.renderDirty = true end
end

function CSR_BathClothingPlan.applyUndress(player, plan)
    local entries = CSR_BathClothingPlan.decode(plan)
    if not player or #entries == 0 then return false end
    local changed = false
    for i = 1, #entries do
        local item = findWornItem(player, entries[i])
        if item then
            if player.removeFromHands then player:removeFromHands(item) end
            player:removeWornItem(item)
            changed = true
        end
    end
    if changed then
        CSR_BathClothingPlan.syncPlayer(player)
    end
    return changed
end

function CSR_BathClothingPlan.applyRedress(player, plan)
    local entries = CSR_BathClothingPlan.decode(plan)
    if not player or #entries == 0 then return false end
    local changed = false
    for i = 1, #entries do
        local item = findInventoryItem(player, entries[i])
        local loc = CSR_BathClothingPlan.getWearLocation(item)
        if item and loc and player.getWornItem and player:getWornItem(loc) ~= item then
            if player.removeFromHands then player:removeFromHands(item) end
            player:setWornItem(loc, item)
            changed = true
        end
    end
    if changed then
        CSR_BathClothingPlan.syncPlayer(player)
    end
    return changed
end

return CSR_BathClothingPlan
