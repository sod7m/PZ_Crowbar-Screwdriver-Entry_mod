require "CSR_FeatureFlags"

--[[
    CSR_WalkingActions
    ------------------
    Lets the player walk while performing certain timed actions
    (wear/unequip clothing, hand-craft, craft, read).

    HISTORY (cumulative)
    Original implementation wrapped each target class's `.new` constructor.
    That broke MP serialization for any other mod that extended a
    NetTimedAction subclass with extra named params, because Kahlua's
    `prototype.locvars` reflection (used by NetTimedAction's wire serializer)
    reads the LAST wrap's named-parameter list as the canonical schema.
    Our 11-named-params + `...` signature on ISHandcraftAction.new silently
    truncated 12-arg payloads from mods loaded earlier than CSR.

    INTERMEDIATE FIX (2026-05-06 morning) -- moved walking-flag mutation onto
    each class's `:start()` method. That fixed the wire-schema breakage but
    silently broke the walking feature itself: `LuaTimedActionNew`'s Java
    constructor snapshots `stopOnWalk` into a Java boolean inside `:create()`,
    which `:begin()` calls before `:start()` ever runs. By the time `:start`
    fired, Java had already cached the unmutated value, so the walking feature
    was a no-op for everything except `ISWearClothing.isStopOnWalk` (static
    helper, read fresh per tick) and the sprint-cancel hook.

    CURRENT APPROACH (2026-05-06 afternoon, cross-checked with JeevesPC author)
    --------------------------------------------------------------------------
    Single override on `ISBaseTimedAction:begin`. We mutate `self.stopOnWalk`
    at the top of `:begin`, before vanilla's begin runs `:create` ->
    `LuaTimedActionNew.new` (where Java reads the field). That's the only
    deterministic window between construction and the Java snapshot.

    Per-class whitelist (`WALKING_ACTION_TYPES`) keeps the override
    transparent for any action class we don't explicitly target, so we don't
    accidentally enable walking during digging, surgery, or any other action
    that needs the player stationary.

    The nil-craftRecipe guard for B42's `NetTimedAction.parse` NPE moves into
    the same `:begin` override -- still SP + Coop host scope, still no impact
    on constructor signatures.

    `ISWearClothing.isStopOnWalk` static override and the sprint-cancel
    OnPlayerUpdate hook are unchanged -- both are orthogonal to the wire
    schema and to the Java snapshot.
]]

CSR_WalkingActions = {}

local function walkingEnabled()
    return CSR_FeatureFlags and CSR_FeatureFlags.isWalkingActionsEnabled and CSR_FeatureFlags.isWalkingActionsEnabled()
end

-- ---------------------------------------------------------------------------
-- Per-action-class opt-in. Only flip stopOnWalk for action classes we
-- previously patched. Anything not in this set behaves exactly as vanilla.
-- ---------------------------------------------------------------------------
local WALKING_ACTION_TYPES = {
    ISWearClothing    = true,
    ISUnequipAction   = true,
    ISCraftAction     = true,
    ISHandcraftAction = true,
    ISReadABook       = true,
    ISReadMagazine    = true,
    ISReadNewspaper   = true,
    ISReadComic       = true,
    ISReadMap         = true,
}

local function isWalkingActionClass(action)
    if type(action) ~= "table" then return false end
    -- ISBaseObject:derive() sets `Type` to the class name string.
    return action.Type and WALKING_ACTION_TYPES[action.Type] == true
end

-- ---------------------------------------------------------------------------
-- ISBaseTimedAction:begin override
--
-- Order of operations in vanilla:
--   1. action:new(...)                                 -- Lua object built
--   2. queue:add(action) -> action:begin()
--   3. :begin -> :create -> LuaTimedActionNew.new(...) -- Java snapshots stopOnWalk
--   4. :begin -> character:StartAction(...)
--   5. :start fires later when the action becomes current
--
-- We hook between (1) and (3): mutate self.stopOnWalk at the top of :begin,
-- before oldBegin runs :create. The Java constructor reads the mutated value
-- into BaseAction.stopOnWalk where the per-tick movement check reads it.
--
-- For action classes outside WALKING_ACTION_TYPES the override is a no-op,
-- so it stays transparent to vanilla and to other mods' actions.
-- ---------------------------------------------------------------------------

local function patchBaseTimedActionBegin()
    if not ISBaseTimedAction or type(ISBaseTimedAction.begin) ~= "function" then return end
    if ISBaseTimedAction.__CSRWalkingPatched then return end
    ISBaseTimedAction.__CSRWalkingPatched = true

    local oldBegin = ISBaseTimedAction.begin

    function ISBaseTimedAction:begin()
        -- Defensive nil-craftRecipe guard, relocated from the old wraps.
        -- NetTimedAction.parse can hand a HandcraftAction a nil craftRecipe
        -- when a recipe id fails to resolve (renamed/removed/cross-mod
        -- desync). Vanilla's update path NPEs on craftRecipe:isCanWalk()
        -- shortly after; bail here so the action never enters update.
        if self.Type == "ISHandcraftAction" and self.craftRecipe == nil then
            if isClient and not isClient() then
                print("[CSR] Skipped HandcraftAction with nil craftRecipe (likely cross-mod recipe desync)")
            end
            self.__CSRInvalid = true
            local q = ISTimedActionQueue and ISTimedActionQueue.getTimedActionQueue
                and ISTimedActionQueue.getTimedActionQueue(self.character)
            if q and q.resetQueue then q:resetQueue() end
            return
        end

        -- Walking-flag mutation. Has to happen before oldBegin runs because
        -- oldBegin -> :create -> LuaTimedActionNew.new is the snapshot point.
        if walkingEnabled() and isWalkingActionClass(self) then
            self.stopOnWalk = false
            self.stopOnRun  = true
            self.__CSRWalkingAction = true
        end

        return oldBegin(self)
    end
end

-- ---------------------------------------------------------------------------
-- ISWearClothing.isStopOnWalk -- static helper, unrelated to wire schema
-- and read fresh by vanilla per tick. Kept from the previous implementation.
-- ---------------------------------------------------------------------------

local function patchWearClothingStatic()
    if not ISWearClothing or type(ISWearClothing.isStopOnWalk) ~= "function" then return end
    if ISWearClothing.__CSRWalkingStaticPatched then return end
    ISWearClothing.__CSRWalkingStaticPatched = true

    local oldIsStopOnWalk = ISWearClothing.isStopOnWalk
    ISWearClothing.isStopOnWalk = function(item)
        if walkingEnabled() then
            return false
        end
        return oldIsStopOnWalk(item)
    end
end

-- ---------------------------------------------------------------------------
-- Sprint-cancel hook (unchanged)
-- ---------------------------------------------------------------------------

local function hookSprintStop()
    if CSR_WalkingActions._sprintHooked or not Events or not Events.OnPlayerUpdate then
        return
    end
    CSR_WalkingActions._sprintHooked = true

    Events.OnPlayerUpdate.Add(function(player)
        if not walkingEnabled() or not player or player:isDead() then return end
        if not ISTimedActionQueue or not ISTimedActionQueue.getTimedActionQueue then return end

        local queue = ISTimedActionQueue.getTimedActionQueue(player)
        if not queue or not queue.queue or not queue.queue[1] then return end

        local action = queue.queue[1]
        if not action.__CSRWalkingAction then return end

        if player.isSprinting and player:isSprinting() then
            if action.stop then action:stop() end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Patch entry point
-- ---------------------------------------------------------------------------

function CSR_WalkingActions.tryPatch()
    patchBaseTimedActionBegin()
    patchWearClothingStatic()
    hookSprintStop()

    -- Inventory transfer walking patch intentionally NOT enabled --
    -- vanilla isValid() checks container proximity which fails while
    -- walking, causing "bugged action, cleared queue".
end

Events.OnGameStart.Add(CSR_WalkingActions.tryPatch)

return CSR_WalkingActions
