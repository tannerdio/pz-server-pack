-- Base Keeper: layout planner ("Zone Theory", v0.13.0, Tanner 2026-11-06: "have it intelligently set it up like i am
-- asking for whatever square i setup, if i put this in any house it would work the same way").
--
-- Given a zone, every storage container tile gets a role (one or more loot categories) from
--   1. the room it stands in (BKPlaces: garage, kitchen, bathroom, laundry, bedroom, office, living, armory, storage),
--   2. where it stands in that room relative to the room's main entrance: depth (categories used least go to the
--      back, daily ones by the door) and side (standing in the doorway looking in: in a garage the left and middle
--      are workshop, building and farm gear, the right is cleaning, electronics and bags),
--   3. how well its container type fits the category (BKRules, normalised per category so a crate full of guns is
--      not outscored by a crate of nails), what it already holds (the share of the base's stock of that category on
--      the tile: "guns like they already are, ammo where it is") and how much of the category the zone owns
--      (demand = stock x HEADROOM, so 2 kg of ammo never claims three crates).
-- The plan is applied as section roles (BKSections, per container tile, ModData), optionally removing the loot areas
-- inside the zone. Roles are strict (BKSections.STRICT): a container with a role refuses a category that has a home
-- elsewhere in the zone; a category with no home anywhere still follows the default rules. Cold storage, bins,
-- appliances, personal areas and locked containers are never planned (their rules already exist).
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/BKSections"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlaces"
require "BaseKeeper/Engine/BKRules"
require "BaseKeeper/Engine/BKTaxonomy"

BKLayout = BKLayout or {}

BKLayout.HEADROOM = 1.4        -- a category wants this much capacity per kg the zone holds now
BKLayout.FIT_W = 5             -- weight of the container-type fit (normalised 0..1 per category and wing)
BKLayout.DEPTH_W = 4           -- weight of the position preference (0..1)
BKLayout.CONTENT_W = 8         -- weight of "already holds it" (share of the base's stock of the category, 0..1)
BKLayout.SIZE_PENALTY = 2      -- taken once when a tile holds 4x more than the category needs, twice at 10x
BKLayout.FAMILY_AFFINITY = 4   -- a secondary category prefers a tile whose role is in the same family (bombs with guns)
BKLayout.RIGHT_SHARE = 2 / 3   -- the right wing is the right-most third of the room's storage span
BKLayout.MIN_LATERAL = 3       -- rooms whose storage spans fewer tiles sideways have no right wing
BKLayout.GENERIC_FIT = 0.5     -- a generic container with no rule for the category still fits a little
BKLayout.lastPlan = {}         -- zoneId -> plan (overlay + menu), cleared when applied

-- How often a category is reached for: 1 = daily (by the door), 2 = sometimes, 3 = rarely (the back). Default 2.
BKLayout.USAGE = {
    tool = 1, build_material = 1, ["g:carpentry"] = 1, ["g:cleaning"] = 1, cooking = 1, food_shelf = 1, drink = 1,
    ["g:food_spice"] = 1, ["g:drink_hot"] = 1, medical = 1, ["g:hygiene"] = 1, clothing = 1, literature = 1, fuel = 1,
    ["g:fire"] = 1,
    mechanics = 2, electronics = 2, ["g:gardening"] = 2, ["g:farm_feed"] = 2, ["g:farm_animal"] = 2, container = 2,
    ["g:lighting"] = 2, ["g:firewood"] = 2, ["g:sewing"] = 2, ["g:household"] = 2, ["g:media"] = 2, empties = 2,
    depleted = 2, ["g:fishing"] = 2, ["g:tobacco"] = 2, ["g:stationery"] = 2, ["g:lit_map"] = 2, ["g:food_snack"] = 2,
    weapon = 3, ammo = 3, ["g:armor"] = 3, ["g:explosive"] = 3, junk = 3, other = 3, ["g:camping"] = 3,
    ["g:trapping"] = 3, ["g:toys"] = 3, ["g:memento"] = 3, ["g:valuables"] = 3, ["g:instrument"] = 3,
}

-- Room policies by inferred place. "left"/"right" are the wings seen from the main entrance; "any" has no side.
-- A key ending in "?" is secondary: it never claims a tile of its own, it is added to the best-fitting tile of a
-- room that lists it when nothing else in the zone gives it a home.
BKLayout.ROOMS = {
    garage = { order = 1,
        left = { "tool", "build_material", "g:gardening", "mechanics", "fuel", "weapon", "ammo",
                 "g:farm_feed?", "g:farm_animal?", "g:firewood?", "g:fishing?", "g:trapping?", "g:camping?", "g:armor?", "g:explosive?" },
        right = { "g:cleaning", "electronics", "container", "g:lighting", "empties", "junk", "other", "depleted?" } },
    kitchen = { order = 2,
        any = { "cooking", "food_shelf", "g:food_spice", "drink", "g:drink_hot?", "g:food_snack?", "g:fire?" } },
    bathroom = { order = 3, any = { "medical", "g:hygiene" } },
    laundry = { order = 4, any = { "clothing", "g:sewing?", "g:household?", "g:cleaning?" } },
    armory = { order = 5, any = { "weapon", "ammo", "g:armor", "g:explosive?" } },
    office = { order = 6, any = { "literature", "g:stationery?", "g:lit_map?", "g:media?", "electronics?" } },
    living = { order = 7,
        any = { "literature", "g:media?", "g:toys?", "g:instrument?", "g:memento?", "g:valuables?", "g:tobacco?", "electronics?" } },
    bedroom = { order = 8, any = { "clothing", "g:household?", "g:hygiene?", "g:toys?" } },
    storage = { order = 9,
        any = { "build_material", "tool", "container", "junk", "other", "g:gardening?", "g:farm_feed?", "g:farm_animal?",
                "fuel?", "mechanics?", "empties?", "depleted?", "weapon?", "ammo?", "clothing?", "electronics?",
                "g:cleaning?", "literature?", "medical?", "food_shelf?", "cooking?", "drink?" } },
}

local function tileKey(x, y, z) return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) end

local function parseEntry(entry)
    if string.sub(entry, -1) == "?" then return string.sub(entry, 1, -2), true end
    return entry, false
end

local function usageOf(key) return BKLayout.USAGE[key] or 2 end

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function weightOf(item)
    local w = safe(function() return item:getActualWeight() end)
    if tonumber(w) then return tonumber(w) end
    w = safe(function() return item:getWeight() end)
    return tonumber(w) or 0
end

-- every category key an item answers to among the keys this plan uses
local function itemKeys(item, used)
    local class, _, _, group = BKItemClass.classify(item)
    local out = {}
    if BKSections.CLASS_CAT[class] and used[BKSections.CLASS_CAT[class]] then table.insert(out, BKSections.CLASS_CAT[class]) end
    if group and BKSections.GROUP_CAT[group] and used[BKSections.GROUP_CAT[group]] then table.insert(out, BKSections.GROUP_CAT[group]) end
    return out
end

local function plannable(c)
    return not c.noDest and not c.locked and not c.personal and not BKSections.SKIP_TYPES[c.ctype]
        and BKRules.isSortable(c.ctype)
end

local function roomIdOf(sq)
    if sq == nil then return nil end
    local id = safe(function() return sq:getRoomID() end)
    id = tonumber(id)
    if id and id >= 0 then return id end
    return nil
end

local function roomPlaceByName(name)
    if not name then return nil end
    for _, pair in ipairs(BKPlaces.ROOM_WORDS) do
        if string.find(name, pair[1], 1, true) then return pair[2] end
    end
    return nil
end

-- How well a tile fits a category: the best BKRules score over its containers (class rules, or the fine group's
-- own container preferences), the way BKSections.fit scores a section. 0 = no container on the tile may take it.
local function fitOf(cat, tile)
    local best, generic = 0, false
    for _, c in ipairs(tile.containers) do
        if BKRules.GENERIC_TYPES[c.ctype] then generic = true end
        for _, cls in ipairs(cat.classes or {}) do
            local v = BKRules.score(cls, c)
            if v > best then best = v end
        end
        for _, g in ipairs(cat.groups or {}) do
            local def = BKTaxonomy.get(g)
            local cls = def and def.class or "other"
            if cls == "food" then cls = "food_dry" end
            local v = BKRules.score(cls, c, g)
            if v > best then best = v end
        end
    end
    if best <= 0 and generic then return BKLayout.GENERIC_FIT end
    return best
end

local function depthPref(usage, depthNorm)
    if usage >= 3 then return depthNorm end
    if usage <= 1 then return 1 - depthNorm end
    return 1 - math.abs(depthNorm - 0.5) * 2
end

-- Rooms --------------------------------------------------------------------------------------------------------

-- Groups the plannable containers of the scan by room (room id when the map has one, else the room name) into
-- tiles. Returns a list of rooms { id, name, place, tiles = {tile...} } in policy order.
local function collectRooms(scan)
    local rooms, order = {}, {}
    for _, c in ipairs(scan.containers) do
        if plannable(c) then
            local rid = roomIdOf(c.square)
            local roomKey = rid and ("id" .. tostring(rid)) or ("name:" .. tostring(c.room or "outside") .. ":" .. tostring(c.z))
            local room = rooms[roomKey]
            if room == nil then
                room = { key = roomKey, id = rid, name = c.room or "outside", tiles = {}, tileMap = {}, placeVotes = {} }
                rooms[roomKey] = room
                table.insert(order, room)
            end
            room.placeVotes[c.place or "storage"] = (room.placeVotes[c.place or "storage"] or 0) + 1
            local tk = tileKey(c.x, c.y, c.z)
            local tile = room.tileMap[tk]
            if tile == nil then
                tile = { key = tk, x = c.x, y = c.y, z = c.z, containers = {}, cap = 0, catW = {}, totalW = 0, keys = {} }
                room.tileMap[tk] = tile
                table.insert(room.tiles, tile)
            end
            table.insert(tile.containers, c)
            tile.cap = tile.cap + (tonumber(safe(function() return c.container:getCapacity() end)) or 0)
        end
    end
    for _, room in ipairs(order) do
        local byName = roomPlaceByName(room.name)
        local place = byName
        if place == nil or place == "storage" then
            local bestP, bestN = place or "storage", 0
            for p, n in pairs(room.placeVotes) do if n > bestN then bestP, bestN = p, n end end
            place = bestP
        end
        room.place = place
        room.policy = BKLayout.ROOMS[place] or BKLayout.ROOMS.storage
        table.sort(room.tiles, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
    end
    table.sort(order, function(a, b)
        local oa, ob = a.policy.order or 99, b.policy.order or 99
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)
    return order
end

-- Entrances: a tile inside a room whose neighbour is another room or outside, with a door or an open doorway
-- between them. Returns roomId -> list of { x, y, dx, dy (outward), door = bool, outside = bool }.
local function openingTo(sq, n)
    local door = safe(function() return sq:isDoorTo(n) end)
    if door == true then return "door" end
    local d2 = safe(function() return sq:getDoorTo(n) end)
    if d2 ~= nil then return "door" end
    local okW, wall = pcall(function() return sq:isWallTo(n) end)
    local okB, blocked = pcall(function() return sq:isBlockedTo(n) end)
    if okW and okB and wall == false and blocked == false then
        local win = safe(function() return sq:isWindowBlockedTo(n) end)
        if win ~= true then return "opening" end
    end
    return nil
end

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function findEntrances(zone)
    local out = {}
    local cell = getCell()
    for _, z in ipairs(BKZones.floors(zone)) do -- v0.16.0: rooms on every floor of the zone
    for x = zone.x1, zone.x2 - 1 do
        for y = zone.y1, zone.y2 - 1 do
            local sq = cell:getGridSquare(x, y, z)
            local rid = roomIdOf(sq)
            if rid then
                for _, d in ipairs(DIRS) do
                    local n = cell:getGridSquare(x + d[1], y + d[2], z)
                    if n and roomIdOf(n) ~= rid then
                        local kind = openingTo(sq, n)
                        if kind then
                            out[rid] = out[rid] or {}
                            table.insert(out[rid], { x = x, y = y, dx = d[1], dy = d[2], door = kind == "door",
                                outside = safe(function() return n:isOutside() end) == true })
                        end
                    end
                end
            end
        end
    end
    end
    return out
end

-- The main entrance of a room: the widest run of entrance tiles with the same direction (a double garage door beats
-- a single house door), doors over open doorways, outside over inside. Returns { tiles, dx, dy, cx, cy } or nil.
local function mainEntrance(list)
    if list == nil or #list == 0 then return nil end
    local clusters = {}
    for _, e in ipairs(list) do
        local joined = nil
        for _, cl in ipairs(clusters) do
            if cl.dx == e.dx and cl.dy == e.dy then
                for _, t in ipairs(cl.tiles) do
                    if math.abs(t.x - e.x) <= 1 and math.abs(t.y - e.y) <= 1 then joined = cl; break end
                end
            end
            if joined then break end
        end
        if joined then
            table.insert(joined.tiles, e)
            if e.door then joined.door = true end
            if e.outside then joined.outside = true end
        else
            table.insert(clusters, { dx = e.dx, dy = e.dy, tiles = { e }, door = e.door, outside = e.outside })
        end
    end
    table.sort(clusters, function(a, b)
        if #a.tiles ~= #b.tiles then return #a.tiles > #b.tiles end
        if a.door ~= b.door then return a.door end
        if a.outside ~= b.outside then return a.outside end
        if a.tiles[1].y ~= b.tiles[1].y then return a.tiles[1].y < b.tiles[1].y end
        return a.tiles[1].x < b.tiles[1].x
    end)
    local m = clusters[1]
    local sx, sy = 0, 0
    for _, t in ipairs(m.tiles) do sx, sy = sx + t.x, sy + t.y end
    m.cx, m.cy = sx / #m.tiles, sy / #m.tiles
    return m
end

-- Depth (how far into the room from the main entrance) and lateral (right of the entrance is positive, standing in
-- the doorway looking in) of every tile; wings when the policy has sides and the room is wide enough.
local function geometry(room, entrance)
    room.entrance = entrance
    local maxDepth, minL, maxL = 0, nil, nil
    for _, t in ipairs(room.tiles) do
        if entrance then
            local fx, fy = -entrance.dx, -entrance.dy          -- facing into the room
            local rx, ry = -fy, fx                             -- right hand side when facing (fx, fy)
            local ox, oy = t.x - entrance.cx, t.y - entrance.cy
            t.depth = math.max(0, ox * fx + oy * fy)
            t.lateral = ox * rx + oy * ry
        else
            t.depth, t.lateral = 0, 0
        end
        if t.depth > maxDepth then maxDepth = t.depth end
        minL = minL and math.min(minL, t.lateral) or t.lateral
        maxL = maxL and math.max(maxL, t.lateral) or t.lateral
    end
    room.maxDepth = maxDepth
    local span = (maxL or 0) - (minL or 0)
    local sided = room.policy.left ~= nil and entrance ~= nil and span >= BKLayout.MIN_LATERAL
    for _, t in ipairs(room.tiles) do
        t.depthNorm = maxDepth > 0 and (t.depth / maxDepth) or 0
        if sided then
            t.wing = (t.lateral > minL + BKLayout.RIGHT_SHARE * span) and "right" or "left"
        else
            t.wing = "any"
        end
    end
    room.sided = sided
end

-- Demand and contents ------------------------------------------------------------------------------------------

local function entriesOf(room)
    local out = {}
    local function add(list, wing)
        for _, entry in ipairs(list or {}) do
            local key, secondary = parseEntry(entry)
            local cat = BKLoot.category(key)
            if cat and not cat.personal then
                table.insert(out, { key = key, cat = cat, secondary = secondary, wing = wing, order = #out + 1, usage = usageOf(key) })
            end
        end
    end
    if room.sided then
        add(room.policy.left, "left")
        add(room.policy.right, "right")
    else
        add(room.policy.any, "any")
        add(room.policy.left, "any")
        add(room.policy.right, "any")
    end
    return out
end

-- kg per category key over every stock container and the floor of the zone (what the base holds, wherever it sits)
local function stockByKey(scan, used)
    local out = {}
    local function addItem(item)
        local w = weightOf(item)
        for _, k in ipairs(itemKeys(item, used)) do out[k] = (out[k] or 0) + w end
    end
    for _, c in ipairs(scan.containers) do
        if not (c.ctype == "bin" or c.ctype == "dumpster" or c.ctype == "composter") and not c.personal then
            local items = safe(function() return c.container:getItems() end)
            if items then
                for i = 0, items:size() - 1 do addItem(items:get(i)) end
            end
        end
    end
    for _, f in ipairs(scan.floorItems) do if not f.personal then addItem(f.item) end end
    return out
end

local function tileContents(tile, used)
    for _, c in ipairs(tile.containers) do
        local items = safe(function() return c.container:getItems() end)
        if items then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local w = weightOf(item)
                tile.totalW = tile.totalW + w
                for _, k in ipairs(itemKeys(item, used)) do tile.catW[k] = (tile.catW[k] or 0) + w end
            end
        end
    end
end

local function typesText(tile)
    local counts, parts = {}, {}
    for _, c in ipairs(tile.containers) do counts[c.ctype] = (counts[c.ctype] or 0) + 1 end
    for t, n in pairs(counts) do table.insert(parts, (n > 1 and (tostring(n) .. "x ") or "") .. t) end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- Assignment ---------------------------------------------------------------------------------------------------

-- share of the base's stock of the category that already sits on the tile (0..1)
local function heldShare(e, tile, stock)
    local have = stock[e.key] or 0
    if have <= 0 then return 0 end
    return math.min(1, (tile.catW[e.key] or 0) / have)
end

-- fit normalised against the best fit the category can get in this wing, position, contents, oversize penalty
local function scoreFor(e, tile, stock, need, bestFit)
    local fit = fitOf(e.cat, tile)
    if fit <= 0 then return nil, 0 end
    local s = BKLayout.FIT_W * (fit / math.max(bestFit[e.key] or fit, 0.001))
        + BKLayout.DEPTH_W * depthPref(e.usage, tile.depthNorm)
        + BKLayout.CONTENT_W * heldShare(e, tile, stock)
    local n = math.max(need[e.key] or 0, 1)
    if tile.cap > 10 * n then s = s - 2 * BKLayout.SIZE_PENALTY
    elseif tile.cap > 4 * n then s = s - BKLayout.SIZE_PENALTY end
    return s, fit
end

local function why(e, tile, fit, stock)
    local parts = { string.format("fit %.0f", fit) }
    local held = heldShare(e, tile, stock)
    if held >= 0.2 then table.insert(parts, string.format("holds %d%% of the base's", math.floor(held * 100))) end
    if e.usage >= 3 then table.insert(parts, "rarely used: the back")
    elseif e.usage <= 1 then table.insert(parts, "daily: by the door") end
    return table.concat(parts, ", ")
end

-- Gives the tiles of one wing their primary roles. need[key] is zone-wide and shared across rooms. Best
-- (category, tile) pair first: round 0 gives every stocked category one tile, round 1 lets a category keep taking
-- tiles while it is under its fair share of the wing's capacity, round 2 gives whatever still needs room the best
-- tiles left, and spare tiles extend the nearest run. Position and contents live in the score, so rarely used
-- categories still end up at the back and "already holds it" still wins.
local function assignWing(tiles, entries, need, stock)
    local prim = {}
    for _, e in ipairs(entries) do
        if not e.secondary and (need[e.key] or 0) > 0 then table.insert(prim, e) end
    end
    local free = {}
    for _, t in ipairs(tiles) do table.insert(free, t) end
    local sumDemand, wingCap, fair, taken, count, bestFit = 0, 0, {}, {}, {}, {}
    for _, e in ipairs(prim) do sumDemand = sumDemand + need[e.key] end
    for _, t in ipairs(tiles) do wingCap = wingCap + t.cap end
    for _, e in ipairs(prim) do
        fair[e.key] = sumDemand > 0 and (wingCap * need[e.key] / sumDemand) or 0
        taken[e.key], count[e.key] = 0, 0
        local bf = 0
        for _, t in ipairs(tiles) do
            local f = fitOf(e.cat, t)
            if f > bf then bf = f end
        end
        bestFit[e.key] = bf
    end
    local function bestPair(round)
        local best = nil
        for _, e in ipairs(prim) do
            local open = need[e.key] > 0
            if round == 0 then open = open and count[e.key] == 0
            elseif round == 1 then open = open and taken[e.key] < fair[e.key] end
            if open then
                for _, t in ipairs(free) do
                    local s, f = scoreFor(e, t, stock, need, bestFit)
                    if s and (best == nil or s > best.s or (s == best.s and e.order < best.e.order)) then
                        best = { e = e, t = t, s = s, f = f }
                    end
                end
            end
        end
        return best
    end
    local function give(pair)
        local t, e = pair.t, pair.e
        t.keys = { e.key }
        t.why = why(e, t, pair.f, stock)
        need[e.key] = need[e.key] - t.cap
        taken[e.key] = taken[e.key] + t.cap
        count[e.key] = count[e.key] + 1
        for i, ft in ipairs(free) do if ft == t then table.remove(free, i); break end end
    end
    for round = 0, 2 do
        while #free > 0 do
            local pair = bestPair(round)
            if pair == nil then break end
            give(pair)
        end
    end
    -- leftover tiles extend the nearest run with a role (same wing), else the wing's first category
    for _, t in ipairs(free) do
        local nearT, nearD = nil, nil
        for _, o in ipairs(tiles) do
            if #o.keys > 0 and o ~= t then
                local d = math.max(math.abs(o.x - t.x), math.abs(o.y - t.y))
                if nearD == nil or d < nearD then nearT, nearD = o, d end
            end
        end
        if nearT then
            t.keys = {}
            for _, k in ipairs(nearT.keys) do table.insert(t.keys, k) end
            t.why = string.format("spare, joins %d,%d", nearT.x, nearT.y)
        elseif prim[1] or entries[1] then
            t.keys = { (prim[1] or entries[1]).key }
            t.why = "spare, nothing in stock yet"
        end
    end
end

local function familyOfKey(key)
    local cat = BKLoot.category(key)
    return cat and cat.family or "misc"
end

-- Every listed category without a home in the zone is added to the best-fitting tile of a room that lists it
-- (secondary keys included), so a future find always has somewhere to go. Same family on the tile and the right
-- wing both count for it.
local function secondaryPass(rooms, homes, lines)
    local missing = {}
    for _, room in ipairs(rooms) do
        for _, e in ipairs(room.entries) do
            if not homes[e.key] and not missing[e.key] then missing[e.key] = e end
        end
    end
    local keys = {}
    for k in pairs(missing) do table.insert(keys, k) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local e = missing[key]
        local fam = e.cat.family or "misc"
        local bestT, bestS, bestRoom = nil, -1, nil
        for _, room in ipairs(rooms) do
            local wing = nil
            for _, re in ipairs(room.entries) do if re.key == key then wing = re.wing end end
            if wing then
                for _, t in ipairs(room.tiles) do
                    local fit = fitOf(e.cat, t)
                    if fit > 0 then
                        local s = fit - 0.3 * #t.keys + ((wing == "any" or t.wing == wing) and 1 or 0)
                        for _, k in ipairs(t.keys) do
                            if familyOfKey(k) == fam then s = s + BKLayout.FAMILY_AFFINITY; break end
                        end
                        if s > bestS then bestT, bestS, bestRoom = t, s, room end
                    end
                end
            end
        end
        if bestT then
            table.insert(bestT.keys, key)
            homes[key] = true
            table.insert(lines, string.format("  + %s joins %s @%d,%d (%s)", e.cat.label, bestRoom.name, bestT.x, bestT.y,
                e.secondary and "secondary" or "nothing in stock"))
        else
            table.insert(lines, string.format("  no home for %s: default rules", e.cat.label))
        end
    end
end

-- Plan ---------------------------------------------------------------------------------------------------------

local function dirName(dx, dy)
    if dx == 1 then return "east" elseif dx == -1 then return "west" elseif dy == 1 then return "south" end
    return "north"
end

function BKLayout.plan(zone)
    local scan = BKZoneScan.scan(zone)
    BKPlaces.infer(scan)
    local rooms = collectRooms(scan)
    local entrances = findEntrances(zone)
    local used = {}
    for _, room in ipairs(rooms) do
        geometry(room, room.id and mainEntrance(entrances[room.id]) or nil)
        room.entries = entriesOf(room)
        for _, e in ipairs(room.entries) do used[e.key] = true end
    end
    local stock = stockByKey(scan, used)
    local need = {}
    for k, w in pairs(stock) do need[k] = w * BKLayout.HEADROOM end
    local plan = { zoneId = zone.id, rooms = rooms, roles = {}, lines = {}, tiles = 0, homes = {}, stock = stock }
    for _, room in ipairs(rooms) do
        for _, t in ipairs(room.tiles) do tileContents(t, used) end
    end
    for _, room in ipairs(rooms) do
        local wings, wingOrder = {}, {}
        for _, t in ipairs(room.tiles) do
            if wings[t.wing] == nil then wings[t.wing] = {}; table.insert(wingOrder, t.wing) end
            table.insert(wings[t.wing], t)
        end
        for _, wing in ipairs(wingOrder) do
            local entries = {}
            for _, e in ipairs(room.entries) do if e.wing == wing then table.insert(entries, e) end end
            assignWing(wings[wing], entries, need, stock)
        end
    end
    for _, room in ipairs(rooms) do
        for _, t in ipairs(room.tiles) do
            for _, k in ipairs(t.keys) do plan.homes[k] = true end
        end
    end
    local extra = {}
    secondaryPass(rooms, plan.homes, extra)
    -- describe + roles
    for _, room in ipairs(rooms) do
        local ent = room.entrance
        local entText = ent and string.format("entrance %d tile(s) @%d,%d facing %s", #ent.tiles, ent.tiles[1].x, ent.tiles[1].y,
            dirName(-ent.dx, -ent.dy)) or "no entrance found"
        local nl, nr = 0, 0
        for _, t in ipairs(room.tiles) do if t.wing == "right" then nr = nr + 1 else nl = nl + 1 end end
        table.insert(plan.lines, string.format("  room %s (%s): %s; %s", room.name, room.place, entText,
            room.sided and string.format("left+middle %d tiles, right %d tiles", nl, nr) or string.format("%d tiles, no sides", #room.tiles)))
        for _, t in ipairs(room.tiles) do
            plan.tiles = plan.tiles + 1
            if #t.keys > 0 then
                local role = table.concat(t.keys, BKSections.KEY_SEP)
                plan.roles[t.key] = role
                table.insert(plan.lines, string.format("    @%d,%d %s  depth %d %s -> %s  (%s)", t.x, t.y, typesText(t),
                    math.floor(t.depth + 0.5), t.wing, BKSections.catLabel(role), t.why or ""))
            else
                table.insert(plan.lines, string.format("    @%d,%d %s  depth %d %s -> (no role)", t.x, t.y, typesText(t),
                    math.floor(t.depth + 0.5), t.wing))
            end
        end
    end
    for _, l in ipairs(extra) do table.insert(plan.lines, l) end
    local nHomes = 0
    for _ in pairs(plan.homes) do nHomes = nHomes + 1 end
    plan.summary = string.format("layout zone %s: %d room(s), %d container tile(s), %d categories homed",
        tostring(zone.id), #rooms, plan.tiles, nHomes)
    BKLayout.lastPlan[zone.id] = plan
    return plan
end

function BKLayout.log(zone)
    local ok, plan = pcall(BKLayout.plan, zone)
    if not ok then BKLog.warn("layout failed for zone " .. tostring(zone.id) .. ": " .. tostring(plan)); return nil end
    BKLog.info(plan.summary)
    for _, l in ipairs(plan.lines) do BKLog.info(l) end
    return plan
end

-- Loot areas that lie entirely inside the zone, personal ones excepted (they stay hands off).
function BKLayout.areasInside(zone)
    local out = {}
    for _, area in ipairs(BKLoot.list()) do
        if (BKZones.ALL_FLOORS or area.z == zone.z) and area.x1 >= zone.x1 and area.x2 <= zone.x2 and area.y1 >= zone.y1 and area.y2 <= zone.y2
                and not BKLoot.isPersonal(area) then
            table.insert(out, area)
        end
    end
    return out
end

-- Applies the plan: roles on every planned tile (other roles inside the zone cleared), and with replaceAreas the
-- non-personal loot areas inside the zone are removed so the roles take effect.
function BKLayout.apply(player, zone, replaceAreas)
    local plan = BKLayout.lastPlan[zone.id]
    if plan == nil then
        local ok, p = pcall(BKLayout.plan, zone)
        if not ok then BKLog.warn("layout failed for zone " .. tostring(zone.id) .. ": " .. tostring(p)); return nil end
        plan = p
    end
    local removed = 0
    if replaceAreas then
        for _, area in ipairs(BKLayout.areasInside(zone)) do
            BKLoot.requestRemove(player, area.id)
            removed = removed + 1
        end
    end
    BKSections.requestSetRoles(player, plan.roles, { x1 = zone.x1, y1 = zone.y1, x2 = zone.x2, y2 = zone.y2,
        z = (not BKZones.ALL_FLOORS) and zone.z or nil })
    local n = 0
    for _ in pairs(plan.roles) do n = n + 1 end
    BKLog.info(string.format("layout applied to zone %s: %d tile role(s), %d loot area(s) removed", tostring(zone.id), n, removed))
    BKLayout.lastPlan[zone.id] = nil
    return n, removed
end

function BKLayout.forget(zone)
    BKLayout.lastPlan[zone.id] = nil
end

return BKLayout
