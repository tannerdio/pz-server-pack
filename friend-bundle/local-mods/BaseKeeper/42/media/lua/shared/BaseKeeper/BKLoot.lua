-- Base Keeper: loot areas. A second kind of rectangle, marked like a zone, then tagged with one or more item
-- categories from the right-click menu. Containers inside a tagged area are where those categories go first,
-- any distance inside the sorting zone; the default rules (BKRules) stay the fallback for every category that
-- has no area. A container inside a tagged area only takes that area's categories. An area with no categories
-- ticked is inert. "Personal (hands off)" is the exception: the keeper never stores anything in such an area, never
-- takes anything out of its containers, bags or floor, never piles next to it and never cooks from it; ticking it
-- clears every other category and ticking another clears it. Rectangles live in global ModData
-- ("BaseKeeperLootAreas"), same mechanism as BKZones; ends are exclusive. Fires BaseKeeper_AreasChanged(area) on
-- every add / remove / category change.
require "BaseKeeper/BKLog"
require "BaseKeeper/Engine/BKTaxonomy"

BKLoot = BKLoot or {}

BKLoot.MODDATA_KEY = "BaseKeeperLootAreas"
BKLoot.MIN_SIDE = 1
BKLoot.MAX_SIDE = 60
BKLoot.STRICT = true     -- a category with an area never falls back outside it: full area -> pile next to it
BKLoot.AREA_BONUS = 20   -- added to every designated container's score, so an area always beats the default rules

-- Player-facing categories. Two kinds (v0.12.0): the broad ones match item classes (BKItemClass.CLASSES) exactly as
-- before, so every area Tanner already tagged keeps working; the fine ones (key "g:<group>", generated from
-- BKTaxonomy.GROUPS) match the item's purpose group, e.g. "Cleaning (bleach, mops, buckets)" or "Carpentry". Both
-- kinds sit under a family for the menus. An item matches a category when its class is in cat.classes or its
-- group is in cat.groups.
BKLoot.CATEGORIES = {
    { key = "food_cold", label = "Fresh & frozen food", classes = { "food_perishable", "food_freezable", "food_frozen" }, family = "food" },
    { key = "food_shelf", label = "Dry & canned food", classes = { "food_dry", "food_canned" }, family = "food" },
    { key = "drink", label = "Drinks", classes = { "drink" }, family = "food" },
    { key = "cooking", label = "Cooking gear", classes = { "cooking" }, family = "kitchen" },
    { key = "tool", label = "Tools (all)", classes = { "tool" }, family = "workshop" },
    { key = "mechanics", label = "Car parts", classes = { "mechanics" }, family = "vehicle" },
    { key = "fuel", label = "Fuel", classes = { "fuel" }, family = "vehicle" },
    { key = "build_material", label = "Building materials (all)", classes = { "build_material" }, family = "workshop" },
    { key = "medical", label = "Medical", classes = { "medical" }, family = "medical" },
    { key = "hygiene", label = "Hygiene & cleaning (all)", classes = { "hygiene" }, family = "home" },
    { key = "clothing", label = "Clothing (all)", classes = { "clothing" }, family = "wardrobe" },
    { key = "weapon", label = "Weapons (all)", classes = { "weapon" }, family = "armory" },
    { key = "ammo", label = "Ammo", classes = { "ammo" }, family = "armory" },
    { key = "literature", label = "Books & paper (all)", classes = { "literature" }, family = "office" },
    { key = "electronics", label = "Electronics (all)", classes = { "electronics" }, family = "office" },
    { key = "container", label = "Bags & containers", classes = { "container" }, family = "misc" },
    { key = "empties", label = "Empty bottles", classes = { "empties" }, family = "misc" },
    { key = "depleted", label = "Needs refill", classes = { "depleted" }, family = "misc" },
    { key = "junk", label = "Junk", classes = { "junk" }, family = "misc" },
    { key = "trash", label = "Trash (bins only)", classes = { "trash" }, family = "misc" },
    { key = "other", label = "Everything else", classes = { "other" }, family = "misc" },
    { key = "personal", label = "Personal (hands off)", classes = {}, personal = true, family = "misc" },
}
BKLoot.PERSONAL = "personal"

-- fine groups that only repeat a broad category above, or are not something to give a shelf
BKLoot.NO_GROUP_CATEGORY = { medical = true, mechanics = true, fuel = true, ammo = true, cook_ware = true,
    empties = true, depleted = true, junk = true, trash = true, other = true, ignore = true, keys = true }
if BKTaxonomy and BKTaxonomy.GROUPS then
    for _, g in ipairs(BKTaxonomy.GROUPS) do
        if not BKLoot.NO_GROUP_CATEGORY[g.key] then
            table.insert(BKLoot.CATEGORIES, { key = BKTaxonomy.groupKey(g.key), label = g.label, classes = {},
                groups = { g.key }, family = g.family, fine = true })
        end
    end
end

-- keys an item answers to: its class and "g:<group>"
function BKLoot.itemKeys(class, group)
    local keys = { class }
    if group then table.insert(keys, BKTaxonomy.groupKey(group)) end
    return keys
end

-- Categories of one family in menu order (broad first, then fine).
function BKLoot.categoriesOf(family)
    local out = {}
    for _, cat in ipairs(BKLoot.CATEGORIES) do
        if (cat.family or "misc") == family then table.insert(out, cat) end
    end
    return out
end

-- v0.16.0 selection model (Tanner: "select the whole upper level category and then edit out smaller pieces").
-- A broad category takes items by class, a fine one by purpose group, and an area may now also carry
-- area.excl = { ["g:<group>"] = true }: groups it refuses even though a ticked broad category would take them by
-- class ("Tools" minus "Paint & decorating"). PARENTS[fineKey] = the broad keys that take that group's items by
-- class, CHILDREN[broadKey] = the reverse. The functions below work on any table with .cats and .excl (an area, or
-- the editor window's working copy).
BKLoot.PARENTS, BKLoot.CHILDREN = {}, {}
do
    local FOOD_BROAD = { food_cold = true, food_shelf = true }
    for _, fine in ipairs(BKLoot.CATEGORIES) do
        if fine.fine then
            local g = BKTaxonomy.get(fine.groups[1])
            local gclass = g and g.class or nil
            BKLoot.PARENTS[fine.key] = {}
            for _, broad in ipairs(BKLoot.CATEGORIES) do
                if not broad.fine and not broad.personal then
                    local takes = gclass == "food" and FOOD_BROAD[broad.key] == true
                    for _, cls in ipairs(broad.classes or {}) do if cls == gclass then takes = true end end
                    if takes then
                        table.insert(BKLoot.PARENTS[fine.key], broad.key)
                        BKLoot.CHILDREN[broad.key] = BKLoot.CHILDREN[broad.key] or {}
                        table.insert(BKLoot.CHILDREN[broad.key], fine.key)
                    end
                end
            end
        end
    end
end

-- "Carpentry (hammers, saws, nails, screws)" -> "Carpentry"
function BKLoot.shortLabel(cat)
    local s = string.gsub(cat.label, "%s*%(.*%)%s*$", "")
    return s
end

-- a ticked broad category already takes this fine group's items by class
function BKLoot.covered(sel, fineKey)
    for _, p in ipairs(BKLoot.PARENTS[fineKey] or {}) do
        if sel.cats and sel.cats[p] == true then return true end
    end
    return false
end

-- the selection takes this category: a broad one when ticked, a fine one when ticked or covered and not edited out
function BKLoot.isOn(sel, key)
    local cat = BKLoot.category(key)
    if cat == nil then return false end
    if cat.fine then
        if sel.excl and sel.excl[key] == true then return false end
        return (sel.cats ~= nil and sel.cats[key] == true) or BKLoot.covered(sel, key)
    end
    return sel.cats ~= nil and sel.cats[key] == true
end

-- Ticks / unticks one category on a selection table (no ModData, no event). Unticking a fine category under a
-- ticked broad one records an exclusion; ticking a broad one clears the exclusions under it.
function BKLoot.toggle(sel, key, on)
    local cat = BKLoot.category(key)
    if cat == nil then return end
    sel.cats = sel.cats or {}
    sel.excl = sel.excl or {}
    if cat.personal then
        if on then sel.cats, sel.excl = { [key] = true }, {} else sel.cats[key] = nil end
        return
    end
    if on then sel.cats[BKLoot.PERSONAL] = nil end
    if cat.fine then
        if on then
            sel.excl[key] = nil
            if not BKLoot.covered(sel, key) then sel.cats[key] = true end
        else
            sel.cats[key] = nil
            if BKLoot.covered(sel, key) then sel.excl[key] = true end
        end
        return
    end
    if on then
        sel.cats[key] = true
        for _, child in ipairs(BKLoot.CHILDREN[key] or {}) do sel.excl[child] = nil; sel.cats[child] = nil end
    else
        sel.cats[key] = nil
        for _, child in ipairs(BKLoot.CHILDREN[key] or {}) do
            if not BKLoot.covered(sel, child) then sel.excl[child] = nil end
        end
    end
end

-- rows of one family that are on, and how many rows it has (personal is not a family row)
function BKLoot.familyState(sel, family)
    local on, total = 0, 0
    for _, cat in ipairs(BKLoot.categoriesOf(family)) do
        if not cat.personal then
            total = total + 1
            if BKLoot.isOn(sel, cat.key) then on = on + 1 end
        end
    end
    return on, total
end

-- the whole family on or off: broad rows first, so the fine rows under them need no entry of their own
function BKLoot.toggleFamily(sel, family, on)
    local cats = BKLoot.categoriesOf(family)
    for _, cat in ipairs(cats) do
        if not cat.fine and not cat.personal then BKLoot.toggle(sel, cat.key, on) end
    end
    for _, cat in ipairs(cats) do
        if cat.fine then BKLoot.toggle(sel, cat.key, on) end
    end
end

BKLoot.data = nil -- { nextId = n, areas = { ["1"] = { id, x1, y1, x2, y2, z, cats = { key = true }, excl = { ["g:x"] = true }, owner }, ... } }

LuaEventManager.AddEvent("BaseKeeper_AreasChanged")

local function store()
    if BKLoot.data == nil then
        BKLoot.data = ModData.getOrCreate(BKLoot.MODDATA_KEY)
    end
    local d = BKLoot.data
    if d.nextId == nil then d.nextId = 1 end
    if d.areas == nil then d.areas = {} end
    return d
end

local function changed(area)
    if isServer() then ModData.transmit(BKLoot.MODDATA_KEY) end
    triggerEvent("BaseKeeper_AreasChanged", area)
end

function BKLoot.init()
    local d = store()
    local count = 0
    for _ in pairs(d.areas) do count = count + 1 end
    BKLog.info("loot areas loaded: " .. count)
end

function BKLoot.category(key)
    for _, cat in ipairs(BKLoot.CATEGORIES) do
        if cat.key == key then return cat end
    end
    return nil
end

function BKLoot.list()
    local out = {}
    for _, area in pairs(store().areas) do table.insert(out, area) end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function BKLoot.get(id)
    return store().areas[tostring(id)]
end

function BKLoot.contains(area, x, y, z)
    return z == area.z and x >= area.x1 and x < area.x2 and y >= area.y1 and y < area.y2
end

-- First area covering the tile, or nil.
function BKLoot.at(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    for _, area in pairs(store().areas) do
        if BKLoot.contains(area, x, y, z) then return area end
    end
    return nil
end

function BKLoot.overlaps(area, x1, y1, x2, y2, z)
    return area.z == z and x1 < area.x2 and x2 > area.x1 and y1 < area.y2 and y2 > area.y1
end

-- (no next() in the game's Lua: pairs is the only way to ask "is this table empty")
function BKLoot.hasCategories(area)
    if area.cats == nil then return false end
    for _ in pairs(area.cats) do return true end
    return false
end

-- The area is hands off: nothing goes in, nothing comes out, no piles next to it, no cooking from it.
function BKLoot.isPersonal(area)
    return area ~= nil and area.cats ~= nil and area.cats[BKLoot.PERSONAL] == true
end

-- The tile sits inside a personal area.
function BKLoot.isPersonalAt(x, y, z)
    return BKLoot.isPersonal(BKLoot.at(x, y, z))
end

-- item key -> true for every class ("tool") and fine group ("g:carpentry") the area's categories cover
function BKLoot.classSet(area)
    local set = {}
    for _, cat in ipairs(BKLoot.CATEGORIES) do
        if area.cats and area.cats[cat.key] then
            for _, class in ipairs(cat.classes or {}) do set[class] = true end
            for _, g in ipairs(cat.groups or {}) do set[BKTaxonomy.groupKey(g)] = true end
        end
    end
    return set
end

-- "Tools, Fuel" in menu order, or "no categories yet"
function BKLoot.labels(area)
    if BKLoot.isPersonal(area) then return "Personal (hands off)" end
    local parts, done = {}, {}
    for _, fam in ipairs(BKTaxonomy.FAMILIES) do
        local on, total = BKLoot.familyState(area, fam.key)
        if total > 0 and on == total then
            table.insert(parts, fam.label .. " (all)")
            for _, cat in ipairs(BKLoot.categoriesOf(fam.key)) do done[cat.key] = true end
        end
    end
    for _, cat in ipairs(BKLoot.CATEGORIES) do
        if not done[cat.key] and area.cats and area.cats[cat.key] then table.insert(parts, BKLoot.shortLabel(cat)) end
    end
    if #parts == 0 then return "no categories yet" end
    local text = table.concat(parts, ", ")
    local minus = {}
    for _, cat in ipairs(BKLoot.CATEGORIES) do
        if area.excl and area.excl[cat.key] then table.insert(minus, BKLoot.shortLabel(cat)) end
    end
    if #minus > 0 then text = text .. " | not: " .. table.concat(minus, ", ") end
    return text
end

function BKLoot.describe(area)
    return string.format("id=%s x=%d y=%d w=%d h=%d z=%d [%s]",
        tostring(area.id), area.x1, area.y1, area.x2 - area.x1, area.y2 - area.y1, area.z, BKLoot.labels(area))
end

local function validate(x1, y1, x2, y2, z)
    if x2 <= x1 or y2 <= y1 then return false, "empty rectangle" end
    local w, h = x2 - x1, y2 - y1
    if w < BKLoot.MIN_SIDE or h < BKLoot.MIN_SIDE then return false, "too small (min " .. BKLoot.MIN_SIDE .. ")" end
    if w > BKLoot.MAX_SIDE or h > BKLoot.MAX_SIDE then return false, "too large (max " .. BKLoot.MAX_SIDE .. ")" end
    for _, area in pairs(store().areas) do
        if BKLoot.overlaps(area, x1, y1, x2, y2, z) then return false, "overlaps loot area " .. tostring(area.id) end
    end
    return true
end

-- Authority-side add. Areas may overlap sorting zones (they are meant to sit inside one) but not each other.
function BKLoot.add(x1, y1, x2, y2, z, ownerName)
    x1, y1, x2, y2, z = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), math.floor(z)
    local ok, reason = validate(x1, y1, x2, y2, z)
    if not ok then
        BKLog.warn("loot area rejected: " .. reason)
        return nil, reason
    end
    local d = store()
    local area = {
        id = d.nextId,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z,
        cats = {},
        owner = ownerName,
        createdAt = getGameTime() and getGameTime():getWorldAgeHours() or 0,
    }
    d.nextId = d.nextId + 1
    d.areas[tostring(area.id)] = area
    BKLog.info("loot area added " .. BKLoot.describe(area))
    if BKZones and BKZones.list then
        local inZone = false
        for _, zone in ipairs(BKZones.list()) do
            if BKZones.overlaps(zone, x1, y1, x2, y2, z) then inZone = true end
        end
        if not inZone then
            BKLog.info("loot area " .. tostring(area.id) .. " is outside every sorting zone: it receives loot once tagged, but its own floor is not an inbox")
        end
    end
    changed(area)
    return area
end

function BKLoot.remove(id)
    local d = store()
    local key = tostring(id)
    local area = d.areas[key]
    if area == nil then return false end
    d.areas[key] = nil
    BKLog.info("loot area removed " .. BKLoot.describe(area))
    changed(area)
    return true
end

function BKLoot.setCategory(id, key, on)
    local area = BKLoot.get(id)
    if area == nil or BKLoot.category(key) == nil then return false end
    -- personal is exclusive: it replaces every other category, and any other category replaces it
    BKLoot.toggle(area, key, on == true)
    BKLog.info("loot area " .. tostring(area.id) .. " categories: " .. BKLoot.labels(area))
    changed(area)
    return true
end

-- v0.16.0: the editor window sends the whole selection at once. Unknown keys are dropped, exclusions only stand
-- for fine categories a ticked broad one still covers, personal stays exclusive.
function BKLoot.setCats(id, cats, excl)
    local area = BKLoot.get(id)
    if area == nil then return false end
    local sel = { cats = {}, excl = {} }
    for key, v in pairs(cats or {}) do
        if v == true and BKLoot.category(key) then sel.cats[key] = true end
    end
    if sel.cats[BKLoot.PERSONAL] then
        sel.cats = { [BKLoot.PERSONAL] = true }
    else
        for key, v in pairs(excl or {}) do
            local cat = BKLoot.category(key)
            if v == true and cat and cat.fine and BKLoot.covered(sel, key) then sel.excl[key] = true; sel.cats[key] = nil end
        end
    end
    area.cats, area.excl = sel.cats, sel.excl
    BKLog.info("loot area " .. tostring(area.id) .. " categories: " .. BKLoot.labels(area))
    changed(area)
    return true
end

function BKLoot.requestSetCats(player, id, cats, excl)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "setAreaCats", { id = id, cats = cats, excl = excl })
        return
    end
    BKLoot.setCats(id, cats, excl)
end

-- Called by the client UI. Single-player: same Lua state, act directly. Multiplayer client: ask the server.
function BKLoot.requestAdd(player, x1, y1, x2, y2, z)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "addArea", { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z })
        return nil
    end
    local name = player and player.getUsername and player:getUsername() or nil
    return BKLoot.add(x1, y1, x2, y2, z, name)
end

function BKLoot.requestRemove(player, id)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "removeArea", { id = id })
        return
    end
    BKLoot.remove(id)
end

function BKLoot.requestSetCategory(player, id, key, on)
    if isClient() then
        sendClientCommand(player, "BaseKeeper", "setAreaCategory", { id = id, key = key, on = on == true })
        return
    end
    BKLoot.setCategory(id, key, on)
end

-- Planner side: tags every scanned container with its tagged area (c.area, c.areaClasses) and builds
-- scan.designated = { class -> { container entries } }. Returns the number of tagged areas touching the scan.
function BKLoot.annotate(scan)
    scan.designated = {}
    local areas = {}
    for _, c in ipairs(scan.containers) do
        c.area, c.areaClasses, c.areaExcl = nil, nil, nil
        local area = BKLoot.at(c.x, c.y, c.z)
        if area and BKLoot.hasCategories(area) then
            local key = tostring(area.id)
            areas[key] = areas[key] or { area = area, classes = BKLoot.classSet(area), containers = 0 }
            areas[key].containers = areas[key].containers + 1
            c.area = area
            c.areaClasses = areas[key].classes -- empty for a personal area: reserved for nothing, designated for nothing
            c.areaExcl = area.excl                 -- v0.16.0: "g:<group>" keys the area refuses despite a class match
            c.personal = BKLoot.isPersonal(area) or nil
            if not c.noDest and not c.locked and not c.personal then
                for class in pairs(c.areaClasses) do
                    scan.designated[class] = scan.designated[class] or {}
                    table.insert(scan.designated[class], c)
                end
            end
        end
    end
    scan.areas = areas
    local n = 0
    for _ in pairs(areas) do n = n + 1 end
    return n
end

-- The container sits in a tagged area that lists this class or (v0.12.0) this fine group.
function BKLoot.designated(c, class, group)
    if c.areaClasses == nil then return false end
    if group ~= nil and c.areaExcl and c.areaExcl[BKTaxonomy.groupKey(group)] == true then return false end
    if c.areaClasses[class] == true then return true end
    return group ~= nil and c.areaClasses[BKTaxonomy.groupKey(group)] == true
end

-- The container sits in a tagged area, so it only takes that area's classes.
function BKLoot.reserved(c)
    return c.areaClasses ~= nil
end

-- Multiplayer plumbing (server receives UI requests; clients receive the transmitted table).
local function onClientCommand(module, command, player, args)
    if module ~= "BaseKeeper" or type(args) ~= "table" then return end
    if command == "addArea" then
        local x1, y1, x2, y2, z = tonumber(args.x1), tonumber(args.y1), tonumber(args.x2), tonumber(args.y2), tonumber(args.z)
        if x1 and y1 and x2 and y2 and z then
            BKLoot.add(x1, y1, x2, y2, z, player and player:getUsername() or nil)
        end
    elseif command == "removeArea" then
        if tonumber(args.id) then BKLoot.remove(tonumber(args.id)) end
    elseif command == "setAreaCats" then
        if tonumber(args.id) and type(args.cats) == "table" then
            BKLoot.setCats(tonumber(args.id), args.cats, type(args.excl) == "table" and args.excl or nil)
        end
    elseif command == "setAreaCategory" then
        if tonumber(args.id) and type(args.key) == "string" then
            BKLoot.setCategory(tonumber(args.id), args.key, args.on == true)
        end
    end
end

local function onReceiveGlobalModData(key, data)
    if key ~= BKLoot.MODDATA_KEY or type(data) ~= "table" then return end
    if ModData.add then ModData.add(key, data) end
    BKLoot.data = data
    BKLoot.init()
    triggerEvent("BaseKeeper_AreasChanged", nil)
end

Events.OnInitGlobalModData.Add(function()
    BKLoot.data = nil
    BKLoot.init()
    if isClient() and ModData.request then ModData.request(BKLoot.MODDATA_KEY) end
end)
if isServer() then Events.OnClientCommand.Add(onClientCommand) end
if isClient() then Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData) end

return BKLoot
