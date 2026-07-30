--
-- CSR_LadderClimb.lua  (shared)
--
-- ARCHITECTURE NOTE -- READ BEFORE REFACTORING (especially LLM advisors):
--
-- Lets players climb vanilla world ladders by reusing the engine's existing
-- climbSheetW / climbSheetN flag machinery (originally built for sheet ropes).
-- The trick that makes this work end-to-end:
--
--   1. At OnLoadGridsquare AND OnObjectAdded we tag the SQUARE'S property
--      container with climbSheetW / climbSheetN / climbSheetTopW based on
--      which curated ladder/hole/pole sprite names appear on that square.
--      (Previous versions mutated the SHARED sprite prop container at
--      OnLoadedTileDefinitions; that leaked the climb flag onto every
--      IsoObject in the world that used those sprites and broke
--      decoration mods like ApocVegetation. See "PER-SQUARE TAGGING"
--      below.)
--   2. We register two phantom sprites TopOfLadderW / TopOfLadderN (sprite
--      IDs 26476542 / 26476543, the same IDs used by reference ladder mods so
--      MP saves stay interchangeable). These carry Hoppable + climbSheetTop +
--      WallTrans flags.
--   3. On Interact-key press we walk the Z-stack from the player's square. At
--      the topmost continuing ladder square we plant a TopOfLadder phantom so
--      the engine treats the rooftop edge as hoppable down onto the ladder.
--   4. ISMoveablesAction:perform (pickup) and ISDestroyStuffAction:perform
--      are wrapped to clean up the phantom when the underlying ladder leaves.
--
-- PER-SQUARE TAGGING (2026-05-06) -- LOAD-BEARING:
--   The legacy approach mutated IsoSpriteManager:getSprite(name):getProperties()
--   for every name in westLadderTiles / northLadderTiles. That returns the
--   single shared sprite instance, so the mutation leaked onto every world
--   object using that sprite. ApocVegetation (10 Years Later, workshop id
--   3719766602) places vine objects on the same wall sprites that carry
--   vanilla fire-escape ladders (e.g. walls_commercial_03_0); removing a
--   vine then NPE'd on the leaf-string drop path because the underlying
--   wall now reported climbSheetW=true.
--
--   The fix tags the SQUARE'S property container instead, scoped to the
--   actual square that contains a ladder sprite. The engine's climb path
--   already reads square:has(climbSheetW) -- this is functionally identical
--   for climbing while keeping shared sprite props pristine. OnObjectAdded
--   covers runtime placement (movables drop, carpentry build, runtime
--   spawn) so player-built / mod-spawned ladders are caught too.
--
-- COOPERATIVE NO-OP -- LOAD-BEARING:
--   At least three other workshop mods (Ladders42131, LaddersRed, b42LaddersTemp)
--   register the SAME phantom sprite name + ID. Calling AddSprite("TopOfLadderW",
--   26476542) twice CRASHES the engine. We pcall-wrap our AddSprite calls so
--   if a partner ladder mod registered first the engine throw is caught and
--   we log + continue. Our runtime hop logic still works because addTopOfLadder
--   only references sprites by name; whoever registered them owns them.
--
--   DO NOT delete the pcall around AddSprite even if it "looks redundant" --
--   you will crash any user running CSR alongside another ladder mod.
--
-- COMPATIBILITY:
--   - CSR_ClimbWithBags (v1.7.x) already drops/re-equips bags on
--     ClimbSheetRopeState transitions. Vanilla ladders share that engine state
--     so bag handling Just Works -- no extra hook needed.
--   - CSR_GroundCleanup (post-Zeer compat) skips world objects with non-empty
--     modData. Phantom TopOfLadder objects intentionally do NOT carry modData
--     so they remain disposable. DO NOT start writing modData on phantoms or
--     you will create a leak (cleanup will treat them as third-party state).
--
-- IDs reused from upstream (Ladders42131 / LaddersRed) on purpose: this lets
-- saved games written by a player who switches mods round-trip cleanly.
--

local CSR_LadderClimb = {}

CSR_LadderClimb.idW = 26476542
CSR_LadderClimb.idN = 26476543
CSR_LadderClimb.climbSheetTopW = "TopOfLadderW"
CSR_LadderClimb.climbSheetTopN = "TopOfLadderN"

-- Vanilla + popular-mod B42 ladder sprite identifiers. Verified working
-- through B42.13-B42.17. Missing sprites are tolerated -- setFlagIfExist
-- below silently skips them. Sprite list mirrors the reference Ladders mod
-- (workshop id 3629835761) so saves stay interchangeable.
CSR_LadderClimb.westLadderTiles = {
    "industry_02_86",
    "location_sewer_01_32",
    "industry_railroad_05_20",
    "industry_railroad_05_36",
    "walls_commercial_03_0",
    -- Reference-mod additions (RUS map / aaa_RC / A1 / trelai / industry_crane_rus)
    "edit_ddd_RUS_decor_house_01_16",
    "edit_ddd_RUS_decor_house_01_19",
    "edit_ddd_RUS_industry_crane_01_72",
    "edit_ddd_RUS_industry_crane_01_73",
    "rus_industry_crane_ddd_01_24",
    "rus_industry_crane_ddd_01_25",
    "A1 Wall_48",
    "A1 Wall_80",
    "A1_CULT_36",
    "aaa_RC_6",
    "trelai_tiles_01_30",
    "trelai_tiles_01_38",
    "industry_crane_rus_72",
    "industry_crane_rus_73",
}

CSR_LadderClimb.northLadderTiles = {
    "location_sewer_01_33",
    "industry_railroad_05_21",
    "industry_railroad_05_37",
    -- Reference-mod additions
    "edit_ddd_RUS_decor_house_01_17",
    "edit_ddd_RUS_decor_house_01_18",
    "edit_ddd_RUS_industry_crane_01_76",
    "edit_ddd_RUS_industry_crane_01_77",
    "A1 Wall_49",
    "A1 Wall_81",
    "A1_CULT_37",
    "aaa_RC_14",
    "trelai_tiles_01_31",
    "trelai_tiles_01_39",
    "industry_crane_rus_76",
    "industry_crane_rus_77",
}

-- basement_objects_02_1..62 alternate W/N by parity index (vanilla pattern).
for index = 1, 62 do
    local name = "basement_objects_02_" .. index
    if index % 2 == 0 then
        CSR_LadderClimb.westLadderTiles[#CSR_LadderClimb.westLadderTiles + 1] = name
    else
        CSR_LadderClimb.northLadderTiles[#CSR_LadderClimb.northLadderTiles + 1] = name
    end
end

CSR_LadderClimb.holeTiles = { "floors_interior_carpet_01_24" }
CSR_LadderClimb.poleTiles = { "recreational_sports_01_32", "recreational_sports_01_33" }

-- Tiles that should NOT use the ladder climb anim variant (fire poles, etc.)
CSR_LadderClimb.excludeAnimTiles = {}
for _, name in ipairs(CSR_LadderClimb.poleTiles) do
    CSR_LadderClimb.excludeAnimTiles[name] = true
end

-- ────────────────────────────────────────────────────────────────────
-- Sprite-name lookup tables (per-square tagging path)
--
-- Built once at file load from the curated lists above. Used by the
-- OnLoadGridsquare / OnObjectAdded hooks to tag the SQUARE that
-- contains a ladder sprite, instead of mutating the shared sprite
-- prop container.
--
-- Why this layout: 10 Years Later (ApocVegetation) places vine objects
-- on the same wall sprites that carry vanilla fire-escape ladders
-- (e.g. walls_commercial_03_0). The legacy approach mutated the SHARED
-- sprite prop container via IsoSpriteManager:getSprite():getProperties(),
-- which leaked the climbSheet flag onto every IsoObject in the world
-- using that sprite -- including the one ApocVegetation drapes a vine
-- over. Removing the vine then NPE'd in vanilla's leaf-string drop
-- path because the wall looked sheet-rope-bearing.
--
-- Per-square tagging keeps the shared sprite props untouched and only
-- tags the square that actually holds a ladder object. Same end result
-- for the engine (square:has(climbSheetW) is what the climb path reads),
-- zero leak surface.
-- ────────────────────────────────────────────────────────────────────
CSR_LadderClimb._lookup = {
    west = {},   -- sprite name -> true  (climbSheetW)
    north = {},  -- sprite name -> true  (climbSheetN)
    hole = {},   -- sprite name -> true  (climbSheetTopW + HoppableW + unset solidfloor)
    pole = {},   -- sprite name -> true  (climbSheetW)
}
for _, n in ipairs(CSR_LadderClimb.westLadderTiles)  do CSR_LadderClimb._lookup.west[n]  = true end
for _, n in ipairs(CSR_LadderClimb.northLadderTiles) do CSR_LadderClimb._lookup.north[n] = true end
for _, n in ipairs(CSR_LadderClimb.holeTiles)        do CSR_LadderClimb._lookup.hole[n]  = true end
for _, n in ipairs(CSR_LadderClimb.poleTiles)        do CSR_LadderClimb._lookup.pole[n]  = true end

-- ────────────────────────────────────────────────────────────────────
-- Per-square tagging
--
-- Tags climbSheet flags on the SQUARE'S property container based on
-- which ladder/hole/pole sprites are currently present on that square.
-- Idempotent: re-running on a tagged square is a no-op.
-- ────────────────────────────────────────────────────────────────────
function CSR_LadderClimb.tagSquare(square)
    if not square then return end
    local objects = square:getObjects()
    if not objects or objects:size() == 0 then return end
    local props = square:getProperties()
    if not props then return end

    local lookup = CSR_LadderClimb._lookup

    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local sprite = obj.getSprite and obj:getSprite() or nil
            local name = sprite and sprite.getName and sprite:getName() or nil
            if not name and obj.getTextureName then name = obj:getTextureName() end
            if name then
                if lookup.west[name] then
                    if not props:has(IsoFlagType.climbSheetW) then
                        props:set(IsoFlagType.climbSheetW)
                    end
                elseif lookup.north[name] then
                    if not props:has(IsoFlagType.climbSheetN) then
                        props:set(IsoFlagType.climbSheetN)
                    end
                elseif lookup.pole[name] then
                    if not props:has(IsoFlagType.climbSheetW) then
                        props:set(IsoFlagType.climbSheetW)
                    end
                elseif lookup.hole[name] then
                    if not props:has(IsoFlagType.climbSheetTopW) then
                        props:set(IsoFlagType.climbSheetTopW)
                    end
                    if not props:has(IsoFlagType.HoppableW) then
                        props:set(IsoFlagType.HoppableW)
                    end
                    if props:has(IsoFlagType.solidfloor) then
                        props:unset(IsoFlagType.solidfloor)
                    end
                end
            end
        end
    end
end

local function isEnabled()
    if CSR_FeatureFlags and CSR_FeatureFlags.isLadderClimbEnabled then
        return CSR_FeatureFlags.isLadderClimbEnabled()
    end
    -- Fallback: SandboxVars not yet loaded -> default true
    local sb = SandboxVars and SandboxVars.CommonSenseLight or nil
    if not sb then return true end
    return sb.EnableLadderClimb ~= false
end

-- ────────────────────────────────────────────────────────────────────
-- Phantom top-of-ladder placement
-- ────────────────────────────────────────────────────────────────────

function CSR_LadderClimb.getTopOfLadder(square, north)
    if not square then return nil end
    local objects = square:getObjects()
    if not objects then return nil end
    local target = north and CSR_LadderClimb.climbSheetTopN or CSR_LadderClimb.climbSheetTopW
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and obj:getTextureName() == target then
            return obj
        end
    end
    return nil
end

function CSR_LadderClimb.removeTopOfLadder(square)
    if not square then return end
    local objects = square:getObjects()
    if not objects then return end
    for i = objects:size() - 1, 0, -1 do
        local obj = objects:get(i)
        if obj then
            local name = obj:getTextureName()
            if name == CSR_LadderClimb.climbSheetTopN
                    or name == CSR_LadderClimb.climbSheetTopW then
                square:transmitRemoveItemFromSquare(obj)
            end
        end
    end
end

function CSR_LadderClimb.addTopOfLadder(square, north)
    if not square then return nil end
    local props = square:getProperties()
    if not props then return nil end
    -- If the square already has a wall in our direction we cannot stand a
    -- phantom hoppable there -- it would conflict with the wall hitbox.
    if props:has(north and IsoFlagType.WallN or IsoFlagType.WallW)
            or props:has(IsoFlagType.WallNW) then
        CSR_LadderClimb.removeTopOfLadder(square)
        return nil
    end
    -- Already flagged climbSheetTop on this side: phantom is in place.
    if props:has(north and IsoFlagType.climbSheetTopN or IsoFlagType.climbSheetTopW) then
        return CSR_LadderClimb.getTopOfLadder(square, north)
    end
    local spriteName = north and CSR_LadderClimb.climbSheetTopN
                              or CSR_LadderClimb.climbSheetTopW
    local object = IsoObject.new(getCell(), square, spriteName)
    if object then
        square:transmitAddObjectToSquare(object, -1)
    end
    return object
end

-- Walk upward from `square`. Plant a TopOfLadder phantom on the topmost
-- continuing ladder square so the engine offers a Hop transition.
function CSR_LadderClimb.makeLadderClimbable(square, north)
    if not square then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local flags
    if north then
        flags = {
            climbSheet    = IsoFlagType.climbSheetN,
            climbSheetTop = IsoFlagType.climbSheetTopN,
            Wall          = IsoFlagType.WallN,
        }
    else
        flags = {
            climbSheet    = IsoFlagType.climbSheetW,
            climbSheetTop = IsoFlagType.climbSheetTopW,
            Wall          = IsoFlagType.WallW,
        }
    end

    local topSquare = square
    local topObject = nil

    while true do
        if topSquare:has(flags.climbSheetTop) then
            topObject = CSR_LadderClimb.getTopOfLadder(topSquare, north)
        else
            topObject = nil
        end

        z = z + 1
        local aboveSquare = getSquare(x, y, z)
        if not aboveSquare then break end

        local treatsAsSolidFloor = false
        local ok = pcall(function()
            treatsAsSolidFloor = aboveSquare:TreatAsSolidFloor()
        end)
        if ok and treatsAsSolidFloor then break end
        if aboveSquare:has("RoofGroup") then break end

        if aboveSquare:has(flags.climbSheet) then
            if topObject then topSquare:transmitRemoveItemFromSquare(topObject) end
            topSquare = aboveSquare
        elseif not (aboveSquare:has(flags.Wall) or aboveSquare:has(IsoFlagType.WallNW)) then
            if topObject then topSquare:transmitRemoveItemFromSquare(topObject) end
            topSquare = aboveSquare
            break
        else
            CSR_LadderClimb.removeTopOfLadder(aboveSquare)
            break
        end
    end

    if topSquare then
        CSR_LadderClimb.addTopOfLadder(topSquare, north)
        if CSR_LadderClimb.player then
            CSR_LadderClimb.chooseAnimVar(topSquare, CSR_LadderClimb.getTopOfLadder(topSquare, north))
        end
    end
end

function CSR_LadderClimb.makeLadderClimbableFromTop(square)
    if not square then return end
    local x, y, z = square:getX(), square:getY(), square:getZ() - 1
    local belowSquare = getSquare(x, y, z)
    if not belowSquare then return end
    CSR_LadderClimb.makeLadderClimbableFromBottom(getSquare(x - 1, y,     z))
    CSR_LadderClimb.makeLadderClimbableFromBottom(getSquare(x + 1, y,     z))
    CSR_LadderClimb.makeLadderClimbableFromBottom(getSquare(x,     y - 1, z))
    CSR_LadderClimb.makeLadderClimbableFromBottom(getSquare(x,     y + 1, z))
end

function CSR_LadderClimb.makeLadderClimbableFromBottom(square)
    if not square then return end
    local props = square:getProperties()
    if not props then return end
    if props:has(IsoFlagType.climbSheetN) then
        CSR_LadderClimb.makeLadderClimbable(square, true)
    elseif props:has(IsoFlagType.climbSheetW) then
        CSR_LadderClimb.makeLadderClimbable(square, false)
    end
end

-- ────────────────────────────────────────────────────────────────────
-- Anim variable picker (ladder climb anim vs sheet-rope anim vs none)
-- ────────────────────────────────────────────────────────────────────

function CSR_LadderClimb.chooseAnimVar(square, topObject)
    if not square or not CSR_LadderClimb.player then return end
    local doLadderAnim = topObject ~= nil
    if doLadderAnim then
        local objects = square:getObjects()
        if objects then
            for i = 0, objects:size() - 1 do
                local obj = objects:get(i)
                if obj and CSR_LadderClimb.excludeAnimTiles[obj:getTextureName()] then
                    doLadderAnim = false
                    break
                end
            end
        end
    end
    if doLadderAnim then
        CSR_LadderClimb.player:setVariable("ClimbLadder", true)
    else
        CSR_LadderClimb.player:clearVariable("ClimbLadder")
    end
end

-- ────────────────────────────────────────────────────────────────────
-- Interact-key entry point
-- ────────────────────────────────────────────────────────────────────

function CSR_LadderClimb.OnKeyPressed(key)
    if not isEnabled() then return end
    if key ~= getCore():getKey("Interact") then return end
    local player = getPlayer()
    if not player or player:isDead() then return end
    if MainScreen and MainScreen.instance and MainScreen.instance:isVisible() then return end

    CSR_LadderClimb.player = player
    local square = player:getSquare()
    if not square then return end

    -- v1.8.2: lightweight diagnostic so it's obvious from console.txt whether
    -- the climb pass actually ran when the user pressed Interact.  Logs the
    -- player square's climbSheet/climbSheetTop flags for the four cardinal
    -- directions so a "ladder doesn't work" report can be diagnosed without
    -- extra build steps.
    local props = square:getProperties()
    if props then
        print(string.format(
            "[CSR] Ladder Interact @ (%d,%d,%d): climbW=%s climbN=%s topW=%s topN=%s",
            square:getX(), square:getY(), square:getZ(),
            tostring(props:has(IsoFlagType.climbSheetW)),
            tostring(props:has(IsoFlagType.climbSheetN)),
            tostring(props:has(IsoFlagType.climbSheetTopW)),
            tostring(props:has(IsoFlagType.climbSheetTopN))
        ))
    end

    CSR_LadderClimb.makeLadderClimbableFromTop(square)
    CSR_LadderClimb.makeLadderClimbableFromBottom(square)
end

-- ────────────────────────────────────────────────────────────────────
-- Cleanup hooks: pickup-up moveable / destroyed sheet-rope item
-- ────────────────────────────────────────────────────────────────────

local function patchMoveablesAction()
    if not ISMoveablesAction or ISMoveablesAction.__csr_ladder_patched then return end
    ISMoveablesAction.__csr_ladder_patched = true
    local origPerform = ISMoveablesAction.perform
    function ISMoveablesAction:perform()
        origPerform(self)
        if self.mode == "pickup" and self.square then
            local sq = getSquare(self.square:getX(), self.square:getY(), self.square:getZ() + 1)
            if sq then CSR_LadderClimb.removeTopOfLadder(sq) end
        end
    end
end

local function patchDestroyStuffAction()
    if not ISDestroyStuffAction or ISDestroyStuffAction.__csr_ladder_patched then
        return
    end
    ISDestroyStuffAction.__csr_ladder_patched = true
    local origPerform = ISDestroyStuffAction.perform
    function ISDestroyStuffAction:perform()
        if self.item and self.item.haveSheetRope and self.item:haveSheetRope() then
            local sq = self.item:getSquare()
            if sq then CSR_LadderClimb.removeTopOfLadder(sq) end
        end
        return origPerform(self)
    end
end

-- ────────────────────────────────────────────────────────────────────
-- Sprite registration & flag tagging (cooperative no-op against other
-- ladder mods)
--
-- IMPORTANT (2026-05-06 refactor): the shared-sprite prop mutation
-- loops were removed from this function. They permanently mutated
-- IsoSpriteManager's single shared sprite instances (e.g. the props
-- container on walls_commercial_03_0), which leaked climbSheetW onto
-- every IsoObject in the world that used those sprites and broke
-- ApocVegetation (10 Years Later) vine removal among other things.
--
-- Tagging now happens per-square at OnLoadGridsquare and OnObjectAdded
-- via CSR_LadderClimb.tagSquare(). Shared sprite props are no longer
-- touched. Phantom TopOfLadder sprite registration is preserved here
-- because those are OUR sprite names -- no leak surface, and other
-- ladder mods reuse the same name+ID by design (cooperative no-op).
-- ────────────────────────────────────────────────────────────────────

-- ────────────────────────────────────────────────────────────────────
-- Legacy shared-sprite mutation (RESTORED 2026-05-06 per user request)
--
-- The per-square tagging path (tagSquare + OnLoadGridsquare/OnObjectAdded)
-- was found to be unreliable in MP -- ladders that streamed in mid-session
-- did not always pick up the flag because property changes on a square that
-- already shipped to clients were not re-broadcast, leaving the climb path
-- broken.  Restoring the legacy approach: tag the SHARED sprite prop
-- container at OnLoadedTileDefinitions time so every IsoObject in the world
-- using that sprite reports the climbSheet flag for free.
--
-- Trade-off: this can leak the flag onto unrelated objects that happen to
-- reuse the same sprite ID (e.g. ApocVegetation vines on walls_commercial_03_0).
-- Documented in KNOWN_LIMITATIONS until a per-object filter ships.
-- ────────────────────────────────────────────────────────────────────
local function setSpriteFlag(manager, name, flag)
    if not manager or not name then return end
    local sprite = manager.getSprite and manager:getSprite(name) or nil
    if not sprite then return end
    local p = sprite:getProperties()
    if not p then return end
    if not p:has(flag) then
        p:set(flag)
        if p.CreateKeySet then p:CreateKeySet() end
    end
end

local function unsetSpriteFlag(manager, name, flag)
    if not manager or not name then return end
    local sprite = manager.getSprite and manager:getSprite(name) or nil
    if not sprite then return end
    local p = sprite:getProperties()
    if not p then return end
    if p:has(flag) then
        p:unset(flag)
        if p.CreateKeySet then p:CreateKeySet() end
    end
end

function CSR_LadderClimb.setLadderClimbingFlags(manager)
    if not isEnabled() then return end
    if not manager then return end

    -- Legacy shared-sprite tagging for the climbable directions.
    for _, n in ipairs(CSR_LadderClimb.westLadderTiles) do
        setSpriteFlag(manager, n, IsoFlagType.climbSheetW)
    end
    for _, n in ipairs(CSR_LadderClimb.northLadderTiles) do
        setSpriteFlag(manager, n, IsoFlagType.climbSheetN)
    end
    for _, n in ipairs(CSR_LadderClimb.poleTiles) do
        setSpriteFlag(manager, n, IsoFlagType.climbSheetW)
    end
    -- Hole tiles are top-of-ladder hops down: flag climbSheetTopW + HoppableW
    -- and clear solidfloor so the engine offers the down-hop transition.
    for _, n in ipairs(CSR_LadderClimb.holeTiles) do
        setSpriteFlag(manager, n,   IsoFlagType.climbSheetTopW)
        setSpriteFlag(manager, n,   IsoFlagType.HoppableW)
        unsetSpriteFlag(manager, n, IsoFlagType.solidfloor)
    end

    -- Phantom registration is unconditional and idempotent.
    -- Pcall-wrapped so a duplicate-ID collision against a still-loaded
    -- partner ladder mod doesn't crash the engine.
    local existing = manager.getSprite and manager:getSprite(CSR_LadderClimb.climbSheetTopW) or nil
    print(string.format(
        "[CSR] LadderClimb phantom registration (existing=%s)",
        tostring(existing ~= nil)
    ))
    CSR_LadderClimb._cooperativeSkip = false

    -- Phantom W sprite -- pcall-wrapped so a duplicate-ID collision against
    -- a partner ladder mod cannot crash the engine.  If AddSprite errors we
    -- log and continue; the partner mod's identical sprite registration is
    -- compatible because we share the same sprite name + ID.
    local okW, spriteW = pcall(function()
        return manager:AddSprite(CSR_LadderClimb.climbSheetTopW, CSR_LadderClimb.idW)
    end)
    if not okW then
        print("[CSR] LadderClimb: AddSprite(W) raised; assuming partner mod registered it.")
    elseif spriteW then
        spriteW:setName(CSR_LadderClimb.climbSheetTopW)
        local p = spriteW:getProperties()
        if p then
            p:set(IsoFlagType.collideW)
            p:set(IsoFlagType.transparentW)
            p:set(IsoFlagType.cutW)
            p:set(IsoFlagType.climbSheetTopW)
            p:set(IsoFlagType.HoppableW)
            p:set(IsoFlagType.canPathW)
            p:set(IsoFlagType.WallWTrans)
            p:set(IsoFlagType.EntityScript)
            p:CreateKeySet()
        end
    end

    -- Phantom N sprite (same pcall protection)
    local okN, spriteN = pcall(function()
        return manager:AddSprite(CSR_LadderClimb.climbSheetTopN, CSR_LadderClimb.idN)
    end)
    if not okN then
        print("[CSR] LadderClimb: AddSprite(N) raised; assuming partner mod registered it.")
    elseif spriteN then
        spriteN:setName(CSR_LadderClimb.climbSheetTopN)
        local p = spriteN:getProperties()
        if p then
            p:set(IsoFlagType.collideN)
            p:set(IsoFlagType.transparentN)
            p:set(IsoFlagType.cutN)
            p:set(IsoFlagType.climbSheetTopN)
            p:set(IsoFlagType.HoppableN)
            p:set(IsoFlagType.canPathN)
            p:set(IsoFlagType.WallNTrans)
            p:set(IsoFlagType.EntityScript)
            p:CreateKeySet()
        end
    end
end

-- ────────────────────────────────────────────────────────────────────
-- Stream-in / placement hooks
--
-- These ensure climbable squares get the climbSheet flags whether the
-- ladder was placed at world generation, dropped via Move Furniture,
-- player-built via carpentry, or spawned by another mod at runtime.
-- The cost per call is one objects:size() walk and an O(1) string-set
-- lookup per object -- microseconds for normal squares, free for empty
-- ones (early return on objects:size() == 0).
-- ────────────────────────────────────────────────────────────────────

local function onLoadGridsquare(square)
    if not isEnabled() then return end
    CSR_LadderClimb.tagSquare(square)
end

local function onObjectAdded(obj)
    if not isEnabled() then return end
    if not obj or not obj.getSquare then return end
    CSR_LadderClimb.tagSquare(obj:getSquare())
end

-- ────────────────────────────────────────────────────────────────────
-- Event registration
-- ────────────────────────────────────────────────────────────────────

if Events then
    if Events.OnLoadedTileDefinitions and not CSR_LadderClimb._tileDefHooked then
        CSR_LadderClimb._tileDefHooked = true
        Events.OnLoadedTileDefinitions.Add(CSR_LadderClimb.setLadderClimbingFlags)
    end
    if Events.OnLoadGridsquare and not CSR_LadderClimb._squareHooked then
        CSR_LadderClimb._squareHooked = true
        Events.OnLoadGridsquare.Add(onLoadGridsquare)
    end
    if Events.OnObjectAdded and not CSR_LadderClimb._objectAddedHooked then
        CSR_LadderClimb._objectAddedHooked = true
        Events.OnObjectAdded.Add(onObjectAdded)
    end
    if Events.OnKeyPressed and not CSR_LadderClimb._keyHooked then
        CSR_LadderClimb._keyHooked = true
        Events.OnKeyPressed.Add(CSR_LadderClimb.OnKeyPressed)
    end
    if Events.OnGameStart and not CSR_LadderClimb._patchHooked then
        CSR_LadderClimb._patchHooked = true
        Events.OnGameStart.Add(function()
            if not isEnabled() then return end
            patchMoveablesAction()
            patchDestroyStuffAction()
        end)
    end
end

return CSR_LadderClimb
