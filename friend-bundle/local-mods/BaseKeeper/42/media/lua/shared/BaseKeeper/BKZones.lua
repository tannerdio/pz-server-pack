-- Base Keeper: zone store. Rectangles live in global ModData ("BaseKeeperZones"), the same mechanism vanilla
-- uses for foraging zones (forageServer.lua). Ends are exclusive: a zone covers x1 <= x < x2, y1 <= y < y2 at z.
-- Fires Lua events BaseKeeper_ZoneAdded(zone) and BaseKeeper_ZoneRemoved(zone) so other files never poll this table.
require "BaseKeeper/BKLog"

BKZones = BKZones or {}

BKZones.MODDATA_KEY = "BaseKeeperZones"
BKZones.MIN_SIDE = 2
BKZones.MAX_SIDE = 60
BKZones.ALL_FLOORS = true     -- a zone covers its footprint on every floor (false = only the floor it was marked on)
BKZones.FLOOR_SPAN = 8        -- levels probed above and below the marked floor
BKZones.FLOOR_CACHE_MS = 60000
BKZones.FLOOR_RETRY_MS = 5000 -- how long a probe of a zone that is not loaded is kept
BKZones.floorCache = {}

BKZones.data = nil -- { nextId = n, zones = { ["z1"] = zone, ... } }

LuaEventManager.AddEvent("BaseKeeper_ZoneAdded")
LuaEventManager.AddEvent("BaseKeeper_ZoneRemoved")

local function store()
    if BKZones.data == nil then
        BKZones.data = ModData.getOrCreate(BKZones.MODDATA_KEY)
    end
    local d = BKZones.data
    if d.nextId == nil then d.nextId = 1 end
    if d.zones == nil then d.zones = {} end
    return d
end

function BKZones.init()
    local d = store()
    local count = 0
    for _ in pairs(d.zones) do count = count + 1 end
    BKLog.info("zones loaded: " .. count)
end

function BKZones.list()
    local out = {}
    for _, zone in pairs(store().zones) do table.insert(out, zone) end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function BKZones.get(id)
    return store().zones[tostring(id)]
end

function BKZones.contains(zone, x, y, z)
    return (BKZones.ALL_FLOORS or z == zone.z) and x >= zone.x1 and x < zone.x2 and y >= zone.y1 and y < zone.y2
end

-- v0.16.0 (Tanner: "consider every floor in the base zone"): a zone is its x/y footprint on every floor. floors()
-- lists the levels that have at least one loaded square inside the footprint (the marked floor first), probed
-- FLOOR_SPAN levels up and down and remembered for FLOOR_CACHE_MS. Rectangles that are not stored zones (the
-- "area12" pseudo rects other files scan) stay on their one floor.
function BKZones.floors(zone)
    if not BKZones.ALL_FLOORS or type(zone.id) ~= "number" then return { zone.z } end
    local key = tostring(zone.id)
    local now = getTimestampMs and getTimestampMs() or 0
    local hit = BKZones.floorCache[key]
    if hit and now - hit.at < BKZones.FLOOR_CACHE_MS and hit.x1 == zone.x1 and hit.y1 == zone.y1 then return hit.list end
    local cell = getCell()
    local list = { zone.z }
    if cell == nil then return list end
    -- v0.18.2: each other floor also gets the box around the tiles that really exist there (a basement is far
    -- smaller than the footprint), which is what the overlay draws on that floor
    local boxes = { [zone.z] = { x1 = zone.x1, y1 = zone.y1, x2 = zone.x2, y2 = zone.y2 } }
    for z = math.max(-32, zone.z - BKZones.FLOOR_SPAN), math.min(31, zone.z + BKZones.FLOOR_SPAN) do
        if z ~= zone.z then
            local bx1, by1, bx2, by2 = nil, nil, nil, nil
            for x = zone.x1, zone.x2 - 1 do
                for y = zone.y1, zone.y2 - 1 do
                    if cell:getGridSquare(x, y, z) then
                        if bx1 == nil then
                            bx1, by1, bx2, by2 = x, y, x + 1, y + 1
                        else
                            if x < bx1 then bx1 = x end
                            if y < by1 then by1 = y end
                            if x + 1 > bx2 then bx2 = x + 1 end
                            if y + 1 > by2 then by2 = y + 1 end
                        end
                    end
                end
            end
            if bx1 ~= nil then
                table.insert(list, z)
                boxes[z] = { x1 = bx1, y1 = by1, x2 = bx2, y2 = by2 }
            end
        end
    end
    -- a probe made while the zone is not loaded is only kept a few seconds, so coming home never waits on a stale
    -- one-floor answer (and the overlay, which asks every frame, never re-probes every frame)
    local cx, cy = BKZones.center(zone)
    local loaded = cell:getGridSquare(cx, cy, zone.z) ~= nil
    BKZones.floorCache[key] = { at = loaded and now or (now - BKZones.FLOOR_CACHE_MS + BKZones.FLOOR_RETRY_MS),
        list = list, boxes = boxes, x1 = zone.x1, y1 = zone.y1 }
    return list
end

-- The part of the zone that exists on floor z: the marked rectangle on its own floor, the box around the real
-- tiles on any other floor, nil when the zone has nothing there.
function BKZones.floorBox(zone, z)
    if not BKZones.ALL_FLOORS or type(zone.id) ~= "number" then
        if z == zone.z then return zone end
        return nil
    end
    BKZones.floors(zone)
    local hit = BKZones.floorCache[tostring(zone.id)]
    return hit and hit.boxes and hit.boxes[z] or nil
end

-- "-1, 0, +1" (lowest first)
function BKZones.floorsText(zone)
    local list = {}
    for _, z in ipairs(BKZones.floors(zone)) do table.insert(list, z) end
    table.sort(list)
    local parts = {}
    for _, z in ipairs(list) do table.insert(parts, (z > 0 and "+" or "") .. tostring(z)) end
    return table.concat(parts, ", ")
end

-- First zone covering the tile, or nil.
function BKZones.at(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    for _, zone in pairs(store().zones) do
        if BKZones.contains(zone, x, y, z) then return zone end
    end
    return nil
end

function BKZones.overlaps(zone, x1, y1, x2, y2, z)
    return (BKZones.ALL_FLOORS or zone.z == z) and x1 < zone.x2 and x2 > zone.x1 and y1 < zone.y2 and y2 > zone.y1
end

function BKZones.center(zone)
    return math.floor((zone.x1 + zone.x2) / 2), math.floor((zone.y1 + zone.y2) / 2), zone.z
end

function BKZones.width(zone) return zone.x2 - zone.x1 end
function BKZones.height(zone) return zone.y2 - zone.y1 end

function BKZones.describe(zone)
    return string.format("id=%s x=%d y=%d w=%d h=%d z=%d",
        tostring(zone.id), zone.x1, zone.y1, BKZones.width(zone), BKZones.height(zone), zone.z)
end

local function validate(x1, y1, x2, y2, z)
    if x2 <= x1 or y2 <= y1 then return false, "empty rectangle" end
    local w, h = x2 - x1, y2 - y1
    if w < BKZones.MIN_SIDE or h < BKZones.MIN_SIDE then return false, "too small (min " .. BKZones.MIN_SIDE .. ")" end
    if w > BKZones.MAX_SIDE or h > BKZones.MAX_SIDE then return false, "too large (max " .. BKZones.MAX_SIDE .. ")" end
    for _, zone in pairs(store().zones) do
        if BKZones.overlaps(zone, x1, y1, x2, y2, z) then return false, "overlaps zone " .. tostring(zone.id) end
    end
    return true
end

-- Authority-side add. Returns zone or nil, reason.
function BKZones.add(x1, y1, x2, y2, z, ownerName)
    x1, y1, x2, y2, z = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), math.floor(z)
    local ok, reason = validate(x1, y1, x2, y2, z)
    if not ok then
        BKLog.warn("zone rejected: " .. reason)
        return nil, reason
    end
    local d = store()
    local zone = {
        id = d.nextId,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z,
        owner = ownerName,
        createdAt = getGameTime() and getGameTime():getWorldAgeHours() or 0,
    }
    d.nextId = d.nextId + 1
    d.zones[tostring(zone.id)] = zone
    BKLog.info("zone added " .. BKZones.describe(zone))
    if isServer() then ModData.transmit(BKZones.MODDATA_KEY) end
    triggerEvent("BaseKeeper_ZoneAdded", zone)
    return zone
end

function BKZones.remove(id)
    local d = store()
    local key = tostring(id)
    local zone = d.zones[key]
    if zone == nil then return false end
    d.zones[key] = nil
    BKLog.info("zone removed " .. BKZones.describe(zone))
    if isServer() then ModData.transmit(BKZones.MODDATA_KEY) end
    triggerEvent("BaseKeeper_ZoneRemoved", zone)
    return true
end

-- Called by the client UI. Single-player: same Lua state, add directly. Multiplayer client: ask the server.
function BKZones.requestAdd(player, x1, y1, x2, y2, z)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "addZone", { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z })
        return nil
    end
    local name = player and player.getUsername and player:getUsername() or nil
    return BKZones.add(x1, y1, x2, y2, z, name)
end

function BKZones.requestRemove(player, id)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "removeZone", { id = id })
        return
    end
    BKZones.remove(id)
end

-- Multiplayer plumbing (server receives UI requests; clients receive the transmitted table).
local function onClientCommand(module, command, player, args)
    if module ~= "BaseKeeper" or type(args) ~= "table" then return end
    if command == "addZone" then
        local x1, y1, x2, y2, z = tonumber(args.x1), tonumber(args.y1), tonumber(args.x2), tonumber(args.y2), tonumber(args.z)
        if x1 and y1 and x2 and y2 and z then
            BKZones.add(x1, y1, x2, y2, z, player and player:getUsername() or nil)
        end
    elseif command == "removeZone" then
        if tonumber(args.id) then BKZones.remove(tonumber(args.id)) end
    end
end

local function onReceiveGlobalModData(key, data)
    if key ~= BKZones.MODDATA_KEY or type(data) ~= "table" then return end
    if ModData.add then ModData.add(key, data) end
    BKZones.data = data
    BKZones.init()
end

function BKZones.sync()
    if isServer() then ModData.transmit(BKZones.MODDATA_KEY) end
end

Events.OnInitGlobalModData.Add(function()
    BKZones.data = nil
    BKZones.init()
    if isClient() and ModData.request then ModData.request(BKZones.MODDATA_KEY) end
end)
if isServer() then Events.OnClientCommand.Add(onClientCommand) end
if isClient() then Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData) end

return BKZones
