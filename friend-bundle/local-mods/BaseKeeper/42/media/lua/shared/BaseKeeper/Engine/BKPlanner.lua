-- Base Keeper: turns a scanned zone into a list of jobs {item, class, src, dst, score, gain}.
--
-- Rule one, what may be touched:
--   * floor items inside the zone: always (minus corpses, furniture, bags with contents, keys, favourites, equipped)
--   * bags on the floor: only duffel bags are emptied (SOURCE_BAGS_ONLY / SOURCE_BAG_TYPES, Tanner 2026-11-08: "only
--     take from duffel bag containers, no other containers"); other bags lie there untouched.
--   * items inside containers: OFF while SOURCE_BAGS_ONLY is true (v0.14.5). The old rule, kept in code: only when
--     the classification is certain, the current container has no use at all for that class, and the destination is
--     a specialist container. Food never leaves a fridge or freezer.
--   * frozen food only moves to a powered freezer; perishables only to powered cold storage; otherwise they stay.
--   * rotten food and anything the keeper moved in the last game day are left alone.
-- Rule two, where it belongs: BKRules (class x container type x inferred place), with guessed classifications
--   restricted to generic storage.
-- Rule three, how far: best match within RADIUS tiles; beyond that only a specialist container for a certain class,
--   and only when nothing nearby fits.
-- Rule four, space: every container has a weight budget for the whole plan, so queued jobs never oversubscribe it.
--   When the preferred container is full the next best one with room is used; only when NO container with a
--   positive score has room does a floor item go to a pile on a free tile next to the container it wants.
-- Rule five, order: floor items first (into containers, then onto piles), then bag contents, then tidy-ups inside
--   containers. Piles never consume container space and pile items are re-planned every time, so they move in as
--   soon as room frees up.
-- Rule six, loot areas (BKLoot): a class whose category is ticked on a loot area goes to a container inside that
--   area first, any distance, AREA_BONUS above every default score; when the area is full the item piles next to
--   its best container (BKLoot.STRICT) instead of falling back outside. Containers inside a tagged area take only
--   that area's classes; classes with no area follow the rules above unchanged. A "Personal (hands off)" area is
--   skipped in every direction: its containers are never a destination or a tidy-up source, its floor and bags are
--   not an inbox, and no pile forms on its tiles.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlaces"
require "BaseKeeper/Engine/BKRules"
require "BaseKeeper/Engine/BKTaxonomy"
require "BaseKeeper/BKLoot"
require "BaseKeeper/BKSections"

BKPlanner = BKPlanner or {}

BKPlanner.RADIUS = 8           -- preferred hauling distance in tiles
BKPlanner.DIST_PENALTY = 0.4   -- score lost per tile
BKPlanner.MIN_GAIN = 4         -- container->container moves need at least this much improvement
BKPlanner.EVICT_MIN_GAIN = 1   -- leaving a loot area that is not for the item: any positive destination will do
BKPlanner.SPECIALIST_MIN = 6   -- base type score that makes a container a "specialist" for a class
BKPlanner.MAX_JOBS = 40
BKPlanner.MIN_FLOOR_SCORE = 0.5
BKPlanner.MIN_DIST_FACTOR = 0.35  -- inside RADIUS distance never takes more than 65% of a score away
BKPlanner.FALLBACK_FACTOR = 0.5   -- a certain class with no container of its own takes generic storage at half its "other" score
BKPlanner.WEIGHT_EPSILON = 0.01   -- float slack when comparing item weight with free weight (AddItem does not enforce capacity)
BKPlanner.PILE_MAX_ITEMS = 40  -- a pile tile with this many items takes no more
BKPlanner.COLD = { fridge = true, freezer = true, icecream = true }
BKPlanner.FREEZER = { freezer = true, icecream = true }
BKPlanner.ORDER = { floor = 1, pile = 2, bag = 3, container = 4 } -- lower runs first
BKPlanner.TRASH_DEST = { bin = true, dumpster = true }   -- the only places trash may go...
BKPlanner.COMPOST_DEST = { composter = true }            -- ...except rotten food, which a composter takes too (v0.8.3)
BKPlanner.NO_SOURCE = { bin = true, dumpster = true, composter = true }  -- never tidied: what is in the bin stays...
-- v0.14.5 (Tanner, 2026-11-08: "only take from duffel bag containers, no other containers when sorting"): the only
-- containers the sorter ever takes from are duffel bags lying on the floor. Container tidy-ups (step 3: loot-area
-- migration/eviction, section pulls, fridge quota -> freezer, cold-storage evictions, bin rescue) do not run.
-- Flip SOURCE_BAGS_ONLY to false to get the old behaviour back. FLOOR_INBOX = false would also stop loose floor items.
BKPlanner.SOURCE_BAGS_ONLY = true
BKPlanner.FLOOR_INBOX = true
BKPlanner.SOURCE_BAG_TYPES = { ["Base.Bag_DuffelBag"] = true, ["Base.Bag_DuffelBagTINT"] = true }
BKPlanner.BIN_RESCUE = { empties = true, medical = true } -- ...except these certain classes (v0.9.0 bottles, v0.10.2 dirty bandages)
-- v0.9.0 smart rules ----------------------------------------------------------------------------------------
BKPlanner.SPOILS = { food_perishable = true, food_freezable = true, food_frozen = true } -- the only things a powered fridge/freezer takes
BKPlanner.COMPANION_BONUS = 3   -- container already holds something the item works with (ammo<->gun<->magazine, rods<->torch...)
BKPlanner.SAME_TYPE_BONUS = 1   -- container already holds the same item type
BKPlanner.WATER_BONUS = 5       -- empties near a rain collector / sink / barrel
BKPlanner.WORKSHOP_BONUS = 2    -- heavy build materials in crates by the workbench, small parts in drawers
BKPlanner.SEASON_BONUS = 6      -- in-season clothing by an outside door, off-season clothing away from it
BKPlanner.STALE_BONUS = 2       -- perishables past STALE_RATIO of their fresh life: the fridge by the stove
BKPlanner.STALE_RATIO = 0.6
BKPlanner.FREEZE_BONUS = 4      -- meat/fish: a powered freezer beats the fridge even a floor away
-- v0.14.0 fridge = working stock, freezer = the store (Tanner 2026-11-08, "optimize storage of items in the freezer vs
-- fridge"): in each powered fridge the perishables that rot soonest stay, up to FRIDGE_STOCK_HUNGER hunger in all;
-- freezable food beyond that goes to a powered freezer, and the meal prep thaws what it needs one run ahead
-- (BKCook.thawAhead, 3 h in a powered fridge). Spices, drinks, made meals and anything thawing stay where they are.
BKPlanner.FRIDGE_STOCK_HUNGER = 300  -- about three days of eating at 100 hunger a day
BKPlanner.THAW_HOLD_HOURS = 24       -- food the prep moved out to thaw (item modData BKThaw) is left alone this long
BKPlanner.HEAVY_KG = 2.0
BKPlanner.SMALL_KG = 0.3
BKPlanner.WARM_INSULATION = 0.45
BKPlanner.SUMMER_NAMES = { "shorts", "skirt", "tanktop", "sandal", "flipflop", "bikini", "swimsuit", "swimtrunks" }
BKPlanner.HEAVY_TYPES = { crate = true, smallcrate = true, metal_shelves = true, garagestorage = true, garage_storage = true }
BKPlanner.DRAWER_TYPES = { toolcabinet = true, smallbox = true, officedrawers = true, sidetable = true, desk = true }
-- v0.12.0: companions come from the item taxonomy (BKTaxonomy via BKItemClass.groupOf): same fine group
-- (carpentry with carpentry, cleaning with cleaning) = COMPANION_BONUS, same family (workshop, kitchen...) =
-- FAMILY_BONUS, same calibre for guns/ammo/magazines = COMPANION_BONUS. The old substring GROUPS table is gone.
BKPlanner.FAMILY_BONUS = 1
BKPlanner.skipPredicate = nil  -- set by the keeper: function(item) -> reason string / true to leave the item alone
BKPlanner.refusedPredicate = nil -- set by the keeper: function(c, item) -> true when c refused this item at move time recently

local function dist(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

local function itemWeight(item)
    local ok, w = pcall(function() return item:getActualWeight() end)
    if ok and tonumber(w) then return tonumber(w) end
    local ok2, w2 = pcall(function() return item:getWeight() end)
    return (ok2 and tonumber(w2)) or 0
end

-- Free weight in a container right now (capacity minus what is in it). nil when unknown.
local function liveFreeWeight(c)
    local ok, free = pcall(function() return c.container:getCapacity() - c.container:getCapacityWeight() end)
    if ok and tonumber(free) then return tonumber(free) end
    return nil
end

-- Space -----------------------------------------------------------------------------------------------------
-- budget: container entry -> free weight left for this plan. Without a budget the live value is used.

local function remaining(c, budget)
    if budget and budget[c] ~= nil then return budget[c] end
    local free = liveFreeWeight(c)
    if budget then budget[c] = free end
    return free
end

local function fits(c, item, budget)
    if BKPlanner.refusedPredicate and BKPlanner.refusedPredicate(c, item) then return false end
    local free = remaining(c, budget)
    if free == nil then
        local ok, room = pcall(function() return c.container:hasRoomFor(nil, item) end)
        return not (ok and room == false)
    end
    return itemWeight(item) <= free + BKPlanner.WEIGHT_EPSILON
end

-- The same test against the live container, for the keeper at move time, so plan and move never disagree.
function BKPlanner.fitsLive(container, item)
    local ok, free = pcall(function() return container:getCapacity() - container:getCapacityWeight() end)
    if ok and tonumber(free) then return itemWeight(item) <= tonumber(free) + BKPlanner.WEIGHT_EPSILON end
    local okRoom, room = pcall(function() return container:hasRoomFor(nil, item) end)
    return not (okRoom and room == false)
end

local function reserve(c, item, budget)
    if not budget then return end
    local free = remaining(c, budget)
    if free ~= nil then budget[c] = free - itemWeight(item) end
end

local function lowerStr(v) return string.lower(tostring(v or "")) end

local function m(obj, name, ...)
    if obj == nil then return nil end
    local fn = obj[name]
    if type(fn) ~= "function" then return nil end
    local ok, r = pcall(fn, obj, ...)
    if ok then return r end
    return nil
end

local function has(s, sub) return string.find(s, sub, 1, true) ~= nil end

-- "556", "9mm", "shotgun", "308": the calibre shared by a gun, its magazines, loose rounds and ammo boxes
local function normAmmo(s)
    s = lowerStr(s)
    if string.sub(s, 1, 5) == "base." then s = string.sub(s, 6) end
    for _, w in ipairs({ "box", "bullets", "shells", "rounds", "carton" }) do
        local i = string.find(s, w, 1, true)
        while i do
            s = string.sub(s, 1, i - 1) .. string.sub(s, i + #w)
            i = string.find(s, w, 1, true)
        end
    end
    return s
end

local function ammoKey(item, typeName)
    local at = m(item, "getAmmoType") -- B42: an AmmoType object on guns and magazines
    if at ~= nil then
        local key = (type(at) == "string") and at or m(at, "getItemKey")
        if key then return normAmmo(key) end
    end
    if (has(typeName, "box") or has(typeName, "bullets") or has(typeName, "shells")) and m(item, "IsWeapon") ~= true then
        return normAmmo(typeName)
    end
    return nil
end

-- Companion keys of an item: "g:<group>", "f:<family>" and, for guns/ammo/magazines, "ammo:<calibre>". The group
-- may depend on live state (an empty bottle is "empties"), so only the calibre part is cached by full type.
local ammoCache = {} -- full type -> "ammo:<cal>" or false
local function groupsOf(item, group)
    local out = {}
    group = group or BKItemClass.groupOf(item)
    table.insert(out, "g:" .. tostring(group))
    table.insert(out, "f:" .. BKTaxonomy.familyOf(group))
    local ft = m(item, "getFullType")
    local ak = ft and ammoCache[ft]
    if ak == nil then
        local typeName = lowerStr(m(item, "getType"))
        local cat = m(item, "getCategory")
        ak = false
        if cat == "Weapon" or has(typeName, "box") or has(typeName, "bullets") or has(typeName, "shells")
                or has(typeName, "clip") or has(typeName, "magazine") then
            local k = ammoKey(item, typeName)
            if k and k ~= "" then ak = "ammo:" .. k end
        end
        if ft then ammoCache[ft] = ak end
    end
    if ak then table.insert(out, ak) end
    return out
end

-- winter = Nov-Feb, summer = Jun-Aug, else nil (getMonth is 0-based)
local function season()
    local mo = tonumber(m(getGameTime(), "getMonth"))
    if mo == nil then return nil end
    if mo >= 10 or mo <= 1 then return "winter" end
    if mo >= 5 and mo <= 7 then return "summer" end
    return nil
end

local function seasonOf(item)
    local ins = tonumber(m(item, "getInsulation")) or 0
    if ins >= BKPlanner.WARM_INSULATION then return "warm" end
    local t = lowerStr(m(item, "getType"))
    for _, n in ipairs(BKPlanner.SUMMER_NAMES) do
        if has(t, n) then return "summer" end
    end
    return nil
end

-- "door" when the item is in season, "deep" when it is off season, nil when the rule does not apply
local function seasonWant(info)
    if info == nil or info.season == nil or info.now == nil then return nil end
    if (info.season == "warm") == (info.now == "winter") then return "door" end
    return "deep"
end

BKPlanner.ammoKey = function(item) return ammoKey(item, lowerStr(m(item, "getType"))) end

-- What the planner knows about one item for the v0.9.0 bonuses; computed once per item per plan.
function BKPlanner.itemInfo(item, class, group)
    group = group or BKItemClass.groupOf(item)
    local info = { ftype = m(item, "getFullType"), group = group, groups = groupsOf(item, group) }
    if class == "build_material" then info.weight = itemWeight(item) end
    if class == "clothing" then info.season = seasonOf(item); info.now = season() end
    if class == "food_perishable" then
        local off, age = tonumber(m(item, "getOffAge")), tonumber(m(item, "getAge"))
        info.stale = off ~= nil and off > 0 and age ~= nil and age >= off * BKPlanner.STALE_RATIO
    end
    return info
end

-- Per-container index of what is already inside (type and group counts), built once per plan.
function BKPlanner.indexContents(scan)
    for _, c in ipairs(scan.containers) do
        c.typeN, c.groupN = {}, {}
        if not c.personal and not c.noDest then
            local ok, items = pcall(function() return c.container:getItems() end)
            if ok and items then
                for i = 0, items:size() - 1 do
                    local it = items:get(i)
                    local ft = m(it, "getFullType")
                    if ft then c.typeN[ft] = (c.typeN[ft] or 0) + 1 end
                    for _, g in ipairs(groupsOf(it)) do c.groupN[g] = (c.groupN[g] or 0) + 1 end
                end
            end
        end
    end
end

-- Bonus on top of BKRules.score for this item in container c. inside = the item already sits in c (it does not
-- count as its own companion).
function BKPlanner.extraScore(info, class, c, inside)
    if info == nil then return 0 end
    local s = 0
    local own = inside and 1 or 0
    if c.typeN and info.ftype and (c.typeN[info.ftype] or 0) > own then s = s + BKPlanner.SAME_TYPE_BONUS end
    if c.groupN then
        -- same group or same calibre: full companion bonus (once); same family only: the small one
        local strong, family = false, false
        for _, g in ipairs(info.groups or {}) do
            if (c.groupN[g] or 0) > own then
                if string.sub(g, 1, 2) == "f:" then family = true else strong = true end
            end
        end
        if strong then s = s + BKPlanner.COMPANION_BONUS elseif family then s = s + BKPlanner.FAMILY_BONUS end
    end
    if class == "empties" and c.nearWater then s = s + BKPlanner.WATER_BONUS end
    if class == "build_material" and info.weight then
        if info.weight >= BKPlanner.HEAVY_KG and c.nearBench and BKPlanner.HEAVY_TYPES[c.ctype] then
            s = s + BKPlanner.WORKSHOP_BONUS
        elseif info.weight <= BKPlanner.SMALL_KG and BKPlanner.DRAWER_TYPES[c.ctype] then
            s = s + BKPlanner.WORKSHOP_BONUS
        end
    end
    if class == "clothing" then
        local want = seasonWant(info)
        if (want == "door" and c.nearDoor) or (want == "deep" and not c.nearDoor) then s = s + BKPlanner.SEASON_BONUS end
    end
    if class == "food_freezable" and BKPlanner.FREEZER[c.ctype] and c.powered then s = s + BKPlanner.FREEZE_BONUS end
    if class == "food_perishable" and info.stale and BKPlanner.COLD[c.ctype] and c.nearStove then
        s = s + BKPlanner.STALE_BONUS
    end
    return s
end

-- Hard constraints per class on a candidate destination. Returns false to forbid.
local function allowed(scan, class, c, item)
    if class == "trash" then
        if BKPlanner.TRASH_DEST[c.ctype] == true then return true end
        -- rotten food may also go to a composter (vanilla's own use for it), when the composter accepts the item;
        -- cans and other non-food trash never do
        if BKPlanner.COMPOST_DEST[c.ctype] == true and item ~= nil and type(item.isRotten) == "function" then
            local okR, rotten = pcall(item.isRotten, item)
            if not (okR and rotten == true) then return false end
            local fn = c.container and c.container.isItemAllowed
            if type(fn) ~= "function" then return true end
            local okA, allowedHere = pcall(fn, c.container, item)
            return okA and allowedHere == true
        end
        return false
    end
    if class == "food_frozen" then
        return BKPlanner.FREEZER[c.ctype] == true and c.powered
    end
    if class == "food_perishable" or class == "food_freezable" then
        return BKPlanner.COLD[c.ctype] == true and c.powered
    end
    -- a powered fridge/freezer is only for what spoils (v0.9.0, Tanner: "unless they need a fridge then okay")
    if BKPlanner.COLD[c.ctype] and c.powered and not BKPlanner.SPOILS[class] then return false end
    return true
end

-- a container whose type is made for the class, or (v0.12.0) whose type the fine group prefers that strongly
local function specialist(class, c, group)
    if BKRules.GENERIC_TYPES[c.ctype] then return false end
    local base = (BKRules.TYPE[c.ctype] or {})[class] or 0
    local gBase = BKRules.groupScore(group, c)
    return math.max(base, gBase or 0) >= BKPlanner.SPECIALIST_MIN
end

-- Containers inside a loot area that lists the class or (v0.12.0) the fine group; each once.
local function designatedFor(scan, class, group)
    local out, seen = {}, {}
    local gk = group and BKTaxonomy.groupKey(group) or nil
    local function addAll(list)
        for _, c in ipairs(list or {}) do
            -- v0.16.0: an area that edited this group out (area.excl) is not a home for it
            if not seen[c] and not (gk and c.areaExcl and c.areaExcl[gk] == true) then seen[c] = true; table.insert(out, c) end
        end
    end
    if scan.designated then
        addAll(scan.designated[class])
        if group then addAll(scan.designated[BKTaxonomy.groupKey(group)]) end
    end
    return out
end
BKPlanner.designatedFor = designatedFor

-- Designated containers (inside a loot area whose ticked categories cover the class) score AREA_BONUS + the rule
-- score, distance-penalised but never out of range. Same return shape as bestDestination; everything nil when the
-- class has no usable designated container (no area for it, or the area's containers fail the hard constraints).
local function areaDestination(scan, class, item, at, excludeContainer, budget, info)
    local bestC, bestS, wantC, wantS = nil, 0, nil, 0
    local group = info and info.group or nil
    for _, c in ipairs(designatedFor(scan, class, group)) do
        if c.container ~= excludeContainer and not c.noDest and not c.locked and allowed(scan, class, c, item) then
            local s = BKLoot.AREA_BONUS + BKRules.score(class, c, group) + BKPlanner.extraScore(info, class, c, false)
            local d = dist(at, c)
            local penalised = math.max(s - d * BKPlanner.DIST_PENALTY, s * BKPlanner.MIN_DIST_FACTOR)
            if penalised > wantS then wantC, wantS = c, penalised end
            if penalised > bestS and fits(c, item, budget) then bestC, bestS = c, penalised end
        end
    end
    return bestC, bestS, wantC, wantS
end

-- Best destination for one item. Returns entry, score, wanted entry, wanted score.
-- "wanted" is the best container ignoring space; it is where a pile goes when nothing has room.
-- fallback (floor and bag items only): a class no container in the zone has a rule for still goes to generic
-- storage, at half the "other" score, so nothing certain is left on the floor just because the base lacks a
-- specialist for it. Tidy-ups never use it.
function BKPlanner.bestDestination(scan, class, sure, item, at, excludeContainer, budget, fallback)
    local bestC, bestS = nil, 0
    local farC, farS = nil, 0
    local wantC, wantS = nil, 0
    local wantFarC, wantFarS = nil, 0
    -- loot area first: a container in the area with room wins outright; a full area still owns the "wanted"
    -- container (so the pile forms next to it) and, when strict, nothing outside the area is considered
    local info = item and BKPlanner.itemInfo(item, class) or nil
    local group = info and info.group or nil
    local areaC, areaS, areaWantC, areaWantS = areaDestination(scan, class, item, at, excludeContainer, budget, info)
    if areaC then return areaC, areaS, areaWantC, areaWantS end
    if areaWantC and BKLoot.STRICT then return nil, 0, areaWantC, areaWantS end
    for _, c in ipairs(scan.containers) do
        if c.container ~= excludeContainer and not c.noDest and not c.locked and not c.personal and allowed(scan, class, c, item)
                and (sure or BKRules.GENERIC_TYPES[c.ctype]) and not BKLoot.reserved(c) then
            local s = BKRules.score(class, c, group)
            if s <= 0 and fallback and BKRules.GENERIC_TYPES[c.ctype] then
                s = BKRules.score("other", c) * BKPlanner.FALLBACK_FACTOR
            end
            if s > 0 then s = s + BKPlanner.extraScore(info, class, c, false) end
            -- v0.11.0 accepted section roles: +bonus for its classes, halved otherwise; v0.13.0 strict: 0 when the
            -- class has a role on another container of the zone
            s = BKSections.adjust(c, class, s, group, scan)
            if s > 0 then
                local d = dist(at, c)
                local penalised = math.max(s - d * BKPlanner.DIST_PENALTY, s * BKPlanner.MIN_DIST_FACTOR)
                if d <= BKPlanner.RADIUS then
                    if penalised > wantS then wantC, wantS = c, penalised end
                    if penalised > bestS and fits(c, item, budget) then bestC, bestS = c, penalised end
                elseif sure and specialist(class, c, group) then
                    if penalised > wantFarS then wantFarC, wantFarS = c, penalised end
                    if penalised > farS and fits(c, item, budget) then farC, farS = c, penalised end
                end
            end
        end
    end
    if not wantC then wantC, wantS = wantFarC, wantFarS end
    if areaWantC then wantC, wantS = areaWantC, areaWantS end -- not strict: room elsewhere, but the pile stays by the area
    if bestC then return bestC, bestS, wantC, wantS end
    return farC, farS, wantC, wantS
end

-- Piles --------------------------------------------------------------------------------------------------------

local function squareFree(sq)
    local ok, free = pcall(function()
        if sq.isFree and sq:isFree(false) == false then return false end
        if sq.isSolid and sq:isSolid() then return false end
        if sq.isSolidTrans and sq:isSolidTrans() then return false end
        return true
    end)
    return ok and free == true
end

local function blocked(fromSq, toSq)
    local ok, b = pcall(function() return fromSq:isBlockedTo(toSq) end)
    return ok and b == true
end

local function worldItemCount(sq)
    local ok, n = pcall(function() return sq:getWorldObjects():size() end)
    return (ok and tonumber(n)) or 0
end

-- A free tile inside the zone next to the wanted container, the emptiest one. pileCount tracks items this plan
-- already sends to each square. Returns nil when the item already sits next to the container or no tile is free.
function BKPlanner.pileSquare(zone, want, at, pileCount)
    if at.z == want.z and dist(at, want) <= 1 then return nil end -- already in the pile
    zone = BKZones.at(want.x, want.y, want.z) or zone -- the wanted container may sit in another zone (other floor)
    local cell = getCell()
    local bestSq, bestN, bestD = nil, nil, nil
    for dx = -1, 1 do
        for dy = -1, 1 do
            if not (dx == 0 and dy == 0) then
                local x, y = want.x + dx, want.y + dy
                if BKZones.contains(zone, x, y, want.z) and not BKLoot.isPersonalAt(x, y, want.z) then
                    local sq = cell:getGridSquare(x, y, want.z)
                    if sq and squareFree(sq) and not (want.square and blocked(want.square, sq)) then
                        local n = worldItemCount(sq) + (pileCount and pileCount[sq] or 0)
                        local d = dist(at, { x = x, y = y })
                        if bestN == nil or n < bestN or (n == bestN and d < bestD) then
                            bestSq, bestN, bestD = sq, n, d
                        end
                    end
                end
            end
        end
    end
    if bestSq and bestN >= BKPlanner.PILE_MAX_ITEMS then return nil end
    return bestSq
end

-- Jobs ---------------------------------------------------------------------------------------------------------

local function worldHours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end

local function itemLabel(item)
    local ok, name = pcall(function() return item:getDisplayName() end)
    return ok and tostring(name) or tostring(item)
end

-- Returns a reason string when the item must be left alone, false otherwise.
local function skipItem(item)
    local ok, res = pcall(function()
        if item:isEquipped() then return "equipped" end
        if item.getIsCraftingConsumed and item:getIsCraftingConsumed() then return "crafting" end
        if item.isFavorite and item:isFavorite() then return "favourite" end
        -- v0.14.0: food on its way from frozen to usable is nobody's to move (the meal prep thaws it, or the player
        -- did); a frozen item in a dead freezer also reads as thawing, that one may still go to a powered freezer
        if type(item.isThawing) == "function" and item:isThawing() then
            local okC, ct = pcall(function() return item:getContainer():getType() end)
            -- only inside a container: a frozen thing dropped on the floor is still inbox (it goes to the freezer)
            if okC and ct ~= nil and not BKPlanner.FREEZER[tostring(ct)] then return "thawing" end
        end
        if type(item.getModData) == "function" then
            local since = tonumber(item:getModData().BKThaw)
            if since and (worldHours() - since) < BKPlanner.THAW_HOLD_HOURS then return "thawing" end
        end
        local cat = item:getCategory()
        if cat == "Key" or cat == "Moveable" or cat == "Corpse" then return string.lower(cat) end
        if cat == "Container" and item.getInventory then
            local inv = item:getInventory()
            if inv and inv:getItems() and inv:getItems():size() > 0 then return "bag with contents" end
        end
        if BKPlanner.skipPredicate then
            local why = BKPlanner.skipPredicate(item)
            if why then return type(why) == "string" and why or "recently moved" end
        end
        return false
    end)
    if not ok then return "error" end
    return res
end

-- v0.14.0: per powered fridge, the ids of freezable food past the working-stock quota (-> freezer), and under
-- `evaluated` every id that was weighed (so meat inside the quota is not frozen again). Nothing is marked unless the
-- zone has a powered freezer. Soonest to rot stays; spices, drinks (no hunger), made meals, anything frozen or thawing
-- and anything skipItem protects are left out.
local function fridgeFreezeSet(scan)
    local set = { evaluated = {} }
    local anyFreezer = false
    for _, c in ipairs(scan.containers) do
        if BKPlanner.FREEZER[c.ctype] and c.powered and not c.locked and not c.personal and not c.noDest then anyFreezer = true end
    end
    if not anyFreezer then return set end
    for _, c in ipairs(scan.containers) do
        if c.ctype == "fridge" and c.powered and not c.personal and not c.locked then
            local list = {}
            local ok, items = pcall(function() return c.container:getItems() end)
            for i = 0, ((ok and items) and items:size() or 0) - 1 do
                local it = items:get(i)
                if it and instanceof(it, "Food") and not skipItem(it) and m(it, "isRotten") ~= true
                        and m(it, "isFrozen") ~= true and (tonumber(m(it, "getFreezingTime")) or 0) <= 0
                        and m(it, "canBeFrozen") ~= false and m(it, "isSpice") ~= true
                        and m(it, "haveExtraItems") ~= true then
                    local hunger = -(tonumber(m(it, "getHungChange")) or 0)
                    local offMax, age = tonumber(m(it, "getOffAgeMax")) or 1e9, tonumber(m(it, "getAge")) or 0
                    local id = m(it, "getID")
                    if id and hunger > 0 and offMax < 1000000 then
                        table.insert(list, { id = id, hunger = hunger, left = offMax - age })
                    end
                end
            end
            table.sort(list, function(a, b) return a.left < b.left end)
            local kept = 0
            for _, e in ipairs(list) do
                set.evaluated[e.id] = true
                if kept < BKPlanner.FRIDGE_STOCK_HUNGER then kept = kept + e.hunger else set[e.id] = true end
            end
        end
    end
    return set
end

local function newJob(item, class, sure, src, srcKind, x, y, z, extra, dst, score, gain)
    local job = { item = item, class = class, sure = sure, src = src, srcKind = srcKind,
        srcX = x, srcY = y, srcZ = z, dst = dst, score = score, gain = gain,
        order = BKPlanner.ORDER[srcKind] or BKPlanner.ORDER.container }
    for k, v in pairs(extra or {}) do job[k] = v end
    return job
end

-- A bag the sorter may empty: a duffel bag by type, or anything whose name says Duffel (modded bags).
function BKPlanner.isSourceBag(bagItem)
    if not BKPlanner.SOURCE_BAGS_ONLY then return true end
    if not bagItem then return false end
    local ok, full = pcall(function() return bagItem:getFullType() end)
    if ok and full and BKPlanner.SOURCE_BAG_TYPES[full] then return true end
    local ok2, name = pcall(function() return bagItem:getDisplayName() end)
    return ok2 and type(name) == "string" and string.find(string.lower(name), "duffel", 1, true) ~= nil
end

-- opts.tidy = true (v0.18.0 "Sort now"): run the container tidy-ups for this one plan even though SOURCE_BAGS_ONLY
-- keeps them off, and even when the floor produced jobs. result.tidyJobs = how many container moves it found.
function BKPlanner.plan(zone, opts)
    local forceTidy = opts ~= nil and opts.tidy == true
    local scan = BKZoneScan.scanBase(zone) -- own floor and containers + the uncovered loot areas this zone owns
    local places = BKPlaces.infer(scan)
    local areas = BKLoot.annotate(scan)
    BKSections.annotate(scan) -- after the loot areas: a tagged area wins over a section role
    BKPlanner.indexContents(scan)
    local jobs = {}
    local budget = {}     -- container entry -> free weight left
    local pileCount = {}  -- square -> items this plan already sends there
    local piled = 0
    local left = {}       -- floor and bag items this plan does nothing with, and why (for the logs)
    local function leave(item, class, src, at, reason, want)
        table.insert(left, { item = item, class = class, src = src, x = at.x, y = at.y, reason = reason, want = want })
    end

    -- 1. the floor is the inbox: into a container with room, else onto a pile next to the wanted container
    for _, f in ipairs(BKPlanner.FLOOR_INBOX and scan.floorItems or {}) do
        -- bags are emptied in step 2 and left where they are; items the player placed on purpose are not touched;
        -- the floor of a personal area is not an inbox
        local skip = (f.personal and "personal") or (f.isBag and "bag") or (f.placed and "placed") or skipItem(f.item)
        if skip then
            if skip ~= "bag" then leave(f.item, nil, "floor", f, skip) end
        else
            local class, _, sure, group = BKItemClass.classify(f.item)
            if class ~= "rotten" then
                local c, s, want, wantS = BKPlanner.bestDestination(scan, class, sure, f.item, f, nil, budget, true)
                if c and s >= BKPlanner.MIN_FLOOR_SCORE then
                    reserve(c, f.item, budget)
                    table.insert(jobs, newJob(f.item, class, sure, f.container, "floor", f.x, f.y, f.z,
                        { worldObj = f.worldObj, group = group }, c, s, s))
                elseif want and wantS >= BKPlanner.MIN_FLOOR_SCORE then
                    local sq = BKPlanner.pileSquare(zone, want, f, pileCount)
                    if sq then
                        pileCount[sq] = (pileCount[sq] or 0) + 1
                        piled = piled + 1
                        local dst = { ctype = "pile:" .. want.ctype, place = want.place, pantry = want.pantry,
                            x = sq:getX(), y = sq:getY(), z = sq:getZ(), square = sq, want = want, pile = true }
                        table.insert(jobs, newJob(f.item, class, sure, f.container, "floor", f.x, f.y, f.z,
                            { worldObj = f.worldObj, pile = true, order = BKPlanner.ORDER.pile, group = group }, dst, wantS, wantS))
                    elseif f.z == want.z and dist(f, want) <= 1 then
                        leave(f.item, class, "floor", f, "waiting in pile", want)
                    else
                        leave(f.item, class, "floor", f, "full, no free pile tile", want)
                    end
                else
                    leave(f.item, class, "floor", f, "no destination", want)
                end
            else
                leave(f.item, class, "floor", f, "rotten")
            end
        end
    end

    -- 2. bags lying on the floor are emptied; the empty bag stays on the floor (Tanner: no need to store duffels).
    --    Bag contents follow the floor rule: a container with room, else a pile next to the wanted container, so a
    --    bag never stays on the floor just because one thing inside it has nowhere to go.
    for _, bag in ipairs(scan.floorBags) do
        local ok, items = false, nil
        if bag.personal then
            -- hands off
        elseif not BKPlanner.isSourceBag(bag.item) then
            leave(bag.item, nil, "bag", bag, "not a duffel")
        else
            ok, items = pcall(function() return bag.inventory:getItems() end)
        end
        if ok and items then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local skip = item and skipItem(item)
                if item and skip then
                    leave(item, nil, "bag", bag, skip)
                elseif item then
                    local class, _, sure, group = BKItemClass.classify(item)
                    if class ~= "rotten" then
                        local c, s, want, wantS = BKPlanner.bestDestination(scan, class, sure, item, bag, bag.inventory, budget, true)
                        if c and s >= BKPlanner.MIN_FLOOR_SCORE then
                            reserve(c, item, budget)
                            table.insert(jobs, newJob(item, class, sure, bag.inventory, "bag", bag.x, bag.y, bag.z,
                                { bagItem = bag.item, group = group }, c, s, s))
                        elseif want and wantS >= BKPlanner.MIN_FLOOR_SCORE then
                            local sq = BKPlanner.pileSquare(zone, want, bag, pileCount)
                            if sq then
                                pileCount[sq] = (pileCount[sq] or 0) + 1
                                piled = piled + 1
                                local dst = { ctype = "pile:" .. want.ctype, place = want.place, pantry = want.pantry,
                                    x = sq:getX(), y = sq:getY(), z = sq:getZ(), square = sq, want = want, pile = true }
                                table.insert(jobs, newJob(item, class, sure, bag.inventory, "bag", bag.x, bag.y, bag.z,
                                    { bagItem = bag.item, pile = true, order = BKPlanner.ORDER.pile, group = group }, dst, wantS, wantS))
                            else
                                leave(item, class, "bag", bag, "full, no free pile tile", want)
                            end
                        else
                            leave(item, class, "bag", bag, "no destination", want)
                        end
                    else
                        leave(item, class, "bag", bag, "rotten")
                    end
                end
            end
        end
    end

    -- 3. obvious mistakes inside containers: only when the floor produced no work at all, so the floor is always
    --    dealt with first and a full container scan does not run every plan
    --    v0.14.5: skipped entirely while SOURCE_BAGS_ONLY (duffel bags are the only container source)
    local tidy = forceTidy or ((#jobs == 0) and not BKPlanner.SOURCE_BAGS_ONLY)
    local freezeSet = tidy and fridgeFreezeSet(scan) or { evaluated = {} }
    for _, src in ipairs(tidy and scan.containers or {}) do
        -- bins are never a source, except that BIN_RESCUE classes are fished back out of a bin or dumpster
        local binSrc = BKPlanner.TRASH_DEST[src.ctype] == true
        if src.zoneId == zone.id and not src.locked and not src.noDest and not src.personal
                and (not BKPlanner.NO_SOURCE[src.ctype] or binSrc) and BKRules.isSortable(src.ctype) then
            local ok, items = pcall(function() return src.container:getItems() end)
            if ok and items then
                for i = 0, items:size() - 1 do
                    local item = items:get(i)
                    local class, sure, group
                    if item and not skipItem(item) then
                        local c0, _, s0, g0 = BKItemClass.classify(item)
                        class, sure, group = c0, s0, g0
                        -- v0.14.0 fridge working stock: freezable food past the quota leaves for the freezer; inside
                        -- it, meat the player or the prep put in the fridge stays there
                        if src.ctype == "fridge" and src.powered then
                            local id = m(item, "getID")
                            if id and freezeSet[id] and (class == "food_perishable" or class == "food_freezable") then
                                class = "food_freezable"
                            elseif id and class == "food_freezable" and freezeSet.evaluated[id] then
                                class = "food_perishable"
                            end
                        end
                    end
                    if class and (not binSrc or (sure and BKPlanner.BIN_RESCUE[class])) then
                        local info = BKPlanner.itemInfo(item, class, group)
                        local here = BKRules.score(class, src, group)
                        if here > 0 then here = here + BKPlanner.extraScore(info, class, src, true) end
                        here = BKSections.adjust(src, class, here, group, scan)
                        -- loot areas redistribute: a certain item whose class (or fine group) has an area migrates
                        -- from anywhere else in the zone; an item whose class is not ticked on the area it sits in
                        -- is evicted
                        local hasArea = sure and #designatedFor(scan, class, group) > 0
                        local migrate, evict = false, false
                        if BKLoot.designated(src, class, group) then
                            here = BKLoot.AREA_BONUS + here -- already where its loot area says: never a candidate
                        elseif BKLoot.reserved(src) then
                            here, evict = 0, true           -- inside a loot area that is not for this class
                        elseif hasArea then
                            here, migrate = 0, true         -- its area is elsewhere
                        end
                        -- v0.9.0 exceptions: what does not spoil leaves a powered fridge/freezer, empties leave the bin
                        -- (both like an eviction: any better place will do); meat/fish in a fridge and wrong-season
                        -- clothing may move although their container has a use for them (normal MIN_GAIN applies)
                        local coldOut = BKPlanner.COLD[src.ctype] and src.powered and not BKPlanner.SPOILS[class]
                            and class ~= "trash"
                        if coldOut or binSrc then here, evict = 0, true end
                        local freezeIt = class == "food_freezable" and src.ctype == "fridge"
                        local reseason = class == "clothing" and seasonWant(info) ~= nil
                        -- v0.11.0: an accepted section for the class pulls certain items out of containers that are not
                        -- that section (soft: normal MIN_GAIN, and only into a section container or a specialist)
                        local sectionMove = sure and not hasArea and not BKLoot.reserved(src)
                            and scan.sectionClasses and (scan.sectionClasses[class] == true
                                or (group and scan.sectionClasses[BKTaxonomy.groupKey(group)] == true))
                            and not BKSections.designated(src, class, group)
                        local candidate = sure and (here <= 0 or freezeIt or reseason or sectionMove) and class ~= "rotten"
                            and (class ~= "other" or migrate or evict or sectionMove)
                        -- food never leaves cold storage, except to its own area or out of an area that is not for
                        -- food (allowed() still forces a powered fridge/freezer as the destination)
                        if BKPlanner.COLD[src.ctype] and BKItemClass.isFood(class) and not migrate and not evict
                                and not freezeIt then
                            candidate = false
                        end
                        if candidate then
                            local c, s = BKPlanner.bestDestination(scan, class, sure, item, src, src.container, budget, evict)
                            local minGain = evict and BKPlanner.EVICT_MIN_GAIN or BKPlanner.MIN_GAIN
                            if c and (specialist(class, c, group) or BKLoot.designated(c, class, group)
                                    or BKSections.designated(c, class, group) or evict)
                                    and s - here >= minGain then
                                reserve(c, item, budget)
                                table.insert(jobs, newJob(item, class, sure, src.container, src.ctype, src.x, src.y, src.z,
                                    { srcEntry = src, group = group }, c, s, s - here))
                            end
                        end
                    end
                end
            end
        end
    end

    -- floor jobs first, then piles, bags, container tidy-ups; best gain first inside each group
    table.sort(jobs, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.gain > b.gain
    end)
    local tidyJobs = 0 -- counted before the cap, so a plan full of floor jobs does not look like "nothing to tidy"
    for _, j in ipairs(jobs) do if j.srcEntry ~= nil then tidyJobs = tidyJobs + 1 end end
    while #jobs > BKPlanner.MAX_JOBS do table.remove(jobs) end
    return { zone = zone, scan = scan, places = places, areas = areas, jobs = jobs, piled = piled, left = left,
        tidyJobs = tidyJobs }
end

-- "3 left (no destination 2, placed 1)" or "" when the plan leaves nothing behind.
function BKPlanner.leftSummary(result)
    local left = result and result.left or {}
    if #left == 0 then return "" end
    local counts, keys = {}, {}
    for _, l in ipairs(left) do
        if counts[l.reason] == nil then counts[l.reason] = 0; table.insert(keys, l.reason) end
        counts[l.reason] = counts[l.reason] + 1
    end
    table.sort(keys, function(a, b) if counts[a] ~= counts[b] then return counts[a] > counts[b] end return a < b end)
    local parts = {}
    for _, k in ipairs(keys) do table.insert(parts, k .. " " .. counts[k]) end
    return string.format("%d left (%s)", #left, table.concat(parts, ", "))
end

function BKPlanner.describeLeft(l)
    local want = ""
    if l.want then want = string.format(" wants %s(%s) @%d,%d", l.want.ctype, l.want.place or "?", l.want.x, l.want.y) end
    return string.format("%s [%s] @%d,%d (%s): %s%s", itemLabel(l.item), l.class or "-", l.x, l.y, l.src, l.reason, want)
end

-- ",area N" when the destination (or the container a pile forms next to) sits in a tagged loot area
local function areaTag(dst)
    local c = dst.pile and dst.want or dst
    if c and c.area then return ",area " .. tostring(c.area.id) end
    return ""
end

function BKPlanner.describeJob(j)
    return string.format("%s [%s%s%s] @%d,%d (%s) -> %s(%s%s%s) @%d,%d score=%.1f gain=%.1f",
        itemLabel(j.item), j.class, j.group and ("/" .. j.group) or "", j.sure and "" or "?", j.srcX, j.srcY,
        j.pile and "floor->pile" or j.srcKind,
        j.dst.ctype, j.dst.place or "?", j.dst.pantry and ",pantry" or "", areaTag(j.dst), j.dst.x, j.dst.y,
        j.score, j.gain)
end

function BKPlanner.logPlan(zone)
    local ok, result = pcall(BKPlanner.plan, zone)
    if not ok then BKLog.warn("plan failed: " .. tostring(result)); return nil end
    local scan = result.scan
    local leftSummary = BKPlanner.leftSummary(result)
    BKLog.info(string.format("plan zone %s: %d containers, %d fixtures, %d floor items, %d jobs (%d to piles), %s, %d unloaded squares, %d scan errors",
        tostring(zone.id), #scan.containers, #scan.fixtures, #scan.floorItems, #result.jobs, result.piled or 0,
        leftSummary ~= "" and leftSummary or "0 left", scan.missingSquares or 0, scan.scanErrors or 0))
    local placeParts = {}
    for place, n in pairs(result.places) do table.insert(placeParts, place .. "=" .. n) end
    table.sort(placeParts)
    BKLog.info("places: " .. table.concat(placeParts, " "))
    local areaParts = {}
    for _, a in pairs(scan.areas or {}) do
        table.insert(areaParts, string.format("area %s @%d,%d %dx%d [%s] %d containers", tostring(a.area.id),
            a.area.x1, a.area.y1, a.area.x2 - a.area.x1, a.area.y2 - a.area.y1, BKLoot.labels(a.area), a.containers))
    end
    table.sort(areaParts)
    BKLog.info("loot areas: " .. (#areaParts > 0 and table.concat(areaParts, "; ") or "none"))
    for _, c in ipairs(scan.containers) do
        local free = liveFreeWeight(c)
        BKLog.info(string.format("  container %s @%d,%d place=%s%s room=%s free=%s%s%s%s%s%s", c.ctype, c.x, c.y,
            c.place or "?", c.pantry and " pantry" or "", tostring(c.room),
            free and string.format("%.1f", free) or "?", c.locked and " LOCKED" or "", c.noDest and " nodest" or "",
            (BKPlanner.COLD[c.ctype] and not c.powered) and " UNPOWERED" or "",
            c.area and (" area=" .. tostring(c.area.id)) or "", c.personal and " personal" or "")
            .. (c.section and (" section=" .. c.section) or ""))
    end
    for i, j in ipairs(result.jobs) do
        BKLog.info(string.format("  job %d: %s", i, BKPlanner.describeJob(j)))
    end
    for _, l in ipairs(result.left or {}) do
        BKLog.info("  left: " .. BKPlanner.describeLeft(l))
    end
    return result
end

return BKPlanner
