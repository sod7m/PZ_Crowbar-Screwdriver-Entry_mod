--[[
    CSR_SeatedReloadSpeed.lua (shared)

    Hooks ISReloadWeaponAction.setReloadSpeed to grant a 20% reload-speed
    bonus while the player is seated on furniture / on the ground.

    Vanilla precedent: vehicle drivers reload 20% slower (0.8x). This
    applies the inverse for seated players (1.2x).

    Gated by sandbox option `EnableSeatedReloadBonus`.
]]

require "TimedActions/ISReloadWeaponAction"
require "CSR_FeatureFlags"

local SEATED_RELOAD_MULTIPLIER = 1.20

local function isSeated(character)
    if not character then return false end
    if character.isSittingOnFurniture and character:isSittingOnFurniture() then return true end
    if character.isSitOnGround and character:isSitOnGround() then return true end
    local md = character.getModData and character:getModData() or nil
    return md and md.IsSittingOnSeat == true
end

if not _G.__CSR_SeatedReloadHooked then
    _G.__CSR_SeatedReloadHooked = true
    local _origSetReloadSpeed = ISReloadWeaponAction.setReloadSpeed
    ISReloadWeaponAction.setReloadSpeed = function(character, rack)
        _origSetReloadSpeed(character, rack)
        if not (CSR_FeatureFlags and CSR_FeatureFlags.isSeatedReloadBonusEnabled
                and CSR_FeatureFlags.isSeatedReloadBonusEnabled()) then
            return
        end
        if isSeated(character) then
            local current = character:getVariableFloat("ReloadSpeed", 1.0)
            character:setVariable("ReloadSpeed", current * SEATED_RELOAD_MULTIPLIER)
        end
    end
end
