-- CSR_BeltLightToggle.lua
-- Patches ItemBindingHandler.toggleLight so that HandWeapon light sources
-- (e.g. flashlights / torches) that are ATTACHED to a belt slot are toggled
-- in-place on the belt when the player presses F, instead of being taken
-- into the player's hand.
--
-- Vanilla deliberately excludes HandWeapon items from belt-toggle so that
-- items like the wooden torch keep their "grab-to-use-as-weapon" behaviour.
-- Here we lift that restriction:  if a light-source HandWeapon is already
-- properly attached (belt slot), F toggles it; if it's only in the
-- inventory, vanilla fall-through equips it as normal.

local function patchToggleLight()
    if not ItemBindingHandler or not ItemBindingHandler.toggleLight then
        return
    end

    local orig = ItemBindingHandler.toggleLight

    ItemBindingHandler.toggleLight = function(key)
        local playerObj = getSpecificPlayer(0)
        if not playerObj then
            orig(key)
            return
        end

        -- Vehicle headlights (identical to vanilla)
        if key and getCore():isKey("ToggleVehicleHeadlights", key) then
            local vehicle = playerObj:getVehicle()
            if vehicle and vehicle:isDriver(playerObj) and not playerObj:isAiming() then
                if vehicle:hasHeadlights() then
                    ISVehicleMenu.onToggleHeadlights(playerObj)
                end
                return
            end
        end

        -- Secondary hand (identical to vanilla)
        local secondary = playerObj:getSecondaryHandItem()
        if secondary ~= nil
                and secondary:canEmitLight()
                and secondary:getType() ~= "CandleLit"
                and secondary:getType() ~= "Lantern_HurricaneLit" then
            if secondary:canBeActivated() then
                secondary:setActivated(not secondary:isActivated())
                syncItemActivated(playerObj, secondary)
                secondary:playActivateDeactivateSound()
            end
            return
        end

        -- Primary hand (identical to vanilla)
        local primary = playerObj:getPrimaryHandItem()
        if primary ~= nil
                and primary:canEmitLight()
                and primary:getType() ~= "CandleLit"
                and primary:getType() ~= "Lantern_HurricaneLit" then
            if primary:canBeActivated() then
                primary:setActivated(not primary:isActivated())
                syncItemActivated(playerObj, primary)
                primary:playActivateDeactivateSound()
            end
            return
        end

        -- Belt/hotbar attached items.
        -- KEY DIFFERENCE from vanilla: the `not instanceof(item, "HandWeapon")`
        -- guard is REMOVED so that flashlights (which are HandWeapons) can be
        -- toggled from the belt without being grabbed by hand.
        local attachedItems = playerObj:getAttachedItems()
        for i = 1, attachedItems:size() do
            local item = attachedItems:getItemByIndex(i - 1)
            if item:canEmitLight()
                    and item:getType() ~= "CandleLit"
                    and item:getType() ~= "Lantern_HurricaneLit" then
                if item:canBeActivated() then
                    item:setActivated(not item:isActivated())
                    syncItemActivated(playerObj, item)
                    item:playActivateDeactivateSound()
                end
                return
            end
        end

        -- Nothing in hand or on belt – equip best light source from inventory
        -- (identical to vanilla fall-through)
        if playerObj:isAiming() then return end
        local function predicateLightSource(it)
            return it:canEmitLight() and (it:getLightStrength() > 0)
        end
        local function compareLightStrength(a, b)
            return a:getLightStrength() - b:getLightStrength()
        end
        local lightSource = playerObj:getInventory():getBestEvalRecurse(
            predicateLightSource, compareLightStrength)
        if lightSource ~= nil then
            ISInventoryPaneContextMenu.transferIfNeeded(playerObj, lightSource)
            ISTimedActionQueue.add(ISEquipWeaponAction:new(
                playerObj, lightSource, 50,
                instanceof(lightSource, "HandWeapon"), false))
        end
    end
end

Events.OnGameStart.Add(patchToggleLight)
