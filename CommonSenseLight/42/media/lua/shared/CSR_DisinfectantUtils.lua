CSR_DisinfectantUtils = CSR_DisinfectantUtils or {}

local TIER1_MIN_VOLUME = 0.15
local TIER1_MIN_RATIO = 0.40
local TIER2_MIN_VOLUME = 0.05
local TIER2_MIN_RATIO = 0.60
local DRAINABLE_MIN_POWER = 4.0

CSR_DisinfectantUtils.RAG_DRAIN_AMOUNT = 0.10
CSR_DisinfectantUtils.WOUND_DRAIN_AMOUNT = 0.15

local BANDAGE_SWAP = {
    ["Base.Bandage"] = "Base.AlcoholBandage",
    ["Base.RippedSheets"] = "Base.AlcoholRippedSheets",
}

local function smallBottlesAllowed()
    if CSR_FeatureFlags and CSR_FeatureFlags.isPerfumeAsDisinfectantEnabled then
        return CSR_FeatureFlags.isPerfumeAsDisinfectantEnabled()
    end
    return true
end

local function getFluidContainer(item)
    if not item or not item.hasComponent or not ComponentType then return nil end
    if not item:hasComponent(ComponentType.FluidContainer) then return nil end
    return item.getFluidContainer and item:getFluidContainer() or nil
end

function CSR_DisinfectantUtils.getFluidInfo(item)
    local fc = getFluidContainer(item)
    if not fc or not fc.getAmount or not fc.getProperties then return nil end

    local amount = tonumber(fc:getAmount()) or 0
    local props = fc:getProperties()
    local alcohol = props and props.getAlcohol and (tonumber(props:getAlcohol()) or 0) or 0
    local ratio = 0
    if amount > 0 then
        ratio = alcohol / (amount + 0.001)
    end

    return {
        container = fc,
        amount = amount,
        alcohol = alcohol,
        ratio = ratio,
    }
end

function CSR_DisinfectantUtils.isDisinfectant(item)
    if not item then return false end

    local fluid = CSR_DisinfectantUtils.getFluidInfo(item)
    if fluid then
        if fluid.amount <= 0 then return false end
        if fluid.amount >= TIER1_MIN_VOLUME and fluid.ratio >= TIER1_MIN_RATIO then
            return true
        end
        return smallBottlesAllowed()
            and fluid.amount >= TIER2_MIN_VOLUME
            and fluid.ratio >= TIER2_MIN_RATIO
    end

    if item.IsDrainable and item:IsDrainable() then
        local power = item.getAlcoholPower and (tonumber(item:getAlcoholPower()) or 0) or 0
        return power >= DRAINABLE_MIN_POWER
    end

    return false
end

function CSR_DisinfectantUtils.getAlcoholPower(item)
    local fluid = CSR_DisinfectantUtils.getFluidInfo(item)
    if fluid and fluid.amount > 0 then
        return 4 * fluid.alcohol / fluid.amount
    end

    if item and item.IsDrainable and item:IsDrainable() and item.getAlcoholPower then
        return tonumber(item:getAlcoholPower()) or 0
    end

    return 0
end

function CSR_DisinfectantUtils.drainDisinfectant(item, requestedAmount)
    if not item then return false end

    local fluid = CSR_DisinfectantUtils.getFluidInfo(item)
    if fluid then
        if not fluid.container.adjustAmount then return false end
        if fluid.amount < TIER2_MIN_VOLUME then return false end
        local drain = math.min(tonumber(requestedAmount) or CSR_DisinfectantUtils.RAG_DRAIN_AMOUNT, fluid.amount)
        if drain <= 0 then return false end
        fluid.container:adjustAmount(math.max(0, fluid.amount - drain))
        if sendItemStats then sendItemStats(item) end
        return true
    end

    if item.IsDrainable and item:IsDrainable() then
        if item.UseAndSync then
            item:UseAndSync()
            return true
        end
        if item.Use then
            item:Use()
            return true
        end
    end

    return false
end

function CSR_DisinfectantUtils.getDisinfectedBandageType(fullType)
    return BANDAGE_SWAP[fullType]
end

function CSR_DisinfectantUtils.getWoundPriority(item)
    local fluid = CSR_DisinfectantUtils.getFluidInfo(item)
    if fluid and fluid.amount > 0 then
        return fluid.ratio * math.min(fluid.amount, 0.5)
    end
    if item and item.IsDrainable and item:IsDrainable() and item.getAlcoholPower then
        return (tonumber(item:getAlcoholPower()) or 0) * 0.05
    end
    return 0
end

function CSR_DisinfectantUtils.getRagPriority(item)
    local fluid = CSR_DisinfectantUtils.getFluidInfo(item)
    if fluid then
        return fluid.amount * 100 + fluid.alcohol
    end
    if item and item.getAlcoholPower then
        return 1000 + (tonumber(item:getAlcoholPower()) or 0)
    end
    return 1000
end

return CSR_DisinfectantUtils
