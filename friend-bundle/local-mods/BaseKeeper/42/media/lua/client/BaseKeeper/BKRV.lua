-- Base Keeper: RV interiors ([B42] PROJECT RV Interior, mod id PROJECTRVInterior42).
-- The interior of an RV is a small room on ordinary map tiles far off the map, one room per vehicle. The first time
-- the player enters one, a Base Keeper zone is marked over that room, so the RV is a base like any other.
-- Each room is offered once (ModData "BaseKeeperRV"): a zone the player removes is not marked again.
-- The vehicle itself (trunk, glove box, seats) stays untouched, as for every vehicle.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"

BKRV = BKRV or {}

BKRV.MODDATA_KEY = "BaseKeeperRV"
BKRV.registered = false

local function store()
    local d = ModData.getOrCreate(BKRV.MODDATA_KEY)
    if d.rooms == nil then d.rooms = {} end
    return d
end

-- Room rectangle (exclusive ends) from the RV mod's hook context.
function BKRV.rect(ctx)
    local room, def = ctx.room, ctx.typeDef
    if type(room) ~= "table" or type(def) ~= "table" then return nil end
    local x, y, z = tonumber(room.x), tonumber(room.y), tonumber(room.z) or 0
    local w, h = math.abs(tonumber(def.roomWidth) or 0), math.abs(tonumber(def.roomHeight) or 0)
    if not x or not y or w < BKZones.MIN_SIDE or h < BKZones.MIN_SIDE then return nil end
    return x, y, x + w, y + h, z
end

function BKRV.onEnter(ctx)
    if type(ctx) ~= "table" then return end
    local x1, y1, x2, y2, z = BKRV.rect(ctx)
    if not x1 then
        BKLog.warn("rv: no room rectangle in the hook context")
        return
    end
    local key = x1 .. "," .. y1 .. "," .. z
    local d = store()
    if d.rooms[key] then return end
    d.rooms[key] = true
    if BKZones.at(x1, y1, z) then
        BKLog.info("rv: room " .. key .. " already has a zone")
        return
    end
    local zone = BKZones.requestAdd(ctx.player, x1, y1, x2, y2, z)
    if zone then
        BKLog.info("rv: zone " .. tostring(zone.id) .. " marked over RV interior " .. key .. " (" .. tostring(ctx.typeKey) .. ")")
        if ctx.player and HaloTextHelper then
            pcall(HaloTextHelper.addText, ctx.player, "Base Keeper: RV zone " .. tostring(zone.id) .. " marked")
        end
    elseif not isClient() then
        BKLog.warn("rv: could not mark a zone over room " .. key)
    end
end

-- The RV mod may load after this file, so its hook table is looked up when the game starts.
local function register()
    if BKRV.registered then return end
    if type(RVHooks) ~= "table" or type(RVHooks.register) ~= "function" then return end
    BKRV.registered = true
    RVHooks.register("postEnter", function(ctx)
        BKLog.try("rv enter", BKRV.onEnter, ctx)
        return nil
    end)
    BKLog.info("rv: RV Interior found, interiors become zones on first entry")
end

Events.OnGameStart.Add(register)

return BKRV
