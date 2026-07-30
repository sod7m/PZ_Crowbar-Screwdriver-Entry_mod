--[[
    CSR_FenceData.lua
    Wire-fence sprites that bolt cutters can cut through.
    Each entry maps an intact fence sprite name to the materials dropped on success.
    Sprites here are vanilla wire/chain-link/barbed-wire panels only — pipe-only
    or plank-only panels are intentionally excluded (bolt cutters cannot cut steel
    or wood). Pipe-and-wire panels drop only the wire (the pipe section is
    realistically left standing, but for simplicity we remove the whole tile).
]]

CSR_FenceData = {}

-- spriteName -> { {type=ItemFullType, count=N}, ... }
CSR_FenceData.CUTTABLE_SPRITES = {
    -- Wire mesh, half height
    ["fencing_01_25"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_26"] = { { type = "Base.Wire", count = 1 } },
    -- Wire mesh, full height
    ["fencing_01_57"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_58"] = { { type = "Base.Wire", count = 1 } },
    -- Wire + corner pipe, half height (drops 1 wire)
    ["fencing_01_24"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_27"] = { { type = "Base.Wire", count = 1 } },
    -- Wire + corner pipe, full height (drops 1 wire)
    ["fencing_01_56"] = { { type = "Base.Wire", count = 1 } },
    ["fencing_01_59"] = { { type = "Base.Wire", count = 1 } },
    -- Two-pipe wire panel (drops 2 wire)
    ["fencing_01_28"] = { { type = "Base.Wire", count = 2 } },
    ["fencing_01_60"] = { { type = "Base.Wire", count = 2 } },
    -- Barbed wire on top of wire mesh
    ["fencing_01_20"] = { { type = "Base.Wire", count = 1 }, { type = "Base.BarbedWire", count = 1 } },
    ["fencing_01_21"] = { { type = "Base.Wire", count = 1 }, { type = "Base.BarbedWire", count = 1 } },
}

function CSR_FenceData.isCuttableSprite(spriteName)
    return spriteName ~= nil and CSR_FenceData.CUTTABLE_SPRITES[spriteName] ~= nil
end

function CSR_FenceData.getDrops(spriteName)
    return CSR_FenceData.CUTTABLE_SPRITES[spriteName]
end

return CSR_FenceData
