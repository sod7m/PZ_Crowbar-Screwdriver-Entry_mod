require "CSR_FeatureFlags"

--[[
    CSR_SurvivorBond.lua  (v1.8.34c)
    Client-side moveable Survivor Bond HUD icon (MP only).

    Draws media/ui/CSR_SurvivorBond.png at the player's chosen screen
    position. Solid (full alpha) when the bond is active right now,
    grayed (low alpha + desaturated) when inactive. Hover shows a
    tooltip explaining what the icon represents. Drag to reposition;
    position is saved to player modData and restored next session.

    Server drives state via SurvivorBondActive packets handled in
    CSR_ServerCommands.lua.
]]

local FADE_FRAMES = 90
local SAVE_KEY = "csrBondHudPos"

local bondStrength = 0
local bondFadeTimer = 0
local everBonded = false
local bondTexture = nil

local function getBondTexture()
    if bondTexture == nil then
        bondTexture = getTexture("media/ui/CSR_SurvivorBond.png") or false
    end
    return bondTexture or nil
end

CSR_BondHud = ISPanel:derive("CSR_BondHud")
local hudInstance = nil

local function readSavedPos()
    local p = getSpecificPlayer(0)
    if not p then return nil end
    local md = p:getModData() or {}
    local saved = md[SAVE_KEY]
    if type(saved) == "table" and saved.x and saved.y then
        return tonumber(saved.x), tonumber(saved.y)
    end
    return nil
end

local function savePos(x, y)
    local p = getSpecificPlayer(0)
    if not p then return end
    local md = p:getModData() or {}
    md[SAVE_KEY] = { x = x, y = y }
end

function CSR_BondHud:initialise()
    ISPanel.initialise(self)
    self.moveWithMouse = true
    self.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self._hover = false
    self._tooltip = nil
end

function CSR_BondHud:onMouseUp(x, y)
    ISPanel.onMouseUp(self, x, y)
    savePos(self:getX(), self:getY())
end

function CSR_BondHud:onMouseMove(dx, dy)
    -- v1.8.36: previously this override only set the hover flag and never
    -- chained to ISPanel.onMouseMove, which is what actually applies the
    -- moveWithMouse drag. Result: moveWithMouse=true did nothing -- the
    -- HUD looked stuck. Forwarding the call lets PZ drag the panel.
    ISPanel.onMouseMove(self, dx, dy)
    self._hover = true
end

function CSR_BondHud:onMouseMoveOutside(dx, dy)
    -- Same fix while the cursor is dragging beyond panel bounds.
    ISPanel.onMouseMoveOutside(self, dx, dy)
    self._hover = false
    if self._tooltip then
        self._tooltip:removeFromUIManager()
        self._tooltip = nil
    end
end

local function bondTooltipText()
    local active = bondStrength > 0
    local state
    if active then
        state = "Active — receiving bonus"
    elseif everBonded then
        state = "Inactive — out of range"
    else
        state = "Inactive — bond not yet formed"
    end
    return "Survivor Bond <LINE> " ..
           state ..
           " <LINE> <LINE> Stay near another player to slowly reduce stress, boredom, fatigue and unhappiness. <LINE> <LINE> Drag to reposition."
end

function CSR_BondHud:prerender()
    ISPanel.prerender(self)

    if not CSR_FeatureFlags.isSurvivorBondEnabled() then
        self:setVisible(false)
        return
    end

    local active = bondStrength > 0
    if bondFadeTimer > 0 then bondFadeTimer = bondFadeTimer - 1 end

    local tex = getBondTexture()
    if tex and self.drawTextureScaledAspect then
        if active then
            -- Solid: full color, full alpha
            self:drawTextureScaledAspect(tex, 0, 0, self.width, self.height, 1.0, 1, 1, 1)
        else
            -- Grayed out: low alpha, desaturated tint
            self:drawTextureScaledAspect(tex, 0, 0, self.width, self.height, 0.35, 0.6, 0.6, 0.6)
        end
    else
        -- Texture missing: fall back to a colored square so the HUD is still draggable
        local r, g, b, a = (active and 0.30 or 0.55), (active and 0.90 or 0.55), (active and 0.40 or 0.55), (active and 0.95 or 0.35)
        self:drawRect(0, 0, self.width, self.height, a, r, g, b)
        self:drawRectBorder(0, 0, self.width, self.height, a, r, g, b)
    end

    -- Hover tooltip
    if self._hover and self:isMouseOver() then
        if not self._tooltip then
            local tt = ISToolTip:new()
            tt:initialise()
            tt:setVisible(true)
            tt:setOwner(self)
            tt:setName("Survivor Bond")
            tt.description = bondTooltipText()
            tt:addToUIManager()
            self._tooltip = tt
        end
        if self._tooltip then
            self._tooltip:setX(self:getX() + self:getWidth() + 8)
            self._tooltip:setY(self:getY())
        end
    elseif self._tooltip then
        self._tooltip:removeFromUIManager()
        self._tooltip = nil
    end
end

function CSR_BondHud.create()
    if hudInstance then return hudInstance end
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 40, 40
    local sx, sy = readSavedPos()
    local x = sx or (sw - w - 12)
    local y = sy or math.floor(sh * 0.5)
    local hud = CSR_BondHud:new(x, y, w, h)
    hud:initialise()
    hud:addToUIManager()
    hud:setVisible(true)
    hudInstance = hud
    return hud
end

if Events and Events.OnServerCommand then
    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= "CommonSenseLight" then return end
        if command ~= "SurvivorBondActive" then return end
        local s = tonumber(args and args.strength) or 0
        bondStrength = s
        if s > 0 then
            bondFadeTimer = FADE_FRAMES
            everBonded = true
        end
        if not hudInstance then CSR_BondHud.create() end
    end)
end

local function onGameStart()
    if not isClient() then return end
    if not CSR_FeatureFlags.isSurvivorBondEnabled() then return end
    CSR_BondHud.create()
end
Events.OnGameStart.Add(onGameStart)
