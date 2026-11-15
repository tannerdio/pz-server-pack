-- Base Keeper: sections (v0.11.0, Tanner 2026-11-06: "determine zones within the base zone with crate information,
-- what crate it is, what type, what would go there, what room it is considered... then determine what goes where so
-- default sorting is better and I can make less loot zones and just mark specifics").
--
-- A section is a run of touching storage containers (same room, same floor, Chebyshev distance 1) inside a zone that
-- no tagged loot area covers. Fridges/freezers, bins, appliances, personal, locked and manual-area containers are
-- left out: their rules already exist. Each section gets a profile (container types, capacity, what is in it by
-- category, room/place) and a SUGGESTED role: one loot category, chosen from
--   1. what is already stored there (Tanner's own organisation wins),
--   2. how well the container types and the room fit the category (BKRules scores),
--   3. capacity balanced against how much of that category the zone holds (no 60 kg crate for 2 kg of ammo).
-- Suggestions do nothing until Tanner accepts them (decided 2026-11-06: "suggest, I approve"). Accepted roles are
-- stored per container tile (ModData BaseKeeperSections.roles["x,y,z"] = category key), so adding a crate next to a
-- section does not drop its role. Manual loot areas always win over sections.
--
-- Planner effect of an accepted role (soft, unlike loot areas): +SECTION_BONUS for a matching class even in generic
-- storage, a score x MISMATCH_FACTOR for other classes, and certain items of the class migrate into the section
-- from other containers when the gain is at least MIN_GAIN (BKPlanner tidy-up step).
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlaces"
require "BaseKeeper/Engine/BKRules"
require "BaseKeeper/Engine/BKTaxonomy"

BKSections = BKSections or {}

BKSections.MODDATA_KEY = "BaseKeeperSections"
BKSections.SECTION_BONUS = 8
BKSections.FINE_BONUS = 2        -- v0.13.0: matched through the fine group key ("g:gardening") beats a broad match ("tool")
BKSections.MISMATCH_FACTOR = 0.5
-- v0.13.0 strict roles: a container with a role refuses a class/group that has a role somewhere else in the zone (it
-- piles next to its own tile when that is full, like a loot area); a class with no role anywhere is still halved in.
BKSections.STRICT = true
BKSections.KEY_SEP = "+"         -- a role may hold several category keys: "tool+build_material+g:gardening"
BKSections.HEADROOM = 1.4        -- a category wants this much capacity per kg it holds now
BKSections.KEEP_SHARE = 0.5      -- a section already half full of one category keeps it even past the demand
BKSections.MIN_FIT = 3           -- below this a section is left without a suggestion (default rules)
BKSections.CACHE_MS = 10000      -- right-click menu / overlay reuse a zone's sections this long
-- never sectioned: cold storage, bins, appliances (NO_DEST covers stoves, washers, troughs...)
BKSections.SKIP_TYPES = { fridge = true, freezer = true, icecream = true, bin = true, dumpster = true, composter = true }
-- categories a section may be given (fresh food needs a powered fridge, trash a bin, personal is a manual choice)
BKSections.SKIP_CATS = { food_cold = true, trash = true, personal = true, other = true }

BKSections.data = nil
BKSections.cache = {}  -- zoneId -> { at = ms, sections = {...} }
BKSections.version = 0

local function now() local ok, v = pcall(getTimestampMs); return (ok and tonumber(v)) or 0 end

local function store()
    if BKSections.data == nil then BKSections.data = ModData.getOrCreate(BKSections.MODDATA_KEY) end
    local d = BKSections.data
    if d.roles == nil then d.roles = {} end
    return d
end

local function tileKey(x, y, z) return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) end

-- class -> broad category key, and (v0.12.0) fine group -> "g:<group>" category key
local CLASS_CAT, GROUP_CAT = {}, {}
for _, cat in ipairs(BKLoot.CATEGORIES) do
    for _, cls in ipairs(cat.classes or {}) do CLASS_CAT[cls] = cat.key end
    for _, g in ipairs(cat.groups or {}) do GROUP_CAT[g] = cat.key end
end
BKSections.CLASS_CAT = CLASS_CAT
BKSections.GROUP_CAT = GROUP_CAT

-- every category key an item counts towards (its broad class category and its fine group category)
local function catsOf(class, group)
    local out = {}
    if CLASS_CAT[class] then table.insert(out, CLASS_CAT[class]) end
    if group and GROUP_CAT[group] then table.insert(out, GROUP_CAT[group]) end
    return out
end

-- v0.13.0: a role string is one or more category keys joined by KEY_SEP
function BKSections.keysOf(role)
    local out = {}
    if type(role) ~= "string" then return out end
    local start = 1
    while true do
        local i = string.find(role, BKSections.KEY_SEP, start, true)
        local part = i and string.sub(role, start, i - 1) or string.sub(role, start)
        if part ~= "" then table.insert(out, part) end
        if i == nil then break end
        start = i + 1
    end
    return out
end

function BKSections.hasKey(role, key)
    for _, k in ipairs(BKSections.keysOf(role)) do if k == key then return true end end
    return false
end

function BKSections.catLabel(key)
    local labels = {}
    for _, k in ipairs(BKSections.keysOf(key)) do
        local cat = BKLoot.category(k)
        if cat then table.insert(labels, cat.label) end
    end
    if #labels == 0 then return "none" end
    return table.concat(labels, " + ")
end

function BKSections.roleAt(x, y, z)
    return store().roles[tileKey(x, y, z)]
end

-- Planner side ----------------------------------------------------------------------------------------------------

-- Tags containers that carry an accepted role (and are not in a tagged loot area, which wins): c.section = category
-- key, c.sectionClasses = class set. scan.sectionClasses[class] = true when some container in the scan takes it.
-- Run after BKLoot.annotate.
function BKSections.annotate(scan)
    local roles = store().roles
    scan.sectionClasses = {}
    local n = 0
    for _, c in ipairs(scan.containers) do
        c.section, c.sectionClasses = nil, nil
        local key = roles[tileKey(c.x, c.y, c.z)]
        if key and c.areaClasses == nil and not c.personal and not c.noDest and not c.locked then
            local any = false
            for _, k in ipairs(BKSections.keysOf(key)) do
                local cat = BKLoot.category(k)
                if cat then
                    any = true
                    c.sectionClasses = c.sectionClasses or {}
                    for _, cls in ipairs(cat.classes or {}) do
                        c.sectionClasses[cls] = true
                        scan.sectionClasses[cls] = true
                    end
                    for _, g in ipairs(cat.groups or {}) do
                        local gk = BKTaxonomy.groupKey(g)
                        c.sectionClasses[gk] = true
                        scan.sectionClasses[gk] = true
                    end
                end
            end
            if any then
                c.section = key
                n = n + 1
            end
        end
    end
    return n
end

-- true, and whether the match came through the fine group key
local function sectionTakes(c, class, group)
    if c.sectionClasses == nil then return false end
    if group ~= nil and c.sectionClasses[BKTaxonomy.groupKey(group)] == true then return true, true end
    if c.sectionClasses[class] then return true, false end
    return false
end

-- some container in the scan has a role for this class or group
local function homeElsewhere(scan, class, group)
    if scan == nil or scan.sectionClasses == nil then return false end
    if scan.sectionClasses[class] == true then return true end
    return group ~= nil and scan.sectionClasses[BKTaxonomy.groupKey(group)] == true
end

-- Score adjustment for class/group in container c: +bonus (applied even where the type has no rule; +FINE_BONUS more
-- when the fine group matched), 0 when strict and the class has a role elsewhere (scan given), else x factor.
function BKSections.adjust(c, class, s, group, scan)
    if c.sectionClasses == nil then return s end
    local takes, fine = sectionTakes(c, class, group)
    if takes then return math.max(s, 0) + BKSections.SECTION_BONUS + (fine and BKSections.FINE_BONUS or 0) end
    if BKSections.STRICT and homeElsewhere(scan, class, group) then return 0 end
    return s * BKSections.MISMATCH_FACTOR
end

function BKSections.designated(c, class, group)
    return sectionTakes(c, class, group)
end

-- Analysis --------------------------------------------------------------------------------------------------------

local function weightOf(item)
    local ok, w = pcall(function() return item:getActualWeight() end)
    if ok and tonumber(w) then return tonumber(w) end
    local ok2, w2 = pcall(function() return item:getWeight() end)
    return (ok2 and tonumber(w2)) or 0
end

local function capacityOf(c)
    local ok, v = pcall(function() return c.container:getCapacity() end)
    return (ok and tonumber(v)) or 0
end

local function usedOf(c)
    local ok, v = pcall(function() return c.container:getCapacityWeight() end)
    return (ok and tonumber(v)) or 0
end

local function sectionable(c)
    return not c.noDest and not c.locked and not c.personal and c.areaClasses == nil
        and not BKSections.SKIP_TYPES[c.ctype] and BKRules.isSortable(c.ctype)
end

-- kg per category over every stock container and the floor of the scan (what the base holds, wherever it sits)
local function stockByCat(scan)
    local out = {}
    local function addItem(item)
        local class, _, _, group = BKItemClass.classify(item)
        for _, cat in ipairs(catsOf(class, group)) do out[cat] = (out[cat] or 0) + weightOf(item) end
    end
    for _, c in ipairs(scan.containers) do
        if not (c.ctype == "bin" or c.ctype == "dumpster" or c.ctype == "composter") then
            local ok, items = pcall(function() return c.container:getItems() end)
            if ok and items then
                for i = 0, items:size() - 1 do addItem(items:get(i)) end
            end
        end
    end
    for _, f in ipairs(scan.floorItems) do addItem(f.item) end
    return out
end

local function cluster(list)
    -- union-find over touching containers in the same room and floor
    local parent = {}
    for i = 1, #list do parent[i] = i end
    local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            if a.z == b.z and (a.room or "") == (b.room or "") and math.abs(a.x - b.x) <= 1 and math.abs(a.y - b.y) <= 1 then
                local ri, rj = find(i), find(j)
                if ri ~= rj then parent[rj] = ri end
            end
        end
    end
    local groups, order = {}, {}
    for i = 1, #list do
        local r = find(i)
        if groups[r] == nil then groups[r] = {}; table.insert(order, r) end
        table.insert(groups[r], list[i])
    end
    local out = {}
    for _, r in ipairs(order) do table.insert(out, groups[r]) end
    return out
end

local function profile(containers)
    local s = { containers = containers, cap = 0, used = 0, catW = {}, types = {}, contentW = 0 }
    local x1, y1, x2, y2 = nil, nil, nil, nil
    local placeVotes = {}
    for _, c in ipairs(containers) do
        s.cap = s.cap + capacityOf(c)
        s.used = s.used + usedOf(c)
        s.types[c.ctype] = (s.types[c.ctype] or 0) + 1
        placeVotes[c.place or "storage"] = (placeVotes[c.place or "storage"] or 0) + 1
        x1 = x1 and math.min(x1, c.x) or c.x; y1 = y1 and math.min(y1, c.y) or c.y
        x2 = x2 and math.max(x2, c.x) or c.x; y2 = y2 and math.max(y2, c.y) or c.y
        local ok, items = pcall(function() return c.container:getItems() end)
        if ok and items then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local class, _, sure, group = BKItemClass.classify(item)
                local w = weightOf(item)
                if sure then
                    for _, cat in ipairs(catsOf(class, group)) do s.catW[cat] = (s.catW[cat] or 0) + w end
                end
                s.contentW = s.contentW + w
            end
        end
    end
    local bestPlace, bestN = "storage", 0
    for p, n in pairs(placeVotes) do if n > bestN then bestPlace, bestN = p, n end end
    s.place = bestPlace
    s.room = containers[1].room or "outside"
    s.z = containers[1].z
    s.x1, s.y1, s.x2, s.y2 = x1, y1, x2, y2
    s.key = tileKey(x1, y1, s.z)
    return s
end

-- How well a section fits a category: content share (x10) + mean best rule score of its containers. A fine
-- category (v0.12.0) scores with its group's default class plus the group's own container preferences.
local function fit(s, cat)
    local share = s.contentW > 0 and (s.catW[cat.key] or 0) / s.contentW or 0
    local total = 0
    for _, c in ipairs(s.containers) do
        local best = 0
        for _, cls in ipairs(cat.classes or {}) do
            local v = BKRules.score(cls, c)
            if v > best then best = v end
        end
        for _, g in ipairs(cat.groups or {}) do
            local def = BKTaxonomy.get(g)
            local cls = def and def.class or "other"
            if cls == "food" then cls = "food_dry" elseif cls == "drink" then cls = "drink" end
            local v = BKRules.score(cls, c, g)
            if v > best then best = v end
        end
        total = total + best
    end
    return share * 10 + total / #s.containers, share
end

local function typesText(s)
    local parts = {}
    for t, n in pairs(s.types) do table.insert(parts, (n > 1 and (tostring(n) .. "x ") or "") .. t) end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function contentsText(s)
    local parts = {}
    for k, w in pairs(s.catW) do table.insert(parts, { k = k, w = w }) end
    table.sort(parts, function(a, b) return a.w > b.w end)
    local out = {}
    for i, p in ipairs(parts) do
        if i > 3 then break end
        table.insert(out, string.format("%s %.0f kg", BKSections.catLabel(p.k), p.w))
    end
    return #out > 0 and table.concat(out, ", ") or "empty"
end

-- Builds the sections of one zone. scan: an annotated scan (BKPlaces.infer + BKLoot.annotate already run) or nil to
-- scan now. Returns a list of sections sorted by position, each with .suggest (category key or nil), .role
-- (accepted category key, nil, or "mixed" when its tiles disagree), .fit, .why.
function BKSections.build(zone, scan)
    if scan == nil then
        scan = BKZoneScan.scanBase(zone)
        BKPlaces.infer(scan)
        BKLoot.annotate(scan)
    end
    local list = {}
    for _, c in ipairs(scan.containers) do
        if (c.zoneId == nil or c.zoneId == zone.id) and sectionable(c) then table.insert(list, c) end
    end
    local sections = {}
    for _, group in ipairs(cluster(list)) do table.insert(sections, profile(group)) end

    -- demand per category: what the zone holds now x headroom, minus what manual loot areas already give it
    local stock = stockByCat(scan)
    local demand = {}
    for k, w in pairs(stock) do demand[k] = w * BKSections.HEADROOM end
    for _, c in ipairs(scan.containers) do
        if c.areaClasses then
            for key in pairs(c.areaClasses) do
                -- key is a class ("tool") or a fine group key ("g:carpentry"); both are category keys for groups
                local k = CLASS_CAT[key] or (BKLoot.category(key) and key) or nil
                if k and demand[k] then demand[k] = demand[k] - capacityOf(c) end
            end
        end
    end

    -- greedy: best (section, category) pairs first while the category still needs room
    local pairsList = {}
    for _, s in ipairs(sections) do
        for _, cat in ipairs(BKLoot.CATEGORIES) do
            if not BKSections.SKIP_CATS[cat.key] then
                local f, share = fit(s, cat)
                if f >= BKSections.MIN_FIT or share >= BKSections.KEEP_SHARE then
                    table.insert(pairsList, { s = s, cat = cat, fit = f, share = share })
                end
            end
        end
    end
    table.sort(pairsList, function(a, b) return a.fit > b.fit end)
    for _, p in ipairs(pairsList) do
        local s = p.s
        if s.suggest == nil then
            local need = demand[p.cat.key] or 0
            if need > 0 or p.share >= BKSections.KEEP_SHARE then
                s.suggest, s.fit = p.cat.key, p.fit
                s.why = p.share >= BKSections.KEEP_SHARE and string.format("already %d%% %s", math.floor(p.share * 100), p.cat.label)
                    or string.format("fits %.1f, base needs %.0f kg more %s room", p.fit, need, p.cat.label)
                demand[p.cat.key] = need - s.cap
            end
        end
    end

    -- accepted roles
    local roles = store().roles
    for _, s in ipairs(sections) do
        local role, mixed = nil, false
        for _, c in ipairs(s.containers) do
            local r = roles[tileKey(c.x, c.y, c.z)]
            if r then
                if role and role ~= r then mixed = true end
                role = role or r
            end
        end
        s.role = mixed and "mixed" or role
        s.typesText = typesText(s)
        s.contentsText = contentsText(s)
    end
    table.sort(sections, function(a, b)
        if a.z ~= b.z then return a.z > b.z end
        if a.y1 ~= b.y1 then return a.y1 < b.y1 end
        return a.x1 < b.x1
    end)
    for i, s in ipairs(sections) do s.index = i end
    BKSections.cache[zone.id] = { at = now(), sections = sections }
    return sections
end

function BKSections.forZone(zone, maxAgeMs)
    local c = BKSections.cache[zone.id]
    if c and now() - c.at < (maxAgeMs or BKSections.CACHE_MS) then return c.sections end
    local ok, res = pcall(BKSections.build, zone)
    if ok then return res end
    BKLog.warn("sections failed for zone " .. tostring(zone.id) .. ": " .. tostring(res))
    return {}
end

-- The section whose container sits on this tile (nil when none).
function BKSections.at(zone, x, y, z)
    for _, s in ipairs(BKSections.forZone(zone)) do
        for _, c in ipairs(s.containers) do
            if c.x == x and c.y == y and c.z == z then return s end
        end
    end
    return nil
end

function BKSections.describe(s)
    local role = s.role == "mixed" and "mixed roles" or (s.role and ("role " .. BKSections.catLabel(s.role)) or "no role")
    return string.format("section %d @%d,%d,%d %s, %s: %s, %.0f/%.0f kg, holds %s; %s; suggested %s%s", s.index, s.x1,
        s.y1, s.z, s.room, s.place, s.typesText, s.used, s.cap, s.contentsText, role,
        s.suggest and BKSections.catLabel(s.suggest) or "none (default rules)", s.why and (" (" .. s.why .. ")") or "")
end

-- Authority-side role change for every container tile of a section. key nil clears it.
local function changed()
    BKSections.version = BKSections.version + 1
    BKSections.cache = {}
    if isServer() then ModData.transmit(BKSections.MODDATA_KEY) end
    triggerEvent("BaseKeeper_AreasChanged", nil) -- the keeper replans every zone on this event
end

function BKSections.setRole(tiles, key)
    local roles = store().roles
    for _, t in ipairs(tiles) do roles[tileKey(t.x, t.y, t.z)] = key end
    BKLog.info(string.format("section role %s on %d container tile(s)", key and BKSections.catLabel(key) or "cleared", #tiles))
    changed()
end

function BKSections.clearAll()
    store().roles = {}
    BKLog.info("all section roles cleared")
    changed()
end

-- v0.13.0 layout plans: roles for many tiles at once; rect (x1,y1,x2,y2,z, ends exclusive) first drops every role
-- inside it so a re-planned zone carries nothing stale.
function BKSections.setRoles(map, rect)
    local roles = store().roles
    local cleared = 0
    if rect then
        local drop = {}
        for k in pairs(roles) do
            local x, y, z = string.match(k, "^(%-?%d+),(%-?%d+),(%-?%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x and (rect.z == nil or z == rect.z) and x >= rect.x1 and x < rect.x2 and y >= rect.y1 and y < rect.y2 then table.insert(drop, k) end
        end
        for _, k in ipairs(drop) do roles[k] = nil; cleared = cleared + 1 end
    end
    local n = 0
    for k, key in pairs(map or {}) do
        if type(k) == "string" and type(key) == "string" and #BKSections.keysOf(key) > 0 then
            roles[k] = key
            n = n + 1
        end
    end
    BKLog.info(string.format("section roles set on %d tile(s), %d old role(s) cleared", n, cleared))
    changed()
end

function BKSections.requestSetRoles(player, map, rect)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "setSectionRoles", { roles = map, rect = rect })
        return
    end
    BKSections.setRoles(map, rect)
end

local function tilesOf(s)
    local out = {}
    for _, c in ipairs(s.containers) do table.insert(out, { x = c.x, y = c.y, z = c.z }) end
    return out
end

function BKSections.requestRole(player, s, key)
    local tiles = tilesOf(s)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "setSectionRole", { tiles = tiles, key = key })
        return
    end
    BKSections.setRole(tiles, key)
end

function BKSections.requestAcceptAll(player, zone)
    local n = 0
    for _, s in ipairs(BKSections.forZone(zone, 0)) do
        if s.suggest and s.role == nil then
            BKSections.requestRole(player, s, s.suggest)
            n = n + 1
        end
    end
    BKLog.info(string.format("accepted %d suggested section(s) in zone %s", n, tostring(zone.id)))
    return n
end

function BKSections.requestClearAll(player)
    if isClient() then sendClientCommand(player, "BaseKeeper", "clearSectionRoles", {}); return end
    BKSections.clearAll()
end

function BKSections.logZone(zone)
    local sections = BKSections.forZone(zone, 0)
    BKLog.info(string.format("sections zone %s: %d", tostring(zone.id), #sections))
    for _, s in ipairs(sections) do BKLog.info("  " .. BKSections.describe(s)) end
end

-- Multiplayer plumbing, same pattern as BKLoot.
local function onClientCommand(module, command, player, args)
    if module ~= "BaseKeeper" or type(args) ~= "table" then return end
    if command == "setSectionRole" and type(args.tiles) == "table" then
        local tiles = {}
        for _, t in pairs(args.tiles) do
            if tonumber(t.x) and tonumber(t.y) and tonumber(t.z) then
                table.insert(tiles, { x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z) })
            end
        end
        local key = type(args.key) == "string" and BKLoot.category(args.key) and args.key or nil
        BKSections.setRole(tiles, key)
    elseif command == "clearSectionRoles" then
        BKSections.clearAll()
    elseif command == "setSectionRoles" and type(args.roles) == "table" then
        local map = {}
        for k, v in pairs(args.roles) do if type(k) == "string" and type(v) == "string" then map[k] = v end end
        local rect = nil
        if type(args.rect) == "table" and tonumber(args.rect.x1) then
            rect = { x1 = tonumber(args.rect.x1), y1 = tonumber(args.rect.y1), x2 = tonumber(args.rect.x2),
                y2 = tonumber(args.rect.y2), z = tonumber(args.rect.z) }
        end
        BKSections.setRoles(map, rect)
    end
end

local function onReceiveGlobalModData(key, data)
    if key ~= BKSections.MODDATA_KEY or type(data) ~= "table" then return end
    if ModData.add then ModData.add(key, data) end
    BKSections.data = data
    BKSections.cache = {}
    BKSections.version = BKSections.version + 1
end

Events.OnInitGlobalModData.Add(function()
    BKSections.data = nil
    BKSections.cache = {}
    if isClient() and ModData.request then ModData.request(BKSections.MODDATA_KEY) end
end)
if isServer() then Events.OnClientCommand.Add(onClientCommand) end
if isClient() then Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData) end

return BKSections
