-- CSR_FlashlightHotbarAttach.lua
-- Registers torch/flashlight attachment model locations for vanilla
-- SmallBeltLeft, SmallBeltRight, WebbingLeft, WebbingRight hotbar slots.
-- Without this, PZ won't show the flashlight model on the belt even though
-- the item has the correct AttachmentType and the locations are registered.

local TORCH_DATA = {
    SmallBeltLeft = {
        HandTorchSmall = "BeltTorchLeftVerySmall",
        HandTorchBig   = "BeltTorchLeftSmall",
        TorchAngled    = "BeltTorchLeftAngled",
    },
    SmallBeltRight = {
        HandTorchSmall = "BeltTorchRightVerySmall",
        HandTorchBig   = "BeltTorchRightSmall",
        TorchAngled    = "BeltTorchRightAngled",
    },
    WebbingLeft = {
        HandTorchSmall = "WebbingTorchLeftVerySmall",
        HandTorchBig   = "WebbingTorchLeftSmall",
        TorchAngled    = "WebbingTorchLeftAngled",
    },
    WebbingRight = {
        HandTorchSmall = "WebbingTorchRightVerySmall",
        HandTorchBig   = "WebbingTorchRightSmall",
        TorchAngled    = "WebbingTorchRightAngled",
    },
}

local function applyTorchAttachments()
    if not ISHotbarAttachDefinition then return end
    for _, definition in pairs(ISHotbarAttachDefinition) do
        if definition.type and definition.attachments then
            local data = TORCH_DATA[definition.type]
            if data then
                for attachType, modelLocation in pairs(data) do
                    definition.attachments[attachType] = modelLocation
                end
            end
        end
    end
end

Events.OnGameStart.Add(applyTorchAttachments)
Events.OnCreatePlayer.Add(function(playerIndex, playerObj)
    if playerIndex == 0 then
        applyTorchAttachments()
    end
end)
