-- Stops the cursor from being yanked back to camera look (and then reappearing at screen centre)
-- while the inventory is open under Project Viewpoint.
--
-- Viewpoint frees the cursor itself when the inventory opens. Project Viewpoint QOL marks the cursor
-- as "unlocked by me" whenever a context menu / popup / radial shows, even if it was already free,
-- then re-locks it when that menu closes. With the inventory still open that drops you back into
-- camera look, and Viewpoint puts the cursor at screen centre the next time it is freed.
--
-- Fix: QOL may only re-lock a cursor that QOL itself unlocked. All of QOL's lock/unlock calls go
-- through the ViewpointQOL bridge table, so wrap those two functions.
local done, ticks = false, 0
local owns = false
local isFree

local function cursorFree()
    if not isFree then return false end
    local ok, free = pcall(isFree)
    return ok and free == true
end

local function install()
    if done then return true end
    local b = rawget(_G, "ViewpointQOL")
    if type(b) ~= "table" then return false end
    if type(b.lockMouse) ~= "function" or type(b.unlockMouse) ~= "function"
        or type(b.isCursorMode) ~= "function" then
        return false
    end
    local lock, unlock = b.lockMouse, b.unlockMouse
    isFree = b.isCursorMode

    b.unlockMouse = function(...)
        if not cursorFree() then owns = true end
        return unlock(...)
    end
    b.lockMouse = function(...)
        -- Free, but not freed by QOL: Viewpoint (inventory) or the player (cursor key) did it. Leave it.
        if cursorFree() and not owns then return end
        owns = false
        return lock(...)
    end

    if b.lockMouse == lock then return false end -- bridge table is read-only; nothing we can do
    done = true
    print("[VPCursorKeep] installed: QOL no longer re-locks a cursor it did not unlock")
    return true
end

local function tick()
    if not done then
        ticks = ticks + 1
        if ticks % 30 == 0 then install() end
        if ticks > 900 then
            Events.OnTick.Remove(tick)
            print("[VPCursorKeep] Project Viewpoint QOL bridge not found; nothing to do")
        end
        return
    end
    -- Viewpoint re-locked on its own (inventory closed, cursor key): QOL's claim is over.
    if owns and not cursorFree() then owns = false end
end

Events.OnGameStart.Add(function()
    ticks = 0
    owns = false
    install()
    Events.OnTick.Remove(tick)
    Events.OnTick.Add(tick)
end)
