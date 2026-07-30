--[[
    CSR_WashAll — adds a "Wash Everything" world-object option that washes
    body + recursive inventory + dirty bandages in a single timed action.

    Complements CSR_WashMenu (which only sorts the vanilla wash submenu).
    Server-validated through CSR_ServerCommands.handleWashAll.
]]--

require "CSR_FeatureFlags"
require "TimedActions/CSR_WashAllAction"

CSR_WashAll = CSR_WashAll or {}

local function isFeatureOn()
    local sb = SandboxVars and SandboxVars.CommonSenseLight or {}
    return sb.EnableWashAll ~= false
end

local function findWaterSource(worldobjects, square, playerObj)
    if square then
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            if o and o.isWaterSource and o:isWaterSource() then return o end
            if o and o.getFluidContainer then
                local fc = o:getFluidContainer()
                if fc and fc.getAmount and fc:getAmount() > 0 then return o end
            end
        end
    end
    if worldobjects then
        for i = 1, #worldobjects do
            local o = worldobjects[i]
            if o then
                if o.isWaterSource and o:isWaterSource() then return o end
                if o.getFluidContainer then
                    local fc = o:getFluidContainer()
                    if fc and fc.getAmount and fc:getAmount() > 0 then return o end
                end
            end
        end
    end
    return nil
end

local function startWash(worldobjects, playerNum, sink, mode, dirtyCount)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or not sink then return end
    local target = sink:getSquare()
    if target then
        local adj = AdjacentFreeTileFinder and AdjacentFreeTileFinder.Find(target, playerObj) or target
        if adj and (adj:getX() ~= playerObj:getX() or adj:getY() ~= playerObj:getY()) then
            ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, adj))
        end
    end
    ISTimedActionQueue.add(CSR_WashAllAction:new(playerObj, sink, mode, dirtyCount))
end

local function buildTooltip(text)
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = text
    return tip
end

function CSR_WashAll.onContextMenu(playerNum, context, worldobjects, test)
    if test == true then return end
    if not isFeatureOn() then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local square = nil
    if worldobjects and #worldobjects > 0 and worldobjects[1].getSquare then
        square = worldobjects[1]:getSquare()
    end
    local sink = findWaterSource(worldobjects, square, playerObj)
    if not sink then return end

    local water = CSR_WashAllAction.getAvailableWater(sink)
    if water <= 0 then return end

    local dirtyCount = CSR_WashAllAction.countDirtyRecursive(playerObj:getInventory(), nil, 0)
    local bodyDirty = CSR_WashAllAction.isBodyDirty(playerObj)
    if dirtyCount == 0 and not bodyDirty then return end

    local subMenu = ISContextMenu:getNew(context)
    local rootOpt = context:addOption(getText("ContextMenu_CSR_WashEverything"), worldobjects, nil)
    context:addSubMenu(rootOpt, subMenu)
    rootOpt.toolTip = buildTooltip(string.format("%s: %d <LINE> %s: %s",
        getText("Tooltip_CSR_WashItemsCount"), dirtyCount,
        getText("Tooltip_CSR_WashWaterAvail"),
        water >= 9999 and "infinite" or string.format("%.1f", water)))

    local total = dirtyCount + (bodyDirty and 1 or 0)
    local opt = subMenu:addOption(getText("ContextMenu_CSR_WashAll"), worldobjects, startWash, playerNum, sink, "all", total)
    opt.toolTip = buildTooltip(getText("Tooltip_CSR_WashAll"))

    if dirtyCount > 0 then
        local optInv = subMenu:addOption(getText("ContextMenu_CSR_WashInventory"), worldobjects, startWash, playerNum, sink, "inventory", dirtyCount)
        optInv.toolTip = buildTooltip(getText("Tooltip_CSR_WashInventory"))
    end
    if bodyDirty then
        local optSelf = subMenu:addOption(getText("ContextMenu_CSR_WashSelf"), worldobjects, startWash, playerNum, sink, "self", 1)
        optSelf.toolTip = buildTooltip(getText("Tooltip_CSR_WashSelf"))
    end
end

if Events and Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(CSR_WashAll.onContextMenu)
end

return CSR_WashAll
