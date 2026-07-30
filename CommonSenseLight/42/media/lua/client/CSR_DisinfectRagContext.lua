-- CSR_DisinfectRagContext.lua
-- Adds "Soak with disinfectant" for clean bandages/ripped sheets. In MP the
-- inventory mutation is routed to the server; in SP it is applied locally.

require "CSR_FeatureFlags"
require "CSR_Utils"
require "CSR_DisinfectantUtils"

local CSR_DisinfectRagContext = {}

local function walkContainer(container, callback, visitedContainers, visitedItems)
    if not container or visitedContainers[container] then return end
    visitedContainers[container] = true

    local items = container.getItems and container:getItems() or nil
    if not items then return end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local id = item and item.getID and item:getID() or nil
        if item and (not id or not visitedItems[id]) then
            if id then visitedItems[id] = true end
            callback(item)
        end

        local subInventory = item and item.getInventory and item:getInventory() or nil
        if subInventory then
            walkContainer(subInventory, callback, visitedContainers, visitedItems)
        end
    end
end

local function findDisinfectants(player)
    local out = {}
    if not ISInventoryPaneContextMenu or not ISInventoryPaneContextMenu.getContainers then return out end
    local containers = ISInventoryPaneContextMenu.getContainers(player)
    if not containers then return out end

    local visitedContainers = {}
    local visitedItems = {}
    for i = 0, containers:size() - 1 do
        walkContainer(containers:get(i), function(item)
            if CSR_DisinfectantUtils.isDisinfectant(item) then
                table.insert(out, item)
            end
        end, visitedContainers, visitedItems)
    end
    return out
end

local function disinfectantLabel(item)
    local fluid = CSR_DisinfectantUtils.getFluidInfo(item)
    if fluid then
        return string.format("%s (%.2fL)", item:getName(), fluid.amount)
    end
    return item:getName()
end

local function removeItem(container, item)
    if container.DoRemoveItem then
        container:DoRemoveItem(item)
    else
        container:Remove(item)
    end
end

local function performSoakLocal(player, ragItem, disinfectant)
    if not player or not ragItem or not disinfectant then return end
    if not CSR_DisinfectantUtils.isDisinfectant(disinfectant) then return end

    local ragCont = ragItem.getContainer and ragItem:getContainer() or nil
    if not ragCont then return end

    local newType = CSR_DisinfectantUtils.getDisinfectedBandageType(ragItem:getFullType())
    if not newType then return end

    if not CSR_DisinfectantUtils.drainDisinfectant(
        disinfectant,
        CSR_DisinfectantUtils.RAG_DRAIN_AMOUNT
    ) then
        return
    end

    removeItem(ragCont, ragItem)
    local replacement = ragCont:AddItem(newType)
    if replacement and ragItem.copyModData then
        pcall(function() replacement:copyModData(ragItem:getModData()) end)
    end
end

local function performSoak(player, ragItem, disinfectant)
    if not player or not ragItem or not disinfectant then return end

    if isClient and isClient() then
        if not ragItem.getID or not disinfectant.getID then return end
        sendClientCommand(player, "CommonSenseLight", "DisinfectRag", {
            ragId = ragItem:getID(),
            ragType = ragItem:getFullType(),
            disinfectantId = disinfectant:getID(),
            disinfectantType = disinfectant:getFullType(),
            requestId = CSR_Utils.makeRequestId(player, "DisinfectRag"),
        })
        return
    end

    performSoakLocal(player, ragItem, disinfectant)
end

function CSR_DisinfectRagContext.onFillInventoryObjectContextMenu(playerNum, context, items)
    if not CSR_FeatureFlags or not CSR_FeatureFlags.isEquipmentQoLEnabled
        or not CSR_FeatureFlags.isEquipmentQoLEnabled() then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local rags = {}
    for _, entry in ipairs(items) do
        local item = entry
        if type(entry) == "table" and entry.items and entry.items[1] then
            item = entry.items[1]
        end
        if item and item.getFullType and CSR_DisinfectantUtils.getDisinfectedBandageType(item:getFullType()) then
            table.insert(rags, item)
        end
    end
    if #rags == 0 then return end

    local disinfectants = findDisinfectants(player)
    if #disinfectants == 0 then return end
    table.sort(disinfectants, function(a, b)
        return CSR_DisinfectantUtils.getRagPriority(a) < CSR_DisinfectantUtils.getRagPriority(b)
    end)

    local rag = rags[1]
    local soakOpt = context:addOption(getText("ContextMenu_CSR_SoakWithDisinfectant"))
    local subMenu = ISContextMenu:getNew(context)
    context:addSubMenu(soakOpt, subMenu)
    soakOpt.itemForTexture = disinfectants[1]

    for _, disinfectant in ipairs(disinfectants) do
        local d = disinfectant
        local opt = subMenu:addOption(disinfectantLabel(d), nil, function()
            performSoak(player, rag, d)
        end)
        opt.itemForTexture = d
    end
end

if Events and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(CSR_DisinfectRagContext.onFillInventoryObjectContextMenu)
end

return CSR_DisinfectRagContext
