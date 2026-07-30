
require "CSR_Utils"
require "CSR_FeatureFlags"

CSR_ContextMenu = {}

local function getDisplayNameForType(fullType)
    local scriptItem = ScriptManager and ScriptManager.instance and ScriptManager.instance:FindItem(fullType) or nil
    if scriptItem and scriptItem.getDisplayName then
        return scriptItem:getDisplayName()
    end
    return fullType
end

local function createTooltip(text)
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip.description = text
    return tooltip
end

local function setTooltip(option, lines)
    if not option or not lines or #lines == 0 then
        return
    end
    option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
end

local function addToolRepairOption(player, context, items, item)
    local torch = CSR_Utils.findPreferredPropaneTorch(player, CSR_Utils.getToolRepairTorchFuelCost())
    local scrap = CSR_Utils.findPreferredScrapMetal(player)
    local plank = CSR_Utils.findPreferredPlank(player)
    local option = context:addOption("Repair Tool", items, CSR_ContextMenu.onRepairTool, player, item, torch, scrap, plank)
    local fuelPercent = math.floor(CSR_Utils.getToolRepairTorchFuelCost() * 100)
    local lines = {
        "Requires: propane torch " .. fuelPercent .. "%+, scrap metal, and a plank.",
        "Consumes: " .. fuelPercent .. "% propane, 1 scrap metal, and 1 plank.",
    }
    local condPct = CSR_Utils.getConditionPercent(item)
    if condPct then
        lines[#lines + 1] = "Current condition: " .. condPct .. "%"
    end
    if not torch then
        lines[#lines + 1] = "Missing: propane torch with enough fuel."
    end
    if not scrap then
        lines[#lines + 1] = "Missing: scrap metal."
    end
    if not plank then
        lines[#lines + 1] = "Missing: plank."
    end
    if not (torch and scrap and plank) then
        option.notAvailable = true
    end
    setTooltip(option, lines)
end

local function isItemInCharacterInventory(item, player)
    if not item or not player or not item.getContainer then
        return false
    end

    local container = item:getContainer()
    if not container then
        return false
    end

    if container == player:getInventory() then
        return true
    end

    return container.isInCharacterInventory and container:isInCharacterInventory(player) or false
end

local function isContainerInCharacterInventory(container, player)
    if not container or not player then
        return false
    end
    if player.getInventory and container == player:getInventory() then
        return true
    end
    return container.isInCharacterInventory and container:isInCharacterInventory(player) or false
end

local function getItemIdKey(item)
    if item and item.getID then
        return tostring(item:getID())
    end
    return nil
end

local function addUniqueItem(list, seenIds, item)
    if not item then return false end
    local key = getItemIdKey(item)
    if key then
        if seenIds[key] then return false end
        seenIds[key] = true
    end
    list[#list + 1] = item
    return true
end

local function isTearAllCandidate(item, player)
    if not item or not CSR_Utils.getTearClothInfo(item) then
        return false
    end
    if item.isFavorite and item:isFavorite() then
        return false
    end
    if player and player.isEquippedClothing and player:isEquippedClothing(item) then
        return false
    end
    return true
end

local function isTearSingleCandidate(item)
    if not item or not CSR_Utils.getTearClothInfo(item) then
        return false
    end
    if item.isFavorite and item:isFavorite() then
        return false
    end
    return true
end

local function tearGroupNeedsMissingTool(group, tool)
    if tool then return false end
    for _, item in ipairs(group.items or {}) do
        local info = CSR_Utils.getTearClothInfo(item)
        if info and info.requiresTool then
            return true
        end
    end
    return false
end

local function queueActionAfterTransfers(player, itemsToTransfer, actionFactory)
    if not player or not actionFactory then
        return
    end

    if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.transferIfNeeded then
        for _, item in ipairs(itemsToTransfer or {}) do
            if item then
                ISInventoryPaneContextMenu.transferIfNeeded(player, item)
            end
        end
    end

    local finalAction = actionFactory()
    if finalAction then
        ISTimedActionQueue.add(finalAction)
    end
end

local function getCanOpeningTool(player, toolName)
    if toolName == "Knife" then
        return CSR_Utils.hasKnife(player)
    end
    if toolName == "Screwdriver" then
        return CSR_Utils.hasScrewdriver(player)
    end
    return player and player.getInventory and player:getInventory():FindAndReturn(toolName) or nil
end

local function findVehicleActionPart(player, vehicle, validator)
    if not player or not vehicle or not validator or not vehicle.getPartCount or not vehicle.getPartByIndex then
        return nil
    end

    if vehicle.getUseablePart then
        local useablePart = vehicle:getUseablePart(player)
        if useablePart and validator(useablePart) then
            return useablePart
        end
    end

    local bestPart = nil
    local bestDist = math.huge
    for partIndex = 1, vehicle:getPartCount() do
        local part = vehicle:getPartByIndex(partIndex - 1)
        if part and validator(part) then
            local area = part.getArea and part:getArea() or nil
            local areaCenter = area and vehicle.getAreaCenter and vehicle:getAreaCenter(area) or nil
            local dist = math.huge
            if areaCenter and areaCenter.x and areaCenter.y then
                dist = IsoUtils.DistanceToSquared(player:getX(), player:getY(), areaCenter.x, areaCenter.y)
            elseif vehicle.getX and vehicle.getY then
                dist = IsoUtils.DistanceToSquared(player:getX(), player:getY(), vehicle:getX(), vehicle:getY())
            end
            if not bestPart or dist < bestDist then
                bestDist = dist
                bestPart = part
            end
        end
    end

    return bestPart
end

local function addVehicleEntryOptions(context, worldobjects, player, vehicle)
    if not context or not player or not vehicle then
        return
    end
    if context.__csr_vehicle_entry_added then
        return
    end

    local screwdriver = CSR_Utils.hasScrewdriver(player)

    local lockpickPart = findVehicleActionPart(player, vehicle, CSR_Utils.canLockpickVehiclePart)
    if screwdriver and CSR_FeatureFlags.isLockpickEnabled() and lockpickPart then
        local option = context:addOption(getText("ContextMenu_CSR_PickVehicleDoor"), worldobjects, CSR_ContextMenu.onLockpickVehicleDoor, player, vehicle, lockpickPart, screwdriver)
        option.iconTexture = screwdriver:getTexture()
        setTooltip(option, {
            "Quietly unlock a locked vehicle door or hatch with a screwdriver.",
            "Opens the real vehicle door state on success.",
        })
        context.__csr_vehicle_entry_added = true
    end
end

function CSR_ContextMenu.addWorldObjectOptions(playerNum, context, worldobjects, test)
    if test then return end

    local player = getSpecificPlayer(playerNum)
    if not player then
        return
    end

    local crowbar = CSR_Utils.hasCrowbar(player)
    local screwdriver = CSR_Utils.hasScrewdriver(player)
    local corpseTarget = nil
    local barricadeTarget = nil

    local knowledgeSharing = CSR_KnowledgeSharing
    if knowledgeSharing and knowledgeSharing.addWorldOptions then
        knowledgeSharing.addWorldOptions(playerNum, context, worldobjects, test)
    end

    for _, obj in ipairs(worldobjects) do
        if CSR_FeatureFlags.isClipboardEnabled() and instanceof(obj, "IsoWorldInventoryObject") then
            local item = obj.getItem and obj:getItem() or nil
            if item and CSR_Utils.isClipboard(item) and CSR_Utils.canOpenClipboard(item) then
                local option = context:addOption(getText("ContextMenu_CSR_ReadClipboard"), worldobjects, CSR_ContextMenu.onReadClipboard, player, item)
                local summary = CSR_Utils.getClipboardSummary(item)
                local lines = { "Read this clipboard without picking it up." }
                if summary then
                    lines[#lines + 1] = string.format("Pages loaded: %d", summary.paperAmount or 0)
                    lines[#lines + 1] = string.format("Checklist entries: %d / %d", summary.checkedEntries or 0, summary.totalEntries or 0)
                end
                setTooltip(option, lines)
            end
        end

        if not corpseTarget and CSR_FeatureFlags.isCorpseIgniteEnabled() and instanceof(obj, "IsoDeadBody") then
            corpseTarget = obj
        end

        if not barricadeTarget and instanceof(obj, "IsoWindow")
            and not CSR_Utils.isBarricadedForPlayer(obj, player)
            and CSR_Utils.hasPlank(player)
            and (not obj.isBarricadeAllowed or obj:isBarricadeAllowed()) then
            barricadeTarget = obj
        end
    end

    -- B42: dead bodies are picked separately via IsoObjectPicker:PickCorpse
    -- and stored in fetchVars.body, not in the worldobjects array
    if not corpseTarget and CSR_FeatureFlags.isCorpseIgniteEnabled() then
        local fetch = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars or nil
        if fetch and fetch.body and instanceof(fetch.body, "IsoDeadBody") then
            corpseTarget = fetch.body
        end
    end

    if corpseTarget then
        local ignition = CSR_Utils.findPreferredIgnitionSource(player)
        if ignition then
            local igniteOption = context:addOption(getText("ContextMenu_CSR_IgniteCorpse"), worldobjects, CSR_ContextMenu.onIgniteCorpse, player, corpseTarget, ignition)
            local lines = {
                "Set this corpse alight using the most-depleted lighter or matches first.",
                "Makes the corpse burn without needing a full fuel can.",
            }
            local fuelPct = CSR_Utils.getDrainableInsight(ignition)
            if fuelPct then
                lines[#lines + 1] = "Selected ignition source remaining: " .. fuelPct .. "%"
            end
            setTooltip(igniteOption, lines)
        end
    end

    if barricadeTarget then
        local plank = CSR_Utils.findPreferredPlank(player)
        if plank then
            local barricadeOption = context:addOption(getText("ContextMenu_CSR_BarricadeWindow"), worldobjects, CSR_ContextMenu.onBarricadeWindow, player, barricadeTarget, plank)
            setTooltip(barricadeOption, {
                "Quick-barricade this window with one plank.",
                "CSR shortcut: skips the vanilla hammer and nail requirement.",
            })
        end
    end

    if crowbar and CSR_FeatureFlags.isPryEnabled() then
        local retryTarget = CSR_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSR_Utils.isPryRetryTarget(obj) == true
                and CSR_Utils.canPryWorldTarget(obj, player) == true
        end)
        if retryTarget then
            local option = context:addOption("Force Open Again", worldobjects, CSR_ContextMenu.onPryOpen, player, retryTarget, crowbar)
            option.iconTexture = crowbar:getTexture()
            setTooltip(option, {
                "Re-force a security door or CSR-pried door that closed again.",
                "Success scales with strength, fitness, and crowbar condition.",
            })
        end

        local pryTarget = CSR_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSR_Utils.canPryWorldTarget(obj, player) == true
                and CSR_Utils.isPryRetryTarget(obj) ~= true
        end)
        if pryTarget then
            local option = context:addOption(getText("ContextMenu_CSR_PryOpen"), worldobjects, CSR_ContextMenu.onPryOpen, player, pryTarget, crowbar)
            option.iconTexture = crowbar:getTexture()
            setTooltip(option, {
                "Use a crowbar to force this open.",
                "Success scales with strength, fitness, and crowbar condition.",
            })
        end
    end

    if screwdriver and CSR_FeatureFlags.isLockpickEnabled() then
        local lockpickTarget = CSR_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSR_Utils.canLockpickWorldTarget(obj, player) == true
        end)
        if lockpickTarget then
            local option = context:addOption(getText("ContextMenu_CSR_PickLockScrewdriver"), worldobjects, CSR_ContextMenu.onLockpickOpen, player, lockpickTarget, screwdriver)
            option.iconTexture = screwdriver:getTexture()
            setTooltip(option, {
                "Use a screwdriver to work the lock quietly.",
                "Success scales with nimble, mechanics, fitness, and screwdriver condition.",
            })
        end
    end

    local paperclip = CSR_Utils.findPaperclip(player)
    if paperclip and CSR_FeatureFlags.isLockpickEnabled() then
        local lockpickTarget = CSR_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSR_Utils.canLockpickWorldTarget(obj, player) == true
        end)
        if lockpickTarget then
            local option = context:addOption(getText("ContextMenu_CSR_PickLockPaperclip"), worldobjects, CSR_ContextMenu.onLockpickOpen, player, lockpickTarget, paperclip)
            option.iconTexture = paperclip:getTexture()
            setTooltip(option, {
                "Bend a paperclip and try to pick the lock.",
                "Much lower success rate than a screwdriver.",
                "The paperclip is consumed on success.",
            })
        end
    end

    local boltCutters = CSR_Utils.hasBoltCutters(player)
    if boltCutters and CSR_FeatureFlags.isBoltCutterEnabled() then
        local boltCutTarget = CSR_Utils.findWorldTarget(worldobjects, player, function(obj)
            return CSR_Utils.canBoltCutWorldTarget(obj, player) == true
        end)
        if boltCutTarget then
            local option = context:addOption(getText("ContextMenu_CSR_CutLockBoltCutters"), worldobjects, CSR_ContextMenu.onBoltCut, player, boltCutTarget, boltCutters)
            option.iconTexture = boltCutters:getTexture()
            setTooltip(option, {
                "Use bolt cutters to cut through the lock mechanism.",
                "Works on metal gates, security doors, and garage doors.",
                "Success scales with strength, fitness, and tool condition.",
            })
        end

        if CSR_FeatureFlags.isFenceCuttingEnabled() then
            local fenceTarget = CSR_Utils.findWorldTarget(worldobjects, player, function(obj)
                return CSR_Utils.canBoltCutFence(obj, player) == true
            end)
            if fenceTarget then
                local option = context:addOption(getText("ContextMenu_CSR_CutFenceBoltCutters"), worldobjects, CSR_ContextMenu.onBoltCutFence, player, fenceTarget, boltCutters)
                option.iconTexture = boltCutters:getTexture()
                setTooltip(option, {
                    "Cut through a wire-mesh or barbed-wire fence panel.",
                    "Removes the panel and drops the salvaged wire at your feet.",
                    "Success scales with strength, fitness, and tool condition.",
                })
            end
        end
    end

    local clickedVehicle = nil
    local fetch = ISWorldObjectContextMenu.fetchVars
    if fetch and fetch.clickedSquare and fetch.clickedSquare.getVehicleContainer then
        clickedVehicle = fetch.clickedSquare:getVehicleContainer()
    end

    if not clickedVehicle then
        for _, obj in ipairs(worldobjects) do
            if instanceof(obj, "BaseVehicle") then
                clickedVehicle = obj
                break
            elseif obj.getSquare and obj:getSquare() and obj:getSquare().getVehicleContainer then
                clickedVehicle = obj:getSquare():getVehicleContainer()
                if clickedVehicle then
                    break
                end
            end
        end
    end

    if clickedVehicle then
        addVehicleEntryOptions(context, worldobjects, player, clickedVehicle)
    end
end

function CSR_ContextMenu.onPryOpen(worldobjects, player, obj, crowbar)
    if CSR_PryOpenAction then
        local square = obj and obj.getSquare and obj:getSquare() or nil
        if square and luautils.walkAdjWindowOrDoor(player, square, obj) then
            ISTimedActionQueue.add(CSR_PryOpenAction:new(player, obj, crowbar))
        end
    end
end

function CSR_ContextMenu.onPryVehicleDoor(worldobjects, player, vehicle, part, crowbar)
    if CSR_PryVehicleDoorAction then
        ISTimedActionQueue.add(CSR_PryVehicleDoorAction:new(player, vehicle, part, crowbar))
    end
end

function CSR_ContextMenu.onLockpickOpen(worldobjects, player, obj, screwdriver)
    if CSR_LockpickOpenAction then
        local square = obj and obj.getSquare and obj:getSquare() or nil
        if square and luautils.walkAdjWindowOrDoor(player, square, obj) then
            ISTimedActionQueue.add(CSR_LockpickOpenAction:new(player, obj, screwdriver))
        end
    end
end

function CSR_ContextMenu.onBoltCut(worldobjects, player, obj, boltCutters)
    if CSR_BoltCutAction then
        local square = obj and obj.getSquare and obj:getSquare() or nil
        if square and luautils.walkAdjWindowOrDoor(player, square, obj) then
            ISTimedActionQueue.add(CSR_BoltCutAction:new(player, obj, boltCutters))
        end
    end
end

function CSR_ContextMenu.onBoltCutFence(worldobjects, player, obj, boltCutters)
    if CSR_BoltCutAction then
        local square = obj and obj.getSquare and obj:getSquare() or nil
        -- B42 fence panels expose orientation like doors/windows; using
        -- walkAdjWindowOrDoor lets the player approach from either side
        -- of the fence, matching vanilla "Climb Over" behavior. Plain
        -- walkAdj only finds a path on whichever side the engine picked,
        -- which is why the option appeared dead from one direction.
        local approached = false
        if square then
            if luautils.walkAdjWindowOrDoor then
                approached = luautils.walkAdjWindowOrDoor(player, square, obj)
            end
            if not approached then
                approached = luautils.walkAdj(player, square)
            end
        end
        if approached then
            local action = CSR_BoltCutAction:new(player, obj, boltCutters)
            action.isFence = true
            ISTimedActionQueue.add(action)
        end
    end
end

function CSR_ContextMenu.onLockpickVehicleDoor(worldobjects, player, vehicle, part, screwdriver)
    if not player or not player.getCharacterActions or not vehicle or not part or not screwdriver then
        return
    end
    if CSR_LockpickVehicleDoorAction then
        ISTimedActionQueue.add(CSR_LockpickVehicleDoorAction:new(player, vehicle, part, screwdriver))
    end
end

function CSR_ContextMenu.onReadClipboard(worldobjects, player, item)
    if CSR_Clipboard and CSR_Clipboard.show then
        CSR_Clipboard.show(player, item, true)
    end
end

-- The old inventory-menu builder is intentionally commented out. PZ's Kahlua
-- compiler counts locals across an entire function and this monolithic version
-- crossed its 200-local limit, preventing the file from loading.
--[[
function CSR_ContextMenu.addInventoryOptions_legacy(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then
        return
    end

    local inventoryItems = CSR_Utils.resolveInventorySelection(items)
    local singleSelection = #inventoryItems == 1
    local canGroups = {}
    local jarGroups = {}
    local clothGroups = {}
    local logItems = {}
    local watchItems = {}
    local ammoBoxGroups = {}
    local ammoRoundGroups = {}
    local bandageOptionAdded = false
    local allInPlayerInventory = #inventoryItems > 0
    local clothCuttingTool = CSR_Utils.findClothCuttingTool(player)

    for _, item in ipairs(inventoryItems) do
        if not isItemInCharacterInventory(item, player) then
            allInPlayerInventory = false
            break
        end
    end

    if #inventoryItems > 1 and allInPlayerInventory and ISInventoryPaneContextMenu.onDropItems then
        context:addOptionOnTop(string.format("Drop Selected (%d)", #inventoryItems), inventoryItems, ISInventoryPaneContextMenu.onDropItems, playerNum)
    end

    -- Bink's No Stinks: Pooper Scooper -- radius dung scoop
    if CSR_FeatureFlags.isBinksScooperEnabled and CSR_FeatureFlags.isBinksScooperEnabled()
        and CSR_ScoopDungAction then
        local scooper = nil
        for _, item in ipairs(inventoryItems) do
            if item and item.getFullType and item:getFullType() == "Base.CSR_BinksScooper"
                and isItemInCharacterInventory(item, player) then
                scooper = item
                break
            end
        end
        if not scooper and player.getInventory then
            scooper = player:getInventory():FindAndReturn("CSR_BinksScooper")
        end
        if scooper then
            local radius = CSR_FeatureFlags.getBinksScooperRadius and CSR_FeatureFlags.getBinksScooperRadius() or 3
            local maxPer = CSR_FeatureFlags.getBinksScooperMaxPerAction and CSR_FeatureFlags.getBinksScooperMaxPerAction() or 30
            local targets = CSR_ScoopDungAction.findDungInRadius(player, radius)
            local optText = string.format("Scoop Dung in Radius %d", radius)
            local opt = context:addOption(optText, items, CSR_ContextMenu.onBinksScoopDung, player, scooper, targets, radius, maxPer)
            local lines = {
                "Use Bink's No Stinks: Pooper Scooper to clear all animal dung within a " .. radius .. "-tile radius.",
                "Targets: chicken, turkey, cow, deer, mouse, pig, rabbit, raccoon, rat, sheep dung.",
                "Found in radius: " .. tostring(#targets),
            }
            if #targets > maxPer then
                lines[#lines + 1] = "Will scoop up to " .. tostring(maxPer) .. " per action."
            end
            setTooltip(opt, lines)
            if #targets == 0 or scooper:getCondition() <= 0 then
                opt.notAvailable = true
            end
            opt.iconTexture = scooper.getTexture and scooper:getTexture() or nil
        end
    end

    for _, item in ipairs(inventoryItems) do
        if singleSelection and CSR_FeatureFlags.isClipboardEnabled() and CSR_Utils.isClipboard(item) then
            local data = CSR_Utils.getClipboardData(item)
            local paper = player:getInventory():FindAndReturn("SheetPaper2")
            local summary = CSR_Utils.getClipboardSummary(item)

            if summary then
                local option = context:addOption(getText("ContextMenu_CSR_OpenClipboard"), items, CSR_ContextMenu.onOpenClipboard, player, item)
                local lines = {
                    "Open and edit this clipboard.",
                    string.format("Paper: %d / 5", summary.paperAmount or 0),
                }
                if summary.totalEntries and summary.totalEntries > 0 then
                    lines[#lines + 1] = string.format("Checklist progress: %d / %d", summary.checkedEntries or 0, summary.totalEntries)
                end
                if not CSR_Utils.canOpenClipboard(item) then
                    lines[#lines + 1] = "Add paper before writing."
                end
                setTooltip(option, lines)
            end

            if data and data.paperAmount < 5 then
                local option = context:addOption(getText("ContextMenu_CSR_AddPaperToClipboard"), items, CSR_ContextMenu.onClipboardAddPaper, player, item)
                setTooltip(option, {
                    paper and "Insert one sheet of paper to unlock more checklist rows." or "Need a sheet of paper in inventory.",
                    string.format("Paper after action: %d / 5", math.min(5, (data.paperAmount or 0) + 1)),
                })
                if not paper then
                    option.notAvailable = true
                end
            end

            if data and data.paperAmount > 0 then
                local option = context:addOption(getText("ContextMenu_CSR_RemovePaperFromClipboard"), items, CSR_ContextMenu.onClipboardRemovePaper, player, item)
                setTooltip(option, {
                    "Remove one sheet of paper and return it to inventory.",
                    string.format("Paper after action: %d / 5", math.max(0, (data.paperAmount or 0) - 1)),
                })
            end
        end

        if CSR_Utils.isSupportedJarFood(item) and CSR_FeatureFlags.isAlternateCanOpeningEnabled() then
            local resultType = CSR_Utils.getOpenJarResult(item)
            local groupKey = resultType or item:getFullType()
            if not jarGroups[groupKey] then
                jarGroups[groupKey] = { items = {}, sourceType = item:getFullType(), resultType = resultType }
            end
            table.insert(jarGroups[groupKey].items, item)
            if singleSelection then
                local option = context:addOption(getText("ContextMenu_CSR_OpenJar"), items, CSR_ContextMenu.onOpenJar, player, item)
                setTooltip(option, {
                    "Open preserved food and keep the jar lid.",
                    "Freshness: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown"),
                })
            end
        end

        if CSR_Utils.isSupportedCan(item) and CSR_FeatureFlags.isAlternateCanOpeningEnabled() then
            local resultType = CSR_Utils.getOpenCanResult(item)
            local groupKey = resultType or item:getFullType()
            if not canGroups[groupKey] then
                canGroups[groupKey] = { items = {}, sourceType = item:getFullType(), resultType = resultType }
            end
            table.insert(canGroups[groupKey].items, item)

            -- Show single-can options for the first can in each group (works in both single and multi select)
            if #canGroups[groupKey].items == 1 and CSR_Utils.hasKnife(player) then
                local option = context:addOption(getText("ContextMenu_CSR_OpenWithKnife"), items, CSR_ContextMenu.onOpenCan, player, item, "Knife")
                setTooltip(option, {
                    "Open this can with a knife.",
                    "Food state: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown"),
                })
            end
            if #canGroups[groupKey].items == 1 and CSR_Utils.hasScrewdriver(player) then
                local option = context:addOption(getText("ContextMenu_CSR_OpenWithScrewdriver"), items, CSR_ContextMenu.onOpenCan, player, item, "Screwdriver")
                setTooltip(option, {
                    "Open this can with a screwdriver.",
                    "Food state: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown"),
                })
            end
        end

        if singleSelection and CSR_FeatureFlags.isPourCanContentsEnabled() and CSR_Utils.canPourCanContents(item) then
            local option = context:addOption(getText("ContextMenu_CSR_PourOnGround"), items, ISInventoryPaneContextMenu.onDumpContents, item, playerNum)
            setTooltip(option, {
                "Dump the contents and keep the empty can.",
                "Food state: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown"),
            })
        end

        if singleSelection and CSR_FeatureFlags.isRepairEnabled() and CSR_Utils.isRepairableItem(item) then
            local isClothing = CSR_Utils.isClothingItem(item)
            local isTool = CSR_Utils.isToolRepairTarget(item)

            if isTool then
                addToolRepairOption(player, context, items, item)
            elseif not isClothing then
                local repairTool = CSR_Utils.findRepairTool(player, item)
                if repairTool then
                    local option = context:addOption(getText("ContextMenu_CSR_QuickRepair"), items, CSR_ContextMenu.onRepairItem, player, item, repairTool)
                    local lines = {
                        "Use " .. repairTool:getDisplayName() .. " for a quick repair.",
                    }
                    local better, pct = CSR_Utils.findBetterDuplicate(player, item)
                    if better and pct then
                        lines[#lines + 1] = "Better duplicate in inventory: " .. pct .. "%"
                    end
                    setTooltip(option, lines)
                end
            end

            if not isTool and CSR_Utils.hasDuctTape(player) then
                local tape = CSR_Utils.findPreferredDuctTape(player)
                local option = context:addOption(getText("ContextMenu_CSR_RepairDuctTape"), items, CSR_ContextMenu.onDuctTapeRepair, player, item)
                local lines = { "Uses the most depleted duct tape first." }
                local pct = tape and CSR_Utils.getDrainableInsight(tape) or nil
                if pct then
                    lines[#lines + 1] = "Selected tape remaining: " .. pct .. "%"
                end
                setTooltip(option, lines)
            end

            if not isTool and not isClothing and CSR_Utils.hasGlue(player) then
                local glue = CSR_Utils.findPreferredGlue(player)
                local option = context:addOption(getText("ContextMenu_CSR_RepairGlue"), items, CSR_ContextMenu.onGlueRepair, player, item)
                local lines = { "Uses the most depleted glue first." }
                local pct = glue and CSR_Utils.getDrainableInsight(glue) or nil
                if pct then
                    lines[#lines + 1] = "Selected glue remaining: " .. pct .. "%"
                end
                setTooltip(option, lines)
            end

            if not isTool and CSR_Utils.hasTape(player) then
                local tape = CSR_Utils.findPreferredTape(player)
                local option = context:addOption(getText("ContextMenu_CSR_RepairTape"), items, CSR_ContextMenu.onTapeRepair, player, item)
                local lines = { "Uses the most depleted tape first." }
                local pct = tape and CSR_Utils.getDrainableInsight(tape) or nil
                if pct then
                    lines[#lines + 1] = "Selected tape remaining: " .. pct .. "%"
                end
                setTooltip(option, lines)
            end
        end

        if singleSelection and CSR_FeatureFlags.isRepairEnabled() and CSR_Utils.canTailorClothing(item) then
            local option = context:addOption(getText("ContextMenu_CSR_TailorClothing"), items, CSR_ContextMenu.onOpenGarmentUI, player, item)
            local lines = { "Open the native tailoring interface for this garment." }
            local better, pct = CSR_Utils.findBetterDuplicate(player, item)
            if better and pct then
                lines[#lines + 1] = "Better duplicate in inventory: " .. pct .. "%"
            end
            setTooltip(option, lines)
        end

        if singleSelection and CSR_FeatureFlags.isRepairEnabled() and CSR_Utils.canPatchClothing(item, player) then
            local fabric = CSR_Utils.findPreferredFabricMaterial(player)
            local option = context:addOption(getText("ContextMenu_CSR_PatchClothing"), items, CSR_ContextMenu.onPatchClothing, player, item)
            local lines = { "Sew fabric onto this garment to restore condition." }
            if fabric then
                lines[#lines + 1] = "Using: " .. fabric:getDisplayName()
            end
            lines[#lines + 1] = "Requires: thread, needle, and fabric material."
            local condPct = CSR_Utils.getConditionPercent(item)
            if condPct then
                lines[#lines + 1] = "Current condition: " .. condPct .. "%"
            end
            setTooltip(option, lines)
        end

        if singleSelection and CSR_Utils.isClothingItem(item)
            and CSR_FeatureFlags.isRepairAllClothingEnabled
            and CSR_FeatureFlags.isRepairAllClothingEnabled()
            and CSR_Utils.canRepairAllClothing(player) then
            local option = context:addOption(getText("ContextMenu_CSR_RepairAllClothing"), items, CSR_ContextMenu.onRepairAllClothing, player)
            local damaged = CSR_Utils.getDamagedWornClothing(player)
            local fabricCount = CSR_Utils.countFabricMaterials(player)
            local lines = {
                "Restore every worn garment to full condition and remove all sewn-on patches.",
                "Damaged garments to repair: " .. tostring(#damaged),
                "Cost per garment: 1 thread use, 1 needle wear, 1 fabric strip.",
                "Fabric strips on hand: " .. tostring(fabricCount),
            }
            if fabricCount < #damaged then
                lines[#lines + 1] = "(Will stop early when fabric runs out.)"
            end
            setTooltip(option, lines)
        end

        if isTearAllCandidate(item, player) then
            local clothType = item:getFullType()
            if not clothGroups[clothType] then
                clothGroups[clothType] = { items = {}, seenIds = {} }
            end
            addUniqueItem(clothGroups[clothType].items, clothGroups[clothType].seenIds, item)
            if singleSelection and not (item.isFavorite and item:isFavorite()) then
                local option = context:addOption(getText("ContextMenu_CSR_TearIntoRags"), items, CSR_ContextMenu.onTearCloth, player, item)
                local tearInfo = CSR_Utils.getTearClothInfo(item)
                local outputName = tearInfo and getDisplayNameForType(tearInfo.outputType) or "usable material"
                local lines = {
                    string.format("Convert this item into %d x %s.", tearInfo and tearInfo.quantity or 1, outputName),
                }
                if not isItemInCharacterInventory(item, player) then
                    lines[#lines + 1] = "Will loot the item first, then tear it."
                end
                if player and player.isEquippedClothing and player:isEquippedClothing(item) then
                    lines[#lines + 1] = "Will unequip the item first."
                end
                if tearInfo and tearInfo.requiresTool then
                    lines[#lines + 1] = "Need scissors or a sharp knife."
                    if not clothCuttingTool then
                        option.notAvailable = true
                    end
                end
                setTooltip(option, lines)
            end
        end

        if CSR_FeatureFlags.isEquipmentQoLEnabled() and CSR_Utils.isBandageMaterial(item) and not bandageOptionAdded then
            bandageOptionAdded = true
            local thread = CSR_Utils.findPreferredThread(player)
            local needle = CSR_Utils.findPreferredNeedle(player)
            local option = context:addOption(getText("ContextMenu_CSR_MakeBandage"), items, CSR_ContextMenu.onMakeBandage, player, item)
            local lines = {
                "Turn this material into a proper bandage.",
                "Requires: needle + thread",
            }
            if thread then
                local threadPct = CSR_Utils.getDrainableInsight(thread)
                if threadPct then
                    lines[#lines + 1] = "Thread remaining: " .. threadPct .. "%"
                end
            else
                lines[#lines + 1] = "Missing thread!"
            end
            if needle and needle.getCondition then
                local maxCondition = (needle.getConditionMax and needle:getConditionMax()) or needle:getCondition()
                lines[#lines + 1] = string.format("Needle condition: %d%%", math.floor((needle:getCondition() / math.max(1, maxCondition)) * 100))
            elseif not needle then
                lines[#lines + 1] = "Missing needle!"
            end
            if not isItemInCharacterInventory(item, player) then
                lines[#lines + 1] = "Will loot the material first, then craft the bandage."
            end
            setTooltip(option, lines)
            if not thread or not needle then
                option.notAvailable = true
            end
        end

        if singleSelection and CSR_FeatureFlags.isEquipmentQoLEnabled() and CSR_Utils.canRechargeFlashlight(item) and CSR_Utils.hasBattery(player) then
            local option = context:addOption(getText("ContextMenu_CSR_ReplaceBattery"), items, CSR_ContextMenu.onReplaceBattery, player, item)
            local pct = CSR_Utils.getDrainableInsight(item)
            setTooltip(option, {
                "Replace the battery in this flashlight.",
                pct and ("Current charge: " .. pct .. "%") or "Current charge unknown",
            })
        end

        if singleSelection and CSR_FeatureFlags.isEquipmentQoLEnabled() and CSR_Utils.isRefillableLighter(item) then
            -- v1.8.14: always show the option for any refillable lighter so
            -- the feature is discoverable. Grey out (with explanatory
            -- tooltip) when fluid is missing or the lighter is already
            -- full. Previously the option only appeared when both
            -- conditions were satisfied, so users with no LighterFluid
            -- on hand could not see that the feature exists.
            local pct = CSR_Utils.getDrainableInsight(item)
            local hasFluid = CSR_Utils.hasLighterFluid(player) ~= nil
            local isFull = item.getDelta and item:getDelta() >= 1.0
            local option = context:addOption(getText("ContextMenu_CSR_RefillLighter"), items, CSR_ContextMenu.onRefillLighter, player, item)
            if isFull then
                option.notAvailable = true
                setTooltip(option, {
                    "This lighter is already full.",
                    pct and ("Current fuel: " .. pct .. "%") or nil,
                })
            elseif not hasFluid then
                option.notAvailable = true
                setTooltip(option, {
                    "Refill this lighter using a Lighter Fluid can.",
                    "You don't have any Lighter Fluid in your inventory.",
                    pct and ("Current fuel: " .. pct .. "%") or nil,
                })
            else
                setTooltip(option, {
                    "Refill this lighter using the most depleted lighter fluid first.",
                    pct and ("Current fuel: " .. pct .. "%") or "Current fuel unknown",
                })
            end
        end

        if item and item.getFullType and item:getFullType() == "Base.Log" then
            table.insert(logItems, item)
        end

        if CSR_DismantleAllWatchesAction and CSR_DismantleAllWatchesAction.isWatchItem and CSR_DismantleAllWatchesAction.isWatchItem(item) then
            table.insert(watchItems, item)
        end

        if CSR_FeatureFlags.isAlternateCanOpeningEnabled() and CSR_Utils.isAmmoBox(item) then
            local info = CSR_Utils.getAmmoBoxInfo(item)
            local groupKey = item:getFullType()
            if not ammoBoxGroups[groupKey] then
                ammoBoxGroups[groupKey] = { items = {} }
            end
            if info then
                table.insert(ammoBoxGroups[groupKey].items, item)
            end
            if singleSelection and info then
                local option = context:addOption(getText("ContextMenu_CSR_OpenAmmoBox"), items, CSR_ContextMenu.onOpenAmmoBox, player, item)
                local roundName = getDisplayNameForType(info.round) or info.round
                setTooltip(option, { "Open box and dump rounds into inventory.", info.count .. "x " .. roundName })
            end
        end

        if CSR_FeatureFlags.isAlternateCanOpeningEnabled() and CSR_Utils.isAmmoRound(item) then
            local roundInfo = CSR_Utils.getAmmoRoundInfo(item)
            local roundType = item:getFullType()
            if roundInfo then
                if not ammoRoundGroups[roundType] then
                    ammoRoundGroups[roundType] = { count = 0, boxType = roundInfo.box, perBox = roundInfo.count }
                end
                ammoRoundGroups[roundType].count = ammoRoundGroups[roundType].count + 1
            end
        end
    end

    -- B42 often right-clicks a single row even when more matching items sit in
    -- the same visible container. Fill the Tear All group from that source so
    -- the bulk action is discoverable without manual multi-select.
    if singleSelection and inventoryItems[1] and isTearAllCandidate(inventoryItems[1], player) then
        local selected = inventoryItems[1]
        local clothType = selected.getFullType and selected:getFullType() or nil
        local container = selected.getContainer and selected:getContainer() or nil
        local group = clothType and clothGroups[clothType] or nil
        local containerItems = container and container.getItems and container:getItems() or nil
        if group and containerItems then
            for i = 0, containerItems:size() - 1 do
                local candidate = containerItems:get(i)
                if candidate
                    and candidate.getFullType
                    and candidate:getFullType() == clothType
                    and isTearAllCandidate(candidate, player) then
                    addUniqueItem(group.items, group.seenIds, candidate)
                end
            end
        end
    end

    if CSR_FeatureFlags.isAlternateCanOpeningEnabled() and (CSR_Utils.hasKnife(player) or CSR_Utils.hasScrewdriver(player)) then
        for _, group in pairs(canGroups) do
            if #group.items >= 2 then
                local count = #group.items
                local resultName = group.resultType and getDisplayNameForType(group.resultType) or getDisplayNameForType(group.sourceType)
                local text = string.format("Open All: %d x %s", count, resultName)
                local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onOpenAllCans, player, group.items, text)
                option.toolTip = createTooltip(string.format("Open %d selected cans that become %s.", count, resultName))
            end
        end
    end

    if CSR_FeatureFlags.isAlternateCanOpeningEnabled() then
        for _, group in pairs(jarGroups) do
            if #group.items >= 2 then
                local count = #group.items
                local resultName = group.resultType and getDisplayNameForType(group.resultType) or getDisplayNameForType(group.sourceType)
                local text = string.format("Open All Jars: %d x %s", count, resultName)
                local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onOpenAllJars, player, group.items, text)
                option.toolTip = createTooltip(string.format("Open %d selected jars and keep their lids.", count))
            end
        end
    end

    if CSR_FeatureFlags.isAlternateCanOpeningEnabled() then
        for _, group in pairs(ammoBoxGroups) do
            if #group.items >= 2 then
                local count = #group.items
                local boxName = getDisplayNameForType(group.items[1]:getFullType())
                local text = string.format("Open All: %d x %s", count, boxName)
                local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onOpenAllAmmoBoxes, player, group.items, text)
                option.toolTip = createTooltip(string.format("Dump rounds from %d ammo boxes into your inventory.", count))
            end
        end
    end

    if CSR_FeatureFlags.isAlternateCanOpeningEnabled() then
        for roundType, group in pairs(ammoRoundGroups) do
            local totalInInventory = CSR_Utils.countAmmoRoundsOfType(player, roundType)
            local boxesToMake = math.floor(totalInInventory / group.perBox)
            if boxesToMake >= 1 then
                local roundName = getDisplayNameForType(roundType) or roundType
                local boxName = getDisplayNameForType(group.boxType) or group.boxType
                if boxesToMake == 1 then
                    local text = string.format("Pack Ammo Box: %s", boxName)
                    local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onPackAmmoBox, player, roundType, group.boxType, group.perBox)
                    option.toolTip = createTooltip(string.format("Pack %d x %s into a %s.\n%d rounds available.", group.perBox, roundName, boxName, totalInInventory))
                else
                    local text = string.format("Pack All: %d x %s", boxesToMake, boxName)
                    local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onPackAllAmmoBoxes, player, roundType, group.boxType, group.perBox, text)
                    option.toolTip = createTooltip(string.format("Pack %d rounds into %d boxes of %s.\n%d rounds available.", boxesToMake * group.perBox, boxesToMake, boxName, totalInInventory))
                end
            end
        end
    end

    for clothType, group in pairs(clothGroups) do
        if #group.items >= 2 then
            local count = #group.items
            local clothName = getDisplayNameForType(clothType)
            local text = string.format("Tear All: %d x %s", count, clothName)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onTearAllCloth, player, group.items, text)
            local sample = group.items[1]
            local tearInfo = sample and CSR_Utils.getTearClothInfo(sample) or nil
            local outputName = tearInfo and getDisplayNameForType(tearInfo.outputType) or "usable material"
            local lines = {
                string.format("Tear %d selected %s items into %s.", count, clothName, outputName),
            }
            local needsLoot = false
            for _, item in ipairs(group.items) do
                if not isItemInCharacterInventory(item, player) then
                    needsLoot = true
                    break
                end
            end
            if needsLoot then
                lines[#lines + 1] = "Will loot selected items first, then tear them."
            end
            option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
            if tearGroupNeedsMissingTool(group, clothCuttingTool) then
                option.notAvailable = true
                lines[#lines + 1] = "Need scissors or a sharp knife."
                option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
            end
        end
    end

    -- "Tear All Nearby Clothing" — scoops every tearable clothing item from
    -- all visible loot containers (corpses, floor, vehicle storage, etc.).
    -- Inspired by TearAllClothes (Workshop 3519629457) "Surrounding" option.
    -- Shown for any tearable nearby item; tool-required fabrics are greyed out
    -- when the player lacks scissors or a sharp knife.
    do
        local cuttingTool = clothCuttingTool
        if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers then
            local nearbyTearable = {}
            local seenIds = {}
            -- Avoid duplicate option for items already covered by "Tear All: N x ..."
            for _, group in pairs(clothGroups) do
                for _, it in ipairs(group.items) do
                    local key = getItemIdKey(it)
                    if key then seenIds[key] = true end
                end
            end
            local containers = ISInventoryPaneContextMenu.getContainers(player)
            if containers then
                for ci = 0, containers:size() - 1 do
                    local container = containers:get(ci)
                    -- Skip the player's own inventory; we only want surrounding loot.
                    if container and not isContainerInCharacterInventory(container, player) then
                        local containerItems = container.getItems and container:getItems() or nil
                        if containerItems then
                            for ii = 0, containerItems:size() - 1 do
                                local it = containerItems:get(ii)
                                if isTearAllCandidate(it, player) then
                                    local key = getItemIdKey(it)
                                    if not key or not seenIds[key] then
                                        if key then seenIds[key] = true end
                                        nearbyTearable[#nearbyTearable + 1] = it
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if #nearbyTearable >= 2 then
                local text = string.format("Tear All Nearby Clothing: %d", #nearbyTearable)
                local opt = context:addOptionOnTop(text, items, CSR_ContextMenu.onTearAllCloth, player, nearbyTearable, text)
                if cuttingTool and cuttingTool.getTexture then
                    opt.iconTexture = cuttingTool:getTexture()
                end
                opt.toolTip = createTooltip(string.format(
                    "Tear %d clothing items from nearby loot containers (corpses, floor, vehicle storage). <LINE> Items will be looted first, then torn.",
                    #nearbyTearable))
                if tearGroupNeedsMissingTool({ items = nearbyTearable }, cuttingTool) then
                    opt.notAvailable = true
                    opt.toolTip.description = opt.toolTip.description .. " <LINE> Need scissors or a sharp knife."
                end
            end
        end
    end

    if #logItems >= 2 then
        local saw = CSR_Utils.findSaw(player)
        if saw then
            local count = #logItems
            local text = string.format("Saw All Logs: %d", count)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onSawAllLogs, player, logItems, saw, text)
            option.iconTexture = saw:getTexture()
            option.toolTip = createTooltip(string.format("Saw %d logs into %d planks. Grants carpentry XP.", count, count * 3))
        end
    end

    if CSR_FeatureFlags.isDismantleAllWatchesEnabled() and #watchItems >= 2 then
        local screwdriver = CSR_Utils.hasScrewdriver(player)
        if screwdriver then
            local count = #watchItems
            local text = string.format("Dismantle All Watches: %d", count)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onDismantleAllWatches, player, watchItems, screwdriver, text)
            option.iconTexture = screwdriver:getTexture()
            option.toolTip = createTooltip(string.format("Dismantle %d watches into electronics scrap. Grants electrical XP.", count))
        end
    end
end

--]]

local function allSelectionInPlayerInventory(inventoryItems, player)
    if #inventoryItems == 0 then return false end
    for _, item in ipairs(inventoryItems) do
        if not isItemInCharacterInventory(item, player) then
            return false
        end
    end
    return true
end

local function addDropSelectedOption(playerNum, context, inventoryItems)
    local player = getSpecificPlayer(playerNum)
    if #inventoryItems > 1
        and allSelectionInPlayerInventory(inventoryItems, player)
        and ISInventoryPaneContextMenu.onDropItems then
        context:addOptionOnTop(string.format("Drop Selected (%d)", #inventoryItems), inventoryItems, ISInventoryPaneContextMenu.onDropItems, playerNum)
    end
end

local function findSelectedScooper(player, inventoryItems)
    for _, item in ipairs(inventoryItems) do
        if item and item.getFullType and item:getFullType() == "Base.CSR_BinksScooper"
            and isItemInCharacterInventory(item, player) then
            return item
        end
    end
    return player.getInventory and player:getInventory():FindAndReturn("CSR_BinksScooper") or nil
end

local function addBinksScooperOption(player, context, items, inventoryItems)
    if not (CSR_FeatureFlags.isBinksScooperEnabled and CSR_FeatureFlags.isBinksScooperEnabled()) then return end
    if not CSR_ScoopDungAction then return end

    local scooper = findSelectedScooper(player, inventoryItems)
    if not scooper then return end

    local radius = CSR_FeatureFlags.getBinksScooperRadius and CSR_FeatureFlags.getBinksScooperRadius() or 3
    local maxPer = CSR_FeatureFlags.getBinksScooperMaxPerAction and CSR_FeatureFlags.getBinksScooperMaxPerAction() or 30
    local targets = CSR_ScoopDungAction.findDungInRadius(player, radius)
    local optText = string.format("Scoop Dung in Radius %d", radius)
    local opt = context:addOption(optText, items, CSR_ContextMenu.onBinksScoopDung, player, scooper, targets, radius, maxPer)
    local lines = {
        "Use Bink's No Stinks: Pooper Scooper to clear all animal dung within a " .. radius .. "-tile radius.",
        "Targets: chicken, turkey, cow, deer, mouse, pig, rabbit, raccoon, rat, sheep dung.",
        "Found in radius: " .. tostring(#targets),
    }
    if #targets > maxPer then
        lines[#lines + 1] = "Will scoop up to " .. tostring(maxPer) .. " per action."
    end
    setTooltip(opt, lines)
    if #targets == 0 or scooper:getCondition() <= 0 then
        opt.notAvailable = true
    end
    opt.iconTexture = scooper.getTexture and scooper:getTexture() or nil
end

local function addClipboardInventoryOptions(player, context, items, item)
    if not (CSR_FeatureFlags.isClipboardEnabled() and CSR_Utils.isClipboard(item)) then return end

    local data = CSR_Utils.getClipboardData(item)
    local paper = player:getInventory():FindAndReturn("SheetPaper2")
    local summary = CSR_Utils.getClipboardSummary(item)

    if summary then
        local option = context:addOption(getText("ContextMenu_CSR_OpenClipboard"), items, CSR_ContextMenu.onOpenClipboard, player, item)
        local lines = {
            "Open and edit this clipboard.",
            string.format("Paper: %d / 5", summary.paperAmount or 0),
        }
        if summary.totalEntries and summary.totalEntries > 0 then
            lines[#lines + 1] = string.format("Checklist progress: %d / %d", summary.checkedEntries or 0, summary.totalEntries)
        end
        if not CSR_Utils.canOpenClipboard(item) then
            lines[#lines + 1] = "Add paper before writing."
        end
        setTooltip(option, lines)
    end

    if data and data.paperAmount < 5 then
        local option = context:addOption(getText("ContextMenu_CSR_AddPaperToClipboard"), items, CSR_ContextMenu.onClipboardAddPaper, player, item)
        setTooltip(option, {
            paper and "Insert one sheet of paper to unlock more checklist rows." or "Need a sheet of paper in inventory.",
            string.format("Paper after action: %d / 5", math.min(5, (data.paperAmount or 0) + 1)),
        })
        if not paper then option.notAvailable = true end
    end

    if data and data.paperAmount > 0 then
        local option = context:addOption(getText("ContextMenu_CSR_RemovePaperFromClipboard"), items, CSR_ContextMenu.onClipboardRemovePaper, player, item)
        setTooltip(option, {
            "Remove one sheet of paper and return it to inventory.",
            string.format("Paper after action: %d / 5", math.max(0, (data.paperAmount or 0) - 1)),
        })
    end
end

local function collectJarOptions(player, context, items, item, singleSelection, state)
    if not (CSR_FeatureFlags.isAlternateCanOpeningEnabled() and CSR_Utils.isSupportedJarFood(item)) then return end

    local resultType = CSR_Utils.getOpenJarResult(item)
    local groupKey = resultType or item:getFullType()
    if not state.jarGroups[groupKey] then
        state.jarGroups[groupKey] = { items = {}, sourceType = item:getFullType(), resultType = resultType }
    end
    table.insert(state.jarGroups[groupKey].items, item)

    if singleSelection then
        local option = context:addOption(getText("ContextMenu_CSR_OpenJar"), items, CSR_ContextMenu.onOpenJar, player, item)
        setTooltip(option, {
            "Open preserved food and keep the jar lid.",
            "Freshness: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown"),
        })
    end
end

local function collectCanOptions(playerNum, player, context, items, item, singleSelection, state)
    if CSR_FeatureFlags.isAlternateCanOpeningEnabled() and CSR_Utils.isSupportedCan(item) then
        local resultType = CSR_Utils.getOpenCanResult(item)
        local groupKey = resultType or item:getFullType()
        if not state.canGroups[groupKey] then
            state.canGroups[groupKey] = { items = {}, sourceType = item:getFullType(), resultType = resultType }
        end
        table.insert(state.canGroups[groupKey].items, item)

        if #state.canGroups[groupKey].items == 1 and CSR_Utils.hasKnife(player) then
            local option = context:addOption(getText("ContextMenu_CSR_OpenWithKnife"), items, CSR_ContextMenu.onOpenCan, player, item, "Knife")
            setTooltip(option, { "Open this can with a knife.", "Food state: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown") })
        end
        if #state.canGroups[groupKey].items == 1 and CSR_Utils.hasScrewdriver(player) then
            local option = context:addOption(getText("ContextMenu_CSR_OpenWithScrewdriver"), items, CSR_ContextMenu.onOpenCan, player, item, "Screwdriver")
            setTooltip(option, { "Open this can with a screwdriver.", "Food state: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown") })
        end
    end

    if singleSelection and CSR_FeatureFlags.isPourCanContentsEnabled() and CSR_Utils.canPourCanContents(item) then
        local option = context:addOption(getText("ContextMenu_CSR_PourOnGround"), items, ISInventoryPaneContextMenu.onDumpContents, item, playerNum)
        setTooltip(option, {
            "Dump the contents and keep the empty can.",
            "Food state: " .. (CSR_Utils.getItemFreshnessInsight(item) or "Unknown"),
        })
    end
end

local function addRepairOptions(player, context, items, item, singleSelection)
    if not (singleSelection and CSR_FeatureFlags.isRepairEnabled() and CSR_Utils.isRepairableItem(item)) then return end

    local isClothing = CSR_Utils.isClothingItem(item)
    local isTool = CSR_Utils.isToolRepairTarget(item)
    if isTool then
        addToolRepairOption(player, context, items, item)
    elseif not isClothing then
        local repairTool = CSR_Utils.findRepairTool(player, item)
        if repairTool then
            local option = context:addOption(getText("ContextMenu_CSR_QuickRepair"), items, CSR_ContextMenu.onRepairItem, player, item, repairTool)
            local lines = { "Use " .. repairTool:getDisplayName() .. " for a quick repair." }
            local better, pct = CSR_Utils.findBetterDuplicate(player, item)
            if better and pct then
                lines[#lines + 1] = "Better duplicate in inventory: " .. pct .. "%"
            end
            setTooltip(option, lines)
        end
    end

    if not isTool and CSR_Utils.hasDuctTape(player) then
        local tape = CSR_Utils.findPreferredDuctTape(player)
        local option = context:addOption(getText("ContextMenu_CSR_RepairDuctTape"), items, CSR_ContextMenu.onDuctTapeRepair, player, item)
        local lines = { "Uses the most depleted duct tape first." }
        local pct = tape and CSR_Utils.getDrainableInsight(tape) or nil
        if pct then lines[#lines + 1] = "Selected tape remaining: " .. pct .. "%" end
        setTooltip(option, lines)
    end

    if not isTool and not isClothing and CSR_Utils.hasGlue(player) then
        local glue = CSR_Utils.findPreferredGlue(player)
        local option = context:addOption(getText("ContextMenu_CSR_RepairGlue"), items, CSR_ContextMenu.onGlueRepair, player, item)
        local lines = { "Uses the most depleted glue first." }
        local pct = glue and CSR_Utils.getDrainableInsight(glue) or nil
        if pct then lines[#lines + 1] = "Selected glue remaining: " .. pct .. "%" end
        setTooltip(option, lines)
    end

    if not isTool and CSR_Utils.hasTape(player) then
        local tape = CSR_Utils.findPreferredTape(player)
        local option = context:addOption(getText("ContextMenu_CSR_RepairTape"), items, CSR_ContextMenu.onTapeRepair, player, item)
        local lines = { "Uses the most depleted tape first." }
        local pct = tape and CSR_Utils.getDrainableInsight(tape) or nil
        if pct then lines[#lines + 1] = "Selected tape remaining: " .. pct .. "%" end
        setTooltip(option, lines)
    end
end

local function addClothingRepairOptions(player, context, items, item, singleSelection)
    if not (singleSelection and CSR_FeatureFlags.isRepairEnabled()) then return end

    if CSR_Utils.canTailorClothing(item) then
        local option = context:addOption(getText("ContextMenu_CSR_TailorClothing"), items, CSR_ContextMenu.onOpenGarmentUI, player, item)
        local lines = { "Open the native tailoring interface for this garment." }
        local better, pct = CSR_Utils.findBetterDuplicate(player, item)
        if better and pct then lines[#lines + 1] = "Better duplicate in inventory: " .. pct .. "%" end
        setTooltip(option, lines)
    end

    if CSR_Utils.canPatchClothing(item, player) then
        local fabric = CSR_Utils.findPreferredFabricMaterial(player)
        local option = context:addOption(getText("ContextMenu_CSR_PatchClothing"), items, CSR_ContextMenu.onPatchClothing, player, item)
        local lines = { "Sew fabric onto this garment to restore condition." }
        if fabric then lines[#lines + 1] = "Using: " .. fabric:getDisplayName() end
        lines[#lines + 1] = "Requires: thread, needle, and fabric material."
        local condPct = CSR_Utils.getConditionPercent(item)
        if condPct then lines[#lines + 1] = "Current condition: " .. condPct .. "%" end
        setTooltip(option, lines)
    end

    if CSR_Utils.isClothingItem(item)
        and CSR_FeatureFlags.isRepairAllClothingEnabled
        and CSR_FeatureFlags.isRepairAllClothingEnabled()
        and CSR_Utils.canRepairAllClothing(player) then
        local option = context:addOption(getText("ContextMenu_CSR_RepairAllClothing"), items, CSR_ContextMenu.onRepairAllClothing, player)
        local damaged = CSR_Utils.getDamagedWornClothing(player)
        local fabricCount = CSR_Utils.countFabricMaterials(player)
        local lines = {
            "Restore every worn garment to full condition and remove all sewn-on patches.",
            "Damaged garments to repair: " .. tostring(#damaged),
            "Cost per garment: 1 thread use, 1 needle wear, 1 fabric strip.",
            "Fabric strips on hand: " .. tostring(fabricCount),
        }
        if fabricCount < #damaged then lines[#lines + 1] = "(Will stop early when fabric runs out.)" end
        setTooltip(option, lines)
    end
end

local function collectTearOptions(player, context, items, item, singleSelection, state)
    local bulkCandidate = isTearAllCandidate(item, player)

    if bulkCandidate then
        local clothType = item:getFullType()
        if not state.clothGroups[clothType] then
            state.clothGroups[clothType] = { items = {}, seenIds = {} }
        end
        addUniqueItem(state.clothGroups[clothType].items, state.clothGroups[clothType].seenIds, item)
        if state.selectedTearItems and state.selectedTearSeenIds then
            addUniqueItem(state.selectedTearItems, state.selectedTearSeenIds, item)
        end
    end

    if not singleSelection or not isTearSingleCandidate(item) then return end

    local option = context:addOption(getText("ContextMenu_CSR_TearIntoRags"), items, CSR_ContextMenu.onTearCloth, player, item)
    local tearInfo = CSR_Utils.getTearClothInfo(item)
    local outputName = tearInfo and getDisplayNameForType(tearInfo.outputType) or "usable material"
    local lines = {
        string.format("Convert this item into %d x %s.", tearInfo and tearInfo.quantity or 1, outputName),
    }
    if not isItemInCharacterInventory(item, player) then
        lines[#lines + 1] = "Will loot the item first, then tear it."
    end
    if player and player.isEquippedClothing and player:isEquippedClothing(item) then
        lines[#lines + 1] = "Will unequip the item first."
    end
    if tearInfo and tearInfo.requiresTool then
        lines[#lines + 1] = "Need scissors or a sharp knife."
        if not state.clothCuttingTool then option.notAvailable = true end
    end
    setTooltip(option, lines)
end

local function addBandageOption(player, context, items, item)
    if not (CSR_FeatureFlags.isEquipmentQoLEnabled() and CSR_Utils.isBandageMaterial(item)) then return false end

    local thread = CSR_Utils.findPreferredThread(player)
    local needle = CSR_Utils.findPreferredNeedle(player)
    local option = context:addOption(getText("ContextMenu_CSR_MakeBandage"), items, CSR_ContextMenu.onMakeBandage, player, item)
    local lines = { "Turn this material into a proper bandage.", "Requires: needle + thread" }
    if thread then
        local threadPct = CSR_Utils.getDrainableInsight(thread)
        if threadPct then lines[#lines + 1] = "Thread remaining: " .. threadPct .. "%" end
    else
        lines[#lines + 1] = "Missing thread!"
    end
    if needle and needle.getCondition then
        local maxCondition = (needle.getConditionMax and needle:getConditionMax()) or needle:getCondition()
        lines[#lines + 1] = string.format("Needle condition: %d%%", math.floor((needle:getCondition() / math.max(1, maxCondition)) * 100))
    elseif not needle then
        lines[#lines + 1] = "Missing needle!"
    end
    if not isItemInCharacterInventory(item, player) then
        lines[#lines + 1] = "Will loot the material first, then craft the bandage."
    end
    setTooltip(option, lines)
    if not thread or not needle then option.notAvailable = true end
    return true
end

local function addEquipmentOptions(player, context, items, item, singleSelection)
    if not (singleSelection and CSR_FeatureFlags.isEquipmentQoLEnabled()) then return end

    if CSR_Utils.canRechargeFlashlight(item) and CSR_Utils.hasBattery(player) then
        local option = context:addOption(getText("ContextMenu_CSR_ReplaceBattery"), items, CSR_ContextMenu.onReplaceBattery, player, item)
        local pct = CSR_Utils.getDrainableInsight(item)
        setTooltip(option, { "Replace the battery in this flashlight.", pct and ("Current charge: " .. pct .. "%") or "Current charge unknown" })
    end

    if CSR_Utils.isRefillableLighter(item) then
        local pct = CSR_Utils.getDrainableInsight(item)
        local hasFluid = CSR_Utils.hasLighterFluid(player) ~= nil
        local isFull = item.getDelta and item:getDelta() >= 1.0
        local option = context:addOption(getText("ContextMenu_CSR_RefillLighter"), items, CSR_ContextMenu.onRefillLighter, player, item)
        if isFull then
            option.notAvailable = true
            setTooltip(option, { "This lighter is already full.", pct and ("Current fuel: " .. pct .. "%") or nil })
        elseif not hasFluid then
            option.notAvailable = true
            setTooltip(option, {
                "Refill this lighter using a Lighter Fluid can.",
                "You don't have any Lighter Fluid in your inventory.",
                pct and ("Current fuel: " .. pct .. "%") or nil,
            })
        else
            setTooltip(option, {
                "Refill this lighter using the most depleted lighter fluid first.",
                pct and ("Current fuel: " .. pct .. "%") or "Current fuel unknown",
            })
        end
    end
end

local function collectAmmoLogWatchOptions(player, context, items, item, singleSelection, state)
    if item and item.getFullType and item:getFullType() == "Base.Log" then
        table.insert(state.logItems, item)
    end

    if CSR_DismantleAllWatchesAction and CSR_DismantleAllWatchesAction.isWatchItem and CSR_DismantleAllWatchesAction.isWatchItem(item) then
        table.insert(state.watchItems, item)
    end

    if not CSR_FeatureFlags.isAlternateCanOpeningEnabled() then return end

    if CSR_Utils.isAmmoBox(item) then
        local info = CSR_Utils.getAmmoBoxInfo(item)
        local groupKey = item:getFullType()
        if not state.ammoBoxGroups[groupKey] then
            state.ammoBoxGroups[groupKey] = { items = {} }
        end
        if info then table.insert(state.ammoBoxGroups[groupKey].items, item) end
        if singleSelection and info then
            local option = context:addOption(getText("ContextMenu_CSR_OpenAmmoBox"), items, CSR_ContextMenu.onOpenAmmoBox, player, item)
            local roundName = getDisplayNameForType(info.round) or info.round
            setTooltip(option, { "Open box and dump rounds into inventory.", info.count .. "x " .. roundName })
        end
    elseif CSR_Utils.isAmmoRound(item) then
        local roundInfo = CSR_Utils.getAmmoRoundInfo(item)
        local roundType = item:getFullType()
        if roundInfo then
            if not state.ammoRoundGroups[roundType] then
                state.ammoRoundGroups[roundType] = { count = 0, boxType = roundInfo.box, perBox = roundInfo.count }
            end
            state.ammoRoundGroups[roundType].count = state.ammoRoundGroups[roundType].count + 1
        end
    end
end

local function collectInventoryItemOptions(playerNum, player, context, items, inventoryItems, state)
    local singleSelection = #inventoryItems == 1
    for _, item in ipairs(inventoryItems) do
        if singleSelection then
            addClipboardInventoryOptions(player, context, items, item)
        end
        collectJarOptions(player, context, items, item, singleSelection, state)
        collectCanOptions(playerNum, player, context, items, item, singleSelection, state)
        addRepairOptions(player, context, items, item, singleSelection)
        addClothingRepairOptions(player, context, items, item, singleSelection)
        collectTearOptions(player, context, items, item, singleSelection, state)
        if not state.bandageOptionAdded and addBandageOption(player, context, items, item) then
            state.bandageOptionAdded = true
        end
        addEquipmentOptions(player, context, items, item, singleSelection)
        collectAmmoLogWatchOptions(player, context, items, item, singleSelection, state)
    end
end

local function fillTearGroupFromSelectedContainer(player, inventoryItems, state)
    if #inventoryItems ~= 1 or not inventoryItems[1] or not isTearAllCandidate(inventoryItems[1], player) then return end

    local selected = inventoryItems[1]
    local clothType = selected.getFullType and selected:getFullType() or nil
    local container = selected.getContainer and selected:getContainer() or nil
    local group = clothType and state.clothGroups[clothType] or nil
    local containerItems = container and container.getItems and container:getItems() or nil
    if not group or not containerItems then return end

    for i = 0, containerItems:size() - 1 do
        local candidate = containerItems:get(i)
        if candidate
            and candidate.getFullType
            and candidate:getFullType() == clothType
            and isTearAllCandidate(candidate, player) then
            addUniqueItem(group.items, group.seenIds, candidate)
        end
    end
end

local function addBulkOpenOptions(player, context, items, state)
    if not CSR_FeatureFlags.isAlternateCanOpeningEnabled() then return end

    if CSR_Utils.hasKnife(player) or CSR_Utils.hasScrewdriver(player) then
        for _, group in pairs(state.canGroups) do
            if #group.items >= 2 then
                local count = #group.items
                local resultName = group.resultType and getDisplayNameForType(group.resultType) or getDisplayNameForType(group.sourceType)
                local text = string.format("Open All: %d x %s", count, resultName)
                local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onOpenAllCans, player, group.items, text)
                option.toolTip = createTooltip(string.format("Open %d selected cans that become %s.", count, resultName))
            end
        end
    end

    for _, group in pairs(state.jarGroups) do
        if #group.items >= 2 then
            local count = #group.items
            local resultName = group.resultType and getDisplayNameForType(group.resultType) or getDisplayNameForType(group.sourceType)
            local text = string.format("Open All Jars: %d x %s", count, resultName)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onOpenAllJars, player, group.items, text)
            option.toolTip = createTooltip(string.format("Open %d selected jars and keep their lids.", count))
        end
    end

    for _, group in pairs(state.ammoBoxGroups) do
        if #group.items >= 2 then
            local count = #group.items
            local boxName = getDisplayNameForType(group.items[1]:getFullType())
            local text = string.format("Open All: %d x %s", count, boxName)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onOpenAllAmmoBoxes, player, group.items, text)
            option.toolTip = createTooltip(string.format("Dump rounds from %d ammo boxes into your inventory.", count))
        end
    end
end

local function addAmmoPackingOptions(player, context, items, state)
    if not CSR_FeatureFlags.isAlternateCanOpeningEnabled() then return end

    for roundType, group in pairs(state.ammoRoundGroups) do
        local totalInInventory = CSR_Utils.countAmmoRoundsOfType(player, roundType)
        local boxesToMake = math.floor(totalInInventory / group.perBox)
        if boxesToMake >= 1 then
            local roundName = getDisplayNameForType(roundType) or roundType
            local boxName = getDisplayNameForType(group.boxType) or group.boxType
            if boxesToMake == 1 then
                local text = string.format("Pack Ammo Box: %s", boxName)
                local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onPackAmmoBox, player, roundType, group.boxType, group.perBox)
                option.toolTip = createTooltip(string.format("Pack %d x %s into a %s.\n%d rounds available.", group.perBox, roundName, boxName, totalInInventory))
            else
                local text = string.format("Pack All: %d x %s", boxesToMake, boxName)
                local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onPackAllAmmoBoxes, player, roundType, group.boxType, group.perBox, text)
                option.toolTip = createTooltip(string.format("Pack %d rounds into %d boxes of %s.\n%d rounds available.", boxesToMake * group.perBox, boxesToMake, boxName, totalInInventory))
            end
        end
    end
end

local function addSelectedMixedTearOption(player, context, items, state)
    local selectedItems = state.selectedTearItems or {}
    local selectedCount = #selectedItems
    if selectedCount < 2 then return end

    local firstType = nil
    local hasMultipleTypes = false
    for _, item in ipairs(selectedItems) do
        local itemType = item and item.getFullType and item:getFullType() or nil
        if not firstType then
            firstType = itemType
        elseif itemType ~= firstType then
            hasMultipleTypes = true
            break
        end
    end

    local sameTypeGroup = firstType and state.clothGroups[firstType] or nil
    if not hasMultipleTypes and sameTypeGroup and #sameTypeGroup.items == selectedCount then
        return
    end

    local text = string.format("Tear Selected Clothing: %d", selectedCount)
    local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onTearAllCloth, player, selectedItems, text)
    if state.clothCuttingTool and state.clothCuttingTool.getTexture then
        option.iconTexture = state.clothCuttingTool:getTexture()
    end

    local lines = { string.format("Tear %d selected clothing items into usable material.", selectedCount) }
    for _, item in ipairs(selectedItems) do
        if not isItemInCharacterInventory(item, player) then
            lines[#lines + 1] = "Will loot selected items first, then tear them."
            break
        end
    end
    if tearGroupNeedsMissingTool({ items = selectedItems }, state.clothCuttingTool) then
        option.notAvailable = true
        lines[#lines + 1] = "Need scissors or a sharp knife."
    end
    option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
end

local function addBulkTearOptions(player, context, items, state)
    for clothType, group in pairs(state.clothGroups) do
        if #group.items >= 2 then
            local count = #group.items
            local clothName = getDisplayNameForType(clothType)
            local text = string.format("Tear All: %d x %s", count, clothName)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onTearAllCloth, player, group.items, text)
            local sample = group.items[1]
            local tearInfo = sample and CSR_Utils.getTearClothInfo(sample) or nil
            local outputName = tearInfo and getDisplayNameForType(tearInfo.outputType) or "usable material"
            local lines = { string.format("Tear %d selected %s items into %s.", count, clothName, outputName) }
            for _, item in ipairs(group.items) do
                if not isItemInCharacterInventory(item, player) then
                    lines[#lines + 1] = "Will loot selected items first, then tear them."
                    break
                end
            end
            option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
            if tearGroupNeedsMissingTool(group, state.clothCuttingTool) then
                option.notAvailable = true
                lines[#lines + 1] = "Need scissors or a sharp knife."
                option.toolTip = createTooltip(table.concat(lines, " <LINE>"))
            end
        end
    end
end

local function collectTearableFromContainer(container, player, seenIds, output, visited)
    if not container or visited[container] then return end
    visited[container] = true

    local containerItems = container.getItems and container:getItems() or nil
    if not containerItems then return end

    for ii = 0, containerItems:size() - 1 do
        local it = containerItems:get(ii)
        if isTearAllCandidate(it, player) then
            local key = getItemIdKey(it)
            if not key or not seenIds[key] then
                if key then seenIds[key] = true end
                output[#output + 1] = it
            end
        end

        local subInv = it and it.getInventory and it:getInventory() or nil
        if subInv then
            collectTearableFromContainer(subInv, player, seenIds, output, visited)
        end
    end
end

local function addNearbyTearAllOption(player, context, items, state)
    if CSR_FeatureFlags.isTearAllNearbyClothingEnabled
        and not CSR_FeatureFlags.isTearAllNearbyClothingEnabled() then
        return
    end
    if not (ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers) then return end

    local nearbyTearable = {}
    local seenIds = {}
    for _, group in pairs(state.clothGroups) do
        for _, it in ipairs(group.items) do
            local key = getItemIdKey(it)
            if key then seenIds[key] = true end
        end
    end

    local containers = ISInventoryPaneContextMenu.getContainers(player)
    if containers then
        for ci = 0, containers:size() - 1 do
            local container = containers:get(ci)
            if container and not isContainerInCharacterInventory(container, player) then
                collectTearableFromContainer(container, player, seenIds, nearbyTearable, {})
            end
        end
    end

    if #nearbyTearable < 2 then return end

    local text = string.format("Tear All Nearby Clothing: %d", #nearbyTearable)
    local opt = context:addOptionOnTop(text, items, CSR_ContextMenu.onTearAllCloth, player, nearbyTearable, text)
    if state.clothCuttingTool and state.clothCuttingTool.getTexture then
        opt.iconTexture = state.clothCuttingTool:getTexture()
    end
    opt.toolTip = createTooltip(string.format(
        "Tear %d clothing items from nearby loot containers (corpses, floor, vehicle storage). <LINE> Items will be looted first, then torn.",
        #nearbyTearable))
    if tearGroupNeedsMissingTool({ items = nearbyTearable }, state.clothCuttingTool) then
        opt.notAvailable = true
        opt.toolTip.description = opt.toolTip.description .. " <LINE> Need scissors or a sharp knife."
    end
end

local function addLogAndWatchBulkOptions(player, context, items, state)
    if #state.logItems >= 2 then
        local saw = CSR_Utils.findSaw(player)
        if saw then
            local count = #state.logItems
            local text = string.format("Saw All Logs: %d", count)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onSawAllLogs, player, state.logItems, saw, text)
            option.iconTexture = saw:getTexture()
            option.toolTip = createTooltip(string.format("Saw %d logs into %d planks. Grants carpentry XP.", count, count * 3))
        end
    end

    if CSR_FeatureFlags.isDismantleAllWatchesEnabled() and #state.watchItems >= 2 then
        local screwdriver = CSR_Utils.hasScrewdriver(player)
        if screwdriver then
            local count = #state.watchItems
            local text = string.format("Dismantle All Watches: %d", count)
            local option = context:addOptionOnTop(text, items, CSR_ContextMenu.onDismantleAllWatches, player, state.watchItems, screwdriver, text)
            option.iconTexture = screwdriver:getTexture()
            option.toolTip = createTooltip(string.format("Dismantle %d watches into electronics scrap. Grants electrical XP.", count))
        end
    end
end

function CSR_ContextMenu.addInventoryOptions(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local inventoryItems = CSR_Utils.resolveInventorySelection(items)
    local state = {
        canGroups = {},
        jarGroups = {},
        clothGroups = {},
        selectedTearItems = {},
        selectedTearSeenIds = {},
        logItems = {},
        watchItems = {},
        ammoBoxGroups = {},
        ammoRoundGroups = {},
        bandageOptionAdded = false,
        clothCuttingTool = CSR_Utils.findClothCuttingTool(player),
    }

    addDropSelectedOption(playerNum, context, inventoryItems)
    addBinksScooperOption(player, context, items, inventoryItems)
    collectInventoryItemOptions(playerNum, player, context, items, inventoryItems, state)
    fillTearGroupFromSelectedContainer(player, inventoryItems, state)
    addBulkOpenOptions(player, context, items, state)
    addAmmoPackingOptions(player, context, items, state)
    addSelectedMixedTearOption(player, context, items, state)
    addBulkTearOptions(player, context, items, state)
    addNearbyTearAllOption(player, context, items, state)
    addLogAndWatchBulkOptions(player, context, items, state)
end

function CSR_ContextMenu.onOpenJar(items, player, item)
    if CSR_OpenJarAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_OpenJarAction:new(player, item)
        end)
    end
end

function CSR_ContextMenu.onIgniteCorpse(worldobjects, player, corpse, ignition)
    local selectedIgnition = ignition or CSR_Utils.findPreferredIgnitionSource(player)
    if CSR_IgniteCorpseAction and selectedIgnition and corpse then
        local square = corpse.getSquare and corpse:getSquare() or nil
        if square then
            local diffX = math.abs(square:getX() + 0.5 - player:getX())
            local diffY = math.abs(square:getY() + 0.5 - player:getY())
            if diffX > 2.5 or diffY > 2.5 then
                ISTimedActionQueue.clear(player)
                local adj = AdjacentFreeTileFinder.Find(square, player)
                if adj then
                    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, adj))
                else
                    return
                end
            end
            ISTimedActionQueue.add(CSR_IgniteCorpseAction:new(player, corpse, selectedIgnition))
        end
    end
end

function CSR_ContextMenu.onBarricadeWindow(worldobjects, player, window, plank)
    local selectedPlank = plank or CSR_Utils.findPreferredPlank(player)
    if CSR_BarricadeAction and selectedPlank then
        queueActionAfterTransfers(player, { selectedPlank }, function()
            return CSR_BarricadeAction:new(player, window, selectedPlank)
        end)
    end
end

function CSR_ContextMenu.onOpenClipboard(items, player, item)
    if CSR_Clipboard and CSR_Clipboard.show then
        CSR_Clipboard.show(player, item, false)
    end
end

function CSR_ContextMenu.onClipboardAddPaper(items, player, item)
    if CSR_Clipboard and CSR_Clipboard.addPaper then
        CSR_Clipboard.addPaper(player, item)
    end
end

function CSR_ContextMenu.onClipboardRemovePaper(items, player, item)
    if CSR_Clipboard and CSR_Clipboard.removePaper then
        CSR_Clipboard.removePaper(player, item)
    end
end

function CSR_ContextMenu.onOpenCan(items, player, item, toolName)
    local tool = getCanOpeningTool(player, toolName)
    if tool and CSR_OpenCanAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_OpenCanAction:new(player, item, tool)
        end)
    end
end

function CSR_ContextMenu.onBinksScoopDung(items, player, scooper, targets, radius, maxPer)
    if not CSR_ScoopDungAction or not scooper or not targets or #targets == 0 then
        return
    end
    -- Re-scan now in case the player moved or items dropped between menu open and click.
    local fresh = CSR_ScoopDungAction.findDungInRadius(player, radius or 3)
    if #fresh == 0 then return end
    queueActionAfterTransfers(player, { scooper }, function()
        return CSR_ScoopDungAction:new(player, scooper, fresh, radius, maxPer)
    end)
end

function CSR_ContextMenu.onRepairItem(items, player, item, tool)
    if CSR_RepairAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_RepairAction:new(player, item, tool)
        end)
    end
end

function CSR_ContextMenu.onRepairTool(items, player, item, torch, scrap, plank)
    torch = torch or CSR_Utils.findPreferredPropaneTorch(player, CSR_Utils.getToolRepairTorchFuelCost())
    scrap = scrap or CSR_Utils.findPreferredScrapMetal(player)
    plank = plank or CSR_Utils.findPreferredPlank(player)
    if CSR_ToolRepairAction and item and torch and scrap and plank then
        queueActionAfterTransfers(player, { item, torch, scrap, plank }, function()
            return CSR_ToolRepairAction:new(player, item, torch, scrap, plank)
        end)
    end
end

function CSR_ContextMenu.onOpenGarmentUI(items, player, item)
    if not item or not CSR_Utils.canTailorClothing(item) then
        return
    end
    ISInventoryPaneContextMenu.onInspectClothingUI(player, item)
end

function CSR_ContextMenu.onPatchClothing(items, player, item)
    local thread = CSR_Utils.findPreferredThread(player)
    local needle = CSR_Utils.findPreferredNeedle(player)
    local fabric = CSR_Utils.findPreferredFabricMaterial(player)
    if CSR_PatchClothingAction and thread and needle and fabric then
        queueActionAfterTransfers(player, { item, thread, needle, fabric }, function()
            return CSR_PatchClothingAction:new(player, item, thread, needle, fabric)
        end)
    end
end

function CSR_ContextMenu.onRepairAllClothing(items, player)
    local thread = CSR_Utils.findPreferredThread(player)
    local needle = CSR_Utils.findPreferredNeedle(player)
    local fabric = CSR_Utils.findPreferredFabricMaterial(player)
    if CSR_RepairAllClothingAction and thread and needle and fabric then
        queueActionAfterTransfers(player, { thread, needle, fabric }, function()
            return CSR_RepairAllClothingAction:new(player, thread, needle, fabric)
        end)
    end
end

function CSR_ContextMenu.onTearCloth(items, player, item)
    if CSR_TearClothAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_TearClothAction:new(player, item, CSR_Utils.findClothCuttingTool(player))
        end)
    end
end

function CSR_ContextMenu.onMakeBandage(items, player, item)
    local thread = CSR_Utils.findPreferredThread(player)
    local needle = CSR_Utils.findPreferredNeedle(player)
    if CSR_MakeBandageAction and thread and needle then
        queueActionAfterTransfers(player, { item, thread, needle }, function()
            return CSR_MakeBandageAction:new(player, item, thread, needle)
        end)
    end
end

function CSR_ContextMenu.onOpenAllCans(items, player, groupedItems, label)
    local tool = CSR_Utils.hasKnife(player) or CSR_Utils.hasScrewdriver(player)
    if tool and CSR_OpenAllCansAction then
        queueActionAfterTransfers(player, groupedItems, function()
            return CSR_OpenAllCansAction:new(player, groupedItems, tool, label)
        end)
    end
end

function CSR_ContextMenu.onOpenAllJars(items, player, groupedItems, label)
    if CSR_OpenAllJarsAction then
        queueActionAfterTransfers(player, groupedItems, function()
            return CSR_OpenAllJarsAction:new(player, groupedItems, label)
        end)
    end
end

function CSR_ContextMenu.onOpenAmmoBox(items, player, box)
    if CSR_OpenAmmoBoxAction then
        queueActionAfterTransfers(player, { box }, function()
            return CSR_OpenAmmoBoxAction:new(player, box)
        end)
    end
end

function CSR_ContextMenu.onOpenAllAmmoBoxes(items, player, groupedItems, label)
    if CSR_OpenAllAmmoBoxesAction then
        queueActionAfterTransfers(player, groupedItems, function()
            return CSR_OpenAllAmmoBoxesAction:new(player, groupedItems, label)
        end)
    end
end

function CSR_ContextMenu.onPackAmmoBox(items, player, roundType, boxType, perBox)
    if CSR_PackAmmoBoxAction then
        ISTimedActionQueue.add(CSR_PackAmmoBoxAction:new(player, roundType, boxType, perBox))
    end
end

function CSR_ContextMenu.onPackAllAmmoBoxes(items, player, roundType, boxType, perBox, label)
    if CSR_PackAllAmmoBoxesAction then
        ISTimedActionQueue.add(CSR_PackAllAmmoBoxesAction:new(player, roundType, boxType, perBox, label))
    end
end

function CSR_ContextMenu.onTearAllCloth(items, player, groupedItems, label)
    if CSR_TearAllClothAction then
        queueActionAfterTransfers(player, groupedItems, function()
            return CSR_TearAllClothAction:new(player, groupedItems, label, CSR_Utils.findClothCuttingTool(player))
        end)
    end
end

function CSR_ContextMenu.onSawAllLogs(items, player, logItems, saw, label)
    if CSR_SawAllLogsAction then
        queueActionAfterTransfers(player, logItems, function()
            return CSR_SawAllLogsAction:new(player, logItems, saw, label)
        end)
    end
end

function CSR_ContextMenu.onDismantleAllWatches(items, player, watchItems, screwdriver, label)
    if CSR_DismantleAllWatchesAction then
        queueActionAfterTransfers(player, watchItems, function()
            return CSR_DismantleAllWatchesAction:new(player, watchItems, screwdriver, label)
        end)
    end
end

function CSR_ContextMenu.onDuctTapeRepair(items, player, item)
    local tape = CSR_Utils.findPreferredDuctTape(player)
    if tape and CSR_DuctTapeRepairAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_DuctTapeRepairAction:new(player, item, tape)
        end)
    end
end

function CSR_ContextMenu.onGlueRepair(items, player, item)
    local glue = CSR_Utils.findPreferredGlue(player)
    if glue and CSR_GlueRepairAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_GlueRepairAction:new(player, item, glue)
        end)
    end
end

function CSR_ContextMenu.onTapeRepair(items, player, item)
    local tape = CSR_Utils.findPreferredTape(player)
    if tape and CSR_TapeRepairAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_TapeRepairAction:new(player, item, tape)
        end)
    end
end

function CSR_ContextMenu.onReplaceBattery(items, player, item)
    local battery = player:getInventory():FindAndReturn("Battery")
    if battery and CSR_ReplaceBatteriesAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_ReplaceBatteriesAction:new(player, item, battery)
        end)
    end
end

function CSR_ContextMenu.onRefillLighter(items, player, item)
    local fluid = CSR_Utils.findPreferredLighterFluid(player)
    if fluid and CSR_RefillLighterAction then
        queueActionAfterTransfers(player, { item }, function()
            return CSR_RefillLighterAction:new(player, item, fluid)
        end)
    end
end

if Events and Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(CSR_ContextMenu.addWorldObjectOptions)
end

if Events and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(CSR_ContextMenu.addInventoryOptions)
end

local function hookVehiclePryRadial()
    if not ISVehicleMenu or not ISVehicleMenu.showRadialMenuOutside or ISVehicleMenu.__csr_pry_radial then
        return
    end
    ISVehicleMenu.__csr_pry_radial = true
    local originalShowRadialMenuOutside = ISVehicleMenu.showRadialMenuOutside
    ISVehicleMenu.showRadialMenuOutside = function(playerObj, ...)
        originalShowRadialMenuOutside(playerObj, ...)

        if not playerObj then return end

        local vehicle = ISVehicleMenu.getVehicleToInteractWith and ISVehicleMenu.getVehicleToInteractWith(playerObj) or nil
        if not vehicle then return end

        local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
        if not menu then return end

        local canPry = CSR_FeatureFlags.isVehicleDoorPryEnabled()
        local canLockpick = CSR_FeatureFlags.isLockpickEnabled()
        if not canPry and not canLockpick then return end

        local crowbar = CSR_Utils.hasCrowbar(playerObj)
        if canPry and crowbar then
            local pryPart = findVehicleActionPart(playerObj, vehicle, CSR_Utils.canPryVehiclePart)
            if pryPart then
                menu:addSlice(getText("ContextMenu_CSR_PryVehicleDoorRadial"),
                    crowbar:getTexture(), function()
                        if CSR_PryVehicleDoorAction then
                            ISTimedActionQueue.add(CSR_PryVehicleDoorAction:new(playerObj, vehicle, pryPart, crowbar))
                        end
                    end)
            end
        end

        local screwdriver = CSR_Utils.hasScrewdriver(playerObj)
        if canLockpick and screwdriver then
            local lockpickPart = findVehicleActionPart(playerObj, vehicle, CSR_Utils.canLockpickVehiclePart)
            if lockpickPart then
                menu:addSlice(getText("ContextMenu_CSR_PickVehicleDoor"),
                    screwdriver:getTexture(), function()
                        CSR_ContextMenu.onLockpickVehicleDoor(nil, playerObj, vehicle, lockpickPart, screwdriver)
                    end)
            end
        end
    end
end

local function hookVehicleEntryMenu()
    if not ISVehicleMenu or not ISVehicleMenu.FillMenuOutsideVehicle or ISVehicleMenu.__csr_vehicle_entry then
        return
    end
    ISVehicleMenu.__csr_vehicle_entry = true
    local originalFillMenuOutsideVehicle = ISVehicleMenu.FillMenuOutsideVehicle
    ISVehicleMenu.FillMenuOutsideVehicle = function(playerNum, context, vehicle, test)
        local result = originalFillMenuOutsideVehicle(playerNum, context, vehicle, test)
        if not test and context and vehicle then
            local player = getSpecificPlayer(playerNum)
            if player then
                addVehicleEntryOptions(context, { vehicle }, player, vehicle)
            end
        end
        return result
    end
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(hookVehiclePryRadial)
    Events.OnGameStart.Add(hookVehicleEntryMenu)
end
