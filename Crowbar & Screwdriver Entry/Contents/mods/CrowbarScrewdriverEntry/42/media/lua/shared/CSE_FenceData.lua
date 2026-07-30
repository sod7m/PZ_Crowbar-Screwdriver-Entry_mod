-- Wire-fence sprites a pair of bolt cutters can get through, mapped to the
-- materials salvaged from the panel.
--
-- Only vanilla wire mesh / chain-link / barbed-wire panels are listed here:
-- plank-only and pipe-only panels are deliberately absent, because bolt
-- cutters cut wire, not steel tube or timber. Panels that mix wire with a
-- corner pipe drop the wire only - the pipe section would realistically stay
-- standing, but the whole tile is removed to keep the result walkable.

CSE_FenceData = {}

-- spriteName -> { { type = ItemFullType, count = N }, ... }
CSE_FenceData.CUTTABLE_SPRITES = {
    -- Wire mesh, half height
    ["fencing_01_25"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_26"] = { { type = "Base.Wire", count = 1 } },
    -- Wire mesh, full height
    ["fencing_01_57"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_58"] = { { type = "Base.Wire", count = 1 } },
    -- Wire + corner pipe, half height
    ["fencing_01_24"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_27"] = { { type = "Base.Wire", count = 1 } },
    -- Wire + corner pipe, full height
    ["fencing_01_56"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_59"] = { { type = "Base.Wire", count = 1 } },
    -- Two-pipe wire panel
    ["fencing_01_28"] = { { type = "Base.Wire", count = 2 } },
    ["fencing_01_60"] = { { type = "Base.Wire", count = 2 } },
    -- Barbed wire strung over wire mesh
    ["fencing_01_20"] = { { type = "Base.Wire", count = 1 }, { type = "Base.BarbedWire", count = 1 } },
    ["fencing_01_21"] = { { type = "Base.Wire", count = 1 }, { type = "Base.BarbedWire", count = 1 } },
}

function CSE_FenceData.isCuttableSprite(spriteName)
    return spriteName ~= nil and CSE_FenceData.CUTTABLE_SPRITES[spriteName] ~= nil
end

function CSE_FenceData.getDrops(spriteName)
    return CSE_FenceData.CUTTABLE_SPRITES[spriteName]
end

return CSE_FenceData
