--[[
CSR_AA_InteropGuard
-------------------
Loads first (alphabetically) so it can wrap CSR's own
Events.OnFillWorldObjectContextMenu.Add registrations with one protection:

  1) Skip the handler when the player is in a known foreign-mod interior cell
     (currently: ProjectRV interior at X>22500 and Y>12000) so our world
     context menus never run there and never block the host mod's options.

CRITICAL: only wrap handlers that originate from CSR's own files. Wrapping
a foreign mod's handler (e.g. ProjectRV, Project Interior) would cause our
"skip foreign interior" check to skip THEIR exit option from inside THEIR
own interior cell -- exactly what we are trying to avoid. Origin is detected
via debug.getinfo on the registered function: only wrap when the source
path contains "CommonSenseLight" or a "/CSR_" / "\\CSR_" segment.

B42.15+ note: do not pcall the handler. Some context-menu handlers call
Java methods, and catching those Java exceptions in Lua can corrupt Kahlua's
call-frame state for the rest of the session.
]]

if not Events or not Events.OnFillWorldObjectContextMenu then return end

CSR_AA_InteropGuard = CSR_AA_InteropGuard or {}

local function playerFromArg(playerOrNum)
    if playerOrNum and playerOrNum.getX and playerOrNum.getY then
        return playerOrNum
    end
    local playerNum = tonumber(playerOrNum) or 0
    if getSpecificPlayer then return getSpecificPlayer(playerNum) end
    return nil
end

function CSR_AA_InteropGuard.isInForeignInteriorCell(playerOrNum)
    local p = playerFromArg(playerOrNum)
    if not p then return false end
    local x, y = p:getX(), p:getY()
    -- ProjectRV interior cell (X>22500 & Y>12000) and similar far-cell
    -- foreign interiors. Anything that far out is not vanilla world.
    if x and y and x > 22500 and y > 12000 then return true end
    return false
end

local function isInForeignInteriorCell(playerNum)
    return CSR_AA_InteropGuard.isInForeignInteriorCell(playerNum)
end

local function isCSROrigin(fn)
    if type(fn) ~= "function" then return false end
    if not debug or not debug.getinfo then return false end
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or not info or not info.source then return false end
    local src = tostring(info.source):lower()
    if src:find("CommonSenseLight", 1, true) then return true end
    if src:find("/csr_", 1, true) or src:find("\\csr_", 1, true) then return true end
    local norm = src:gsub("\\", "/")
    local base = norm:match("([^/]+)$") or norm
    if base:sub(1, 4) == "csr_" then return true end
    return false
end

local origAdd = Events.OnFillWorldObjectContextMenu.Add

-- Rare escape hatch for CSR compatibility handlers that must run inside the
-- foreign interior cell they are protecting. Use sparingly.
function CSR_AA_InteropGuard.addForeignInteriorContextHandler(fn)
    return origAdd(fn)
end

Events.OnFillWorldObjectContextMenu.Add = function(fn)
    if not isCSROrigin(fn) then
        return origAdd(fn)
    end
    local wrapped = function(playerNum, context, worldobjects, test)
        if isInForeignInteriorCell(playerNum) then return end
        return fn(playerNum, context, worldobjects, test)
    end
    return origAdd(wrapped)
end

