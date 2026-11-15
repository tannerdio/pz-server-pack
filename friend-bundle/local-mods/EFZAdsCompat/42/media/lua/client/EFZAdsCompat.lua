-- Makes Project Viewpoint ADS ignore Escape From Zomboid Firearms guns, so only the gun mod's own
-- first-person pose / sights drive the arms. Vanilla and other-mod guns keep Project Viewpoint ADS.
-- PVADS decides "is there a firearm in hand" in PVADS.Controller.weapon; returning nil there makes it
-- clear its profile and never raise its sights for that gun.
local PREFIX = "EscapeFromZomboidFirearms."
local done, ticks = false, 0

local function isEFZ(item)
    if not item or not item.getFullType then return false end
    local ft = item:getFullType()
    return ft ~= nil and string.find(ft, PREFIX, 1, true) == 1
end

local function heldEFZ()
    local pl = getSpecificPlayer(0)
    return pl ~= nil and isEFZ(pl:getPrimaryHandItem())
end

local function install()
    if done then return true end
    local C = PVADS and PVADS.Controller
    if not C or type(C.weapon) ~= "function" then return false end
    local weapon = C.weapon
    C.weapon = function(pl)
        local w = weapon(pl)
        if isEFZ(w) then return nil end
        return w
    end
    -- PVADS' weapon-collision pass moves the gun and arms on its own each tick: skip it for these guns too.
    local presence = rawget(_G, "PVADS_presenceTick")
    if type(presence) == "function" then
        PVADS_presenceTick = function(...)
            if heldEFZ() then return end
            return presence(...)
        end
    end
    C.dirty = true
    done = true
    print("[EFZAdsCompat] Project Viewpoint ADS now ignores Escape From Zomboid Firearms guns")
    return true
end

local function tick()
    ticks = ticks + 1
    -- wait for PVADS' own OnGameStart init (it binds its Java functions there)
    if ticks < 60 then return end
    if install() or ticks > 600 then
        Events.OnTick.Remove(tick)
        if not done then print("[EFZAdsCompat] Project Viewpoint ADS not found; nothing to do") end
    end
end

Events.OnGameStart.Add(function() done = false; ticks = 0; Events.OnTick.Add(tick) end)
