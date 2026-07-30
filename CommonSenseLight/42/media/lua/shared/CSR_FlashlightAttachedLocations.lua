-- CSR_FlashlightAttachedLocations.lua
-- Registers belt torch attachment location slots on the Human group.
-- Maps the hotbar slot names (BeltTorchLeftSmall, etc.) to the custom
-- attachments defined in scripts/CSR_FlashlightAttachments.txt, which sit
-- on Bip01_Pelvis / Bip01_Spine1 with the correct offset and rotation so
-- the flashlight model renders properly on the belt instead of floating
-- at the character origin. Same approach as the full CommonSenseReborn mod.

local function registerTorchLocations()
    local locations = AttachedLocations and AttachedLocations.getGroup("Human") or nil
    if not locations then return end

    local function safeLoc(name, attachment)
        local loc = locations:getOrCreateLocation(name)
        if loc and loc.setAttachmentName then
            loc:setAttachmentName(attachment)
        end
    end

    -- Belt left / right -- custom Bip01_Pelvis attachments from
    -- scripts/CSR_FlashlightAttachments.txt
    safeLoc("BeltTorchLeftVerySmall", "torch_left_verysmall")
    safeLoc("BeltTorchLeftSmall",     "torch_left_small")
    safeLoc("BeltTorchLeftAngled",    "torch_left_angled")

    safeLoc("BeltTorchRightVerySmall", "torch_right_verysmall")
    safeLoc("BeltTorchRightSmall",     "torch_right_small")
    safeLoc("BeltTorchRightAngled",    "torch_right_angled")

    -- Webbing left / right -- reuse existing walkie attachments on Bip01_Spine1
    safeLoc("WebbingTorchLeftVerySmall", "webbing_left_walkie")
    safeLoc("WebbingTorchLeftSmall",     "webbing_left_walkie")
    safeLoc("WebbingTorchLeftAngled",    "webbing_left_walkie")

    safeLoc("WebbingTorchRightVerySmall", "webbing_right_walkie")
    safeLoc("WebbingTorchRightSmall",     "webbing_right_walkie")
    safeLoc("WebbingTorchRightAngled",    "webbing_right_walkie")
end

registerTorchLocations()
