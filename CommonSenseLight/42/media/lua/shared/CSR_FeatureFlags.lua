CSR_FeatureFlags = {}

-- CommonSenseLight: stripped to only the features the user wants.
-- All disabled features permanently return false so their code paths never run.

local function sandbox()
    return SandboxVars and SandboxVars.CommonSenseLight or {}
end

-- ============================================================
-- ENTRY ACTIONS & LOCKPICK (kept)
-- ============================================================
function CSR_FeatureFlags.isEntryActionsEnabled()
    if CSR_PlayerPrefs then
        local override = CSR_PlayerPrefs.getOverride("EntryActions")
        if override ~= nil then return override end
    end
    return sandbox().EnableEntryActions ~= false
end

function CSR_FeatureFlags.isPryEnabled()
    return CSR_FeatureFlags.isEntryActionsEnabled() and sandbox().EnablePrySystem == true
end

function CSR_FeatureFlags.isLockpickEnabled()
    return CSR_FeatureFlags.isEntryActionsEnabled() and sandbox().EnableScrewdriverLockpick ~= false
end

function CSR_FeatureFlags.isAlternateCanOpeningEnabled()
    return sandbox().EnableAlternateCanOpening ~= false
end

function CSR_FeatureFlags.isVehicleDoorPryEnabled()
    return sandbox().EnableVehicleDoorPry ~= false and CSR_FeatureFlags.isPryEnabled()
end

function CSR_FeatureFlags.isGarageDoorPryEnabled()
    return sandbox().EnableGarageDoorPry ~= false and CSR_FeatureFlags.isPryEnabled()
end

function CSR_FeatureFlags.isSafeDoorPryEnabled()
    -- Changed default: was == true (off by default), now ~= false (on by default)
    return sandbox().EnableSafeDoorPry ~= false and CSR_FeatureFlags.isPryEnabled()
end

function CSR_FeatureFlags.isBoltCutterEnabled()
    return sandbox().EnableBoltCutter ~= false and CSR_FeatureFlags.isPryEnabled()
end

function CSR_FeatureFlags.isFenceCuttingEnabled()
    return sandbox().EnableFenceCutting ~= false and CSR_FeatureFlags.isBoltCutterEnabled()
end

function CSR_FeatureFlags.isImprovisedHotwireEnabled()
    return sandbox().EnableImprovisedHotwire ~= false
end

function CSR_FeatureFlags.isUnHotwireEnabled()
    return sandbox().EnableUnHotwire ~= false
end

-- ============================================================
-- WASHING / BATHING (kept)
-- ============================================================
function CSR_FeatureFlags.isWashMenuSplitEnabled()
    return sandbox().EnableWashMenuSplits ~= false
end

function CSR_FeatureFlags.isWashAllEnabled()
    return sandbox().EnableWashAll ~= false
end

function CSR_FeatureFlags.isJarCappingEnabled()
    return sandbox().EnableJarCapping ~= false
end

function CSR_FeatureFlags.isHomeCanningEnabled()
    return sandbox().EnableHomeCanning ~= false
end

function CSR_FeatureFlags.isTowelDryingEnabled()
    return sandbox().EnableTowelDrying ~= false
end

function CSR_FeatureFlags.isBathingEnabled()
    return sandbox().EnableBathing ~= false
end

-- ============================================================
-- GAMEPLAY QoL (kept)
-- ============================================================
function CSR_FeatureFlags.isWalkingActionsEnabled()
    if CSR_PlayerPrefs then
        local override = CSR_PlayerPrefs.getOverride("WalkingItemActions")
        if override ~= nil then return override end
    end
    return sandbox().EnableWalkingItemActions ~= false
end

function CSR_FeatureFlags.isEatAllStackEnabled()
    if CSR_PlayerPrefs then
        local override = CSR_PlayerPrefs.getOverride("EatAllStack")
        if override ~= nil then return override end
    end
    return sandbox().EnableEatAllStack ~= false
end

function CSR_FeatureFlags.isHideWatermarkEnabled()
    if CSR_PlayerPrefs then
        local override = CSR_PlayerPrefs.getOverride("HideWatermark")
        if override ~= nil then return override end
    end
    return sandbox().EnableHideWatermark ~= false
end

function CSR_FeatureFlags.isCSRRadialMenuEnabled()
    return sandbox().EnableCSRRadialMenu ~= false
end

function CSR_FeatureFlags.isMagazineBatchActionsEnabled()
    return sandbox().EnableMagazineBatchActions ~= false
end

function CSR_FeatureFlags.isKnowledgeSharingEnabled()
    return sandbox().EnableKnowledgeSharing ~= false
end

function CSR_FeatureFlags.isSweepTrashEnabled()
    return sandbox().EnableSweepTrash ~= false
end

function CSR_FeatureFlags.isSweepAshesEnabled()
    return sandbox().EnableSweepAshes ~= false
end

function CSR_FeatureFlags.isBinksScooperEnabled()
    return sandbox().EnableSweepTrash ~= false
end

function CSR_FeatureFlags.getBinksScooperRadius()
    local v = sandbox().BinksScooperRadius
    if type(v) ~= "number" then return 3 end
    if v < 1 then return 1 end
    if v > 6 then return 6 end
    return v
end

function CSR_FeatureFlags.getBinksScooperMaxPerAction()
    local v = sandbox().BinksScooperMaxPerAction
    if type(v) ~= "number" then return 30 end
    if v < 10 then return 10 end
    if v > 60 then return 60 end
    return v
end

function CSR_FeatureFlags.isCorpseIgniteEnabled()
    return sandbox().EnableCorpseIgnite ~= false
end

function CSR_FeatureFlags.isDismantleAllWatchesEnabled()
    return sandbox().EnableDismantleAllWatches ~= false
end

function CSR_FeatureFlags.isPerfumeAsDisinfectantEnabled()
    return sandbox().EnablePerfumeAsDisinfectant ~= false
end

function CSR_FeatureFlags.isWarmUpEnabled()
    return sandbox().EnableWarmUp ~= false
end

function CSR_FeatureFlags.isStopDropRollEnabled()
    return sandbox().EnableStopDropRoll ~= false
end

function CSR_FeatureFlags.isRainCleanseEnabled()
    return sandbox().EnableRainCleanse ~= false
end

function CSR_FeatureFlags.isRainCleanseExteriorsEnabled()
    return sandbox().EnableRainCleanseExteriors ~= false
end

-- ============================================================
-- COMBAT / FIREARMS (kept)
-- ============================================================
function CSR_FeatureFlags.isPointBlankEnabled()
    return sandbox().EnablePointBlank ~= false
end

function CSR_FeatureFlags.isBulletPenetrationEnabled()
    return sandbox().EnableBulletPenetration ~= false
end

function CSR_FeatureFlags.isReloadAllMagsEnabled()
    return sandbox().EnableReloadAllMags ~= false
end

function CSR_FeatureFlags.isSeatedReloadBonusEnabled()
    return sandbox().EnableSeatedReloadBonus ~= false
end

-- ============================================================
-- VEHICLES (kept)
-- ============================================================
function CSR_FeatureFlags.isVehicleSalvageEnabled()
    return sandbox().EnableVehicleSalvage ~= false
end

-- ============================================================
-- CLIMBING / MOBILITY (kept)
-- ============================================================
function CSR_FeatureFlags.isLadderClimbEnabled()
    return sandbox().EnableLadderClimb ~= false
end

function CSR_FeatureFlags.isClimbWithBagsEnabled()
    return sandbox().EnableClimbWithBags ~= false
end

function CSR_FeatureFlags.isClimbWithGeneratorEnabled()
    return sandbox().EnableClimbWithGenerator ~= false
end

function CSR_FeatureFlags.isGearSlingEnabled()
    return sandbox().EnableGearSling ~= false
end

-- ============================================================
-- SAW ALL (kept) — default changed to enabled
-- ============================================================
function CSR_FeatureFlags.isSawAllDropToGroundEnabled()
    -- Changed default: was == true (off), now ~= false (on by default)
    return sandbox().EnableSawAllDropToGround ~= false
end

-- ============================================================
-- SERVER / MP (kept)
-- ============================================================
function CSR_FeatureFlags.isSurvivorBondEnabled()
    return sandbox().EnableSurvivorBond ~= false
end

function CSR_FeatureFlags.isRVExitRescueEnabled()
    return sandbox().EnableRVExitRescue ~= false
end

-- ============================================================
-- MOD INTEROP (needed for safe coexistence)
-- ============================================================
function CSR_FeatureFlags.isCleanHotBarActive()
    return getActivatedMods and getActivatedMods():contains("CleanHotBar") or false
end

function CSR_FeatureFlags.isCleanUIActive()
    return getActivatedMods and getActivatedMods():contains("CleanUI") or false
end

function CSR_FeatureFlags.isWayMoreCarsActive()
    return getActivatedMods and getActivatedMods():contains("WayMoreCars") or false
end

function CSR_FeatureFlags.isClimbableVehiclesActive()
    return getActivatedMods and getActivatedMods():contains("ClimbableVehicles") or false
end

function CSR_FeatureFlags.isVehicleTrunkCraftModActive()
    return getActivatedMods and getActivatedMods():contains("VehicleTrunkCraftingSurface") or false
end

function CSR_FeatureFlags.isWearableSlotFixEnabled()
    return sandbox().EnableWearableSlotFix ~= false
end

function CSR_FeatureFlags.isAdminAuthoritative()
    return sandbox().AdminAuthoritativeControl == true
end

-- ============================================================
-- ALL REMOVED FEATURES — permanently disabled
-- ============================================================

local function disabled() return false end

CSR_FeatureFlags.isRepairEnabled                        = disabled
CSR_FeatureFlags.isRepairAllClothingEnabled             = disabled
CSR_FeatureFlags.isTearAllNearbyClothingEnabled         = disabled
CSR_FeatureFlags.isEquipmentQoLEnabled                  = disabled
CSR_FeatureFlags.isPlayerMapTrackingEnabled             = disabled
CSR_FeatureFlags.isSeatbeltEnabled                      = disabled
CSR_FeatureFlags.isVehicleMechanicsQoLEnabled           = disabled
CSR_FeatureFlags.isRouletteSessionEnabled               = disabled
CSR_FeatureFlags.isRouletteRealDeathEnabled             = disabled
CSR_FeatureFlags.isDashboardHighlightsEnabled           = disabled
CSR_FeatureFlags.isPourCanContentsEnabled               = disabled
CSR_FeatureFlags.isProximityLootHelperEnabled           = disabled
CSR_FeatureFlags.isZombieDensityOverlayEnabled          = disabled
CSR_FeatureFlags.isZombieDensityMinimapEnabled          = disabled
CSR_FeatureFlags.isCityStandpipesEnabled                = disabled
CSR_FeatureFlags.isUtilityHudEnabled                    = disabled
CSR_FeatureFlags.isPlayerTradingEnabled                 = disabled
CSR_FeatureFlags.isLootFilterEnabled                    = disabled
CSR_FeatureFlags.isItemInsightTooltipsEnabled           = disabled
CSR_FeatureFlags.isSmartVehicleKeyLabelsEnabled         = disabled
CSR_FeatureFlags.isQuickDeviceToggleEnabled             = disabled
CSR_FeatureFlags.isVisualSoundCuesEnabled               = disabled
CSR_FeatureFlags.isVehicleClockEnabled                  = disabled
CSR_FeatureFlags.isEatWhileDrivingEnabled               = disabled
CSR_FeatureFlags.getEatWhileDrivingMaxSpeed             = function() return 60 end
CSR_FeatureFlags.isMassageEnabled                       = disabled
CSR_FeatureFlags.isHideInFurnitureEnabled               = disabled
CSR_FeatureFlags.isClaimRespawnEnabled                  = disabled
CSR_FeatureFlags.isMultipleSafehouseEnabled             = disabled
CSR_FeatureFlags.isFireworkEnabled                      = disabled
CSR_FeatureFlags.isNoticeBoardEnabled                   = disabled
CSR_FeatureFlags.isDualWieldEnabled                     = disabled
CSR_FeatureFlags.toggleDualWieldLocal                   = function() return false end
CSR_FeatureFlags.isOffhandHudOverlayEnabled             = disabled
CSR_FeatureFlags.isOffhandPersistEnabled                = disabled
CSR_FeatureFlags.isAdvancedSoundOptionsEnabled          = disabled
CSR_FeatureFlags.isSleepAnywhereEnabled                 = disabled
CSR_FeatureFlags.isKnoxSyndicateEnabled                 = disabled
CSR_FeatureFlags.isKnoxSyndicateBroadcastEnabled        = disabled
CSR_FeatureFlags.isClipboardEnabled                     = disabled
CSR_FeatureFlags.isQuickSitEnabled                      = disabled
CSR_FeatureFlags.isWeaponHudOverlayEnabled              = disabled
CSR_FeatureFlags.isMaskHudEnabled                       = disabled
CSR_FeatureFlags.isStatusBarEnabled                     = disabled
CSR_FeatureFlags.isEquipmentPanelEnabled                = disabled
CSR_FeatureFlags.isBarrelCapFixEnabled                  = disabled
CSR_FeatureFlags.isLighterUsesEnabled                   = disabled
CSR_FeatureFlags.isHydrationSenseEnabled                = disabled
CSR_FeatureFlags.isDangerousThirstEnabled               = disabled
CSR_FeatureFlags.getHydrationSenseMode                  = function() return "auto" end
CSR_FeatureFlags.isRoofClimbEnabled                     = disabled
CSR_FeatureFlags.isVehicleWeatherExposureEnabled        = disabled
CSR_FeatureFlags.isVehicleHoodCraftEnabled              = disabled
CSR_FeatureFlags.isVehicleTrunkCraftEnabled             = disabled
CSR_FeatureFlags.isVehicleCraftSurfaceMasterEnabled     = disabled
CSR_FeatureFlags.isVehicleClaimEnabled                  = disabled
CSR_FeatureFlags.isCSRClaimsOverrideEnabled             = disabled
CSR_FeatureFlags.isClaimRaidEnabled                     = disabled
CSR_FeatureFlags.getClaimRaidStart                      = function() return 0 end
CSR_FeatureFlags.getClaimRaidEnd                        = function() return 0 end
CSR_FeatureFlags.isClaimRaidAllowBuild                  = disabled
CSR_FeatureFlags.isClaimRaidAllowLoot                   = disabled
CSR_FeatureFlags.isClaimContainerProtectEnabled         = disabled
CSR_FeatureFlags.isClaimPadlockEnabled                  = disabled
CSR_FeatureFlags.getClaimPadlockBreakSeconds            = function() return 180 end
CSR_FeatureFlags.isClaimAuditLogEnabled                 = disabled
CSR_FeatureFlags.isClaimInvitesEnabled                  = disabled
CSR_FeatureFlags.isClaimExpansionEnabled                = disabled
CSR_FeatureFlags.getClaimExpansionMaxWidth              = function() return 96 end
CSR_FeatureFlags.getClaimExpansionMaxHeight             = function() return 96 end
CSR_FeatureFlags.getClaimExpansionMaxAddedTiles         = function() return 1024 end
CSR_FeatureFlags.getClaimExpansionMoneyPer10Tiles       = function() return 1 end
CSR_FeatureFlags.getClaimExpansionMaterialsPer10Tiles   = function() return 2 end
CSR_FeatureFlags.isClaimExpansionArchitectRequired      = disabled
CSR_FeatureFlags.getClaimInviteCooldownMin              = function() return 1 end
CSR_FeatureFlags.getClaimDissolveAction                 = function() return "transfer" end
CSR_FeatureFlags.isClaimAdminsInvisible                 = disabled
CSR_FeatureFlags.isItemRenameEnabled                    = disabled
CSR_FeatureFlags.isVehicleHVACEnabled                   = disabled
CSR_FeatureFlags.isCharacterInfoEnhancementsEnabled     = disabled
CSR_FeatureFlags.isRoomScannerEnabled                   = disabled
CSR_FeatureFlags.isVehicleRadioEnabled                  = disabled
CSR_FeatureFlags.isFoodExpiryTooltipEnabled             = disabled
CSR_FeatureFlags.isSleepBenefitsEnabled                 = disabled
CSR_FeatureFlags.isBagBottomAttachEnabled               = disabled
CSR_FeatureFlags.isNestedContainersEnabled              = disabled
CSR_FeatureFlags.isLootBagEnabled                       = disabled
CSR_FeatureFlags.isLootBagAutoTrunkEnabled              = disabled
CSR_FeatureFlags.isToolSetEnabled                       = disabled
CSR_FeatureFlags.isMaterialBundlesEnabled               = disabled
CSR_FeatureFlags.isThrowableItemsEnabled                = disabled
CSR_FeatureFlags.isBack2SlotEnabled                     = disabled
CSR_FeatureFlags.isConeVisionOutlineEnabled             = disabled
CSR_FeatureFlags.isExerciseWithGearEnabled              = disabled
CSR_FeatureFlags.isInfectionResilienceEnabled           = disabled
CSR_FeatureFlags.isAntibodySystemEnabled                = disabled
CSR_FeatureFlags.isUsefulBarrelsEnabled                 = disabled
CSR_FeatureFlags.isFieldFiltersEnabled                  = disabled
CSR_FeatureFlags.isTowAssistEnabled                     = disabled
function CSR_FeatureFlags.isGeneratorInfoEnabled()
    return sandbox().EnableGeneratorInfo ~= false
end
CSR_FeatureFlags.isVideoInsertEnabled                   = disabled
CSR_FeatureFlags.isTVRadialEnabled                      = disabled
CSR_FeatureFlags.isReplaceVanillaSafehouseUIEnabled     = disabled
CSR_FeatureFlags.isVehicleClaimEnforcementStrictEnabled = disabled
CSR_FeatureFlags.isAnimatedDufflesEnabled               = disabled
CSR_FeatureFlags.isAimingAmmoCursorEnabled              = disabled
CSR_FeatureFlags.isAimingHealthCursorEnabled            = disabled
CSR_FeatureFlags.isAimingDensityCursorEnabled           = disabled
CSR_FeatureFlags.isRallyPointsEnabled                   = disabled
CSR_FeatureFlags.isRankingsEnabled                      = disabled
CSR_FeatureFlags.isRankingsTrackPvP                     = disabled
CSR_FeatureFlags.isColoredTogglesEnabled                = disabled
CSR_FeatureFlags.isSurvivorLedgerEnabled                = disabled
CSR_FeatureFlags.isSkillJournalEnabled                  = disabled
CSR_FeatureFlags.isFactionMemberLimitEnabled            = disabled
CSR_FeatureFlags.getMaxFactionMembers                   = function() return 8 end
CSR_FeatureFlags.isFactionSafehouseEnabled              = disabled
CSR_FeatureFlags.getMaxFactionSafehouses                = function() return 2 end
CSR_FeatureFlags.isFridgeToggleEnabled                  = disabled
CSR_FeatureFlags.isGroundMarkingEnabled                 = disabled
CSR_FeatureFlags.isTrunkSpillageEnabled                 = disabled
CSR_FeatureFlags.isFireTrailEnabled                     = disabled
CSR_FeatureFlags.isRopeTowEnabled                       = disabled

-- Legacy compat stub
CSR_FeatureFlags._dualWieldLocalOverride = nil

return CSR_FeatureFlags
