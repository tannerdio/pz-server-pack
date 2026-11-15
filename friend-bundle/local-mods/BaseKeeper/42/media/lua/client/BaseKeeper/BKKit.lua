-- Base Keeper: kits (v0.9.0).
--   Rule 6, med kit restock: while the player stands inside a zone (awake, at most once per game hour) the carried
--   medical supply is topped up from base containers to BKKit.MED. Items go into a carried first aid kit when there is
--   one, else the main inventory. Toggle in the Base Keeper menu (per character, ModData BKMedRestockOff).
--   Rule 10, run loadout: Base Keeper menu "Pack run loadout" fills the bag on the back (or a bag in hand) with
--   BKKit.LOADOUT from base containers of the zone the player stands in. What the player already carries counts.
-- Sources are the zone's containers (and the loot areas it owns) minus personal areas, locked containers and bins.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlanner"
require "BaseKeeper/UI/BKContextMenu"

BKKit = BKKit or {}
BKKit.lastRestockHour = -1

local function m(obj, name, ...)
    if obj == nil then return nil end
    local fn = obj[name]
    if type(fn) ~= "function" then return nil end
    local ok, r = pcall(fn, obj, ...)
    if ok then return r end
    return nil
end

local function lower(s) return string.lower(tostring(s or "")) end

local function tag(item, name)
    local t = ItemTag and ItemTag[name]
    if t == nil then return false end
    return m(item, "hasTag", t) == true
end

local function fluidOf(item) return m(item, "getFluidContainer") end

local function holdsAlcohol(item)
    local fc = fluidOf(item)
    if fc == nil then return false end
    -- v0.10.4: match the primary fluid's type string; `Fluid.RubbingAlcohol` did not resolve reliably
    local ok, fname = pcall(function() return tostring(fc:getPrimaryFluid():getFluidTypeString()) end)
    if ok and fname == "RubbingAlcohol" then return true end
    if not (Fluid and Fluid.RubbingAlcohol) then return false end
    return m(fc, "contains", Fluid.RubbingAlcohol) == true
end

local function holdsCleanWater(item, minL)
    local fc = fluidOf(item)
    if fc == nil or not (Fluid and Fluid.Water) then return false end
    if m(fc, "isPureFluid", Fluid.Water) ~= true then return false end
    return (tonumber(m(fc, "getAmount")) or 0) >= (minL or 0.5)
end

local function hunger(item) return -(tonumber(m(item, "getHungChange")) or 0) end

local function ofType(...)
    local set = {}
    for _, t in ipairs({ ... }) do set[t] = true end
    return function(item) return set[m(item, "getFullType")] == true end
end

-- Medical targets (rule 6). Bandage rows list the preferred type first.
BKKit.MED = {
    { label = "bandages", want = 4, match = ofType("Base.AlcoholBandage", "Base.Bandage"),
        prefer = function(item) return m(item, "getFullType") == "Base.AlcoholBandage" end },
    { label = "disinfectant", want = 1, match = function(item) return m(item, "getFullType") == "Base.Disinfectant" end,
        source = holdsAlcohol },
    { label = "painkillers", want = 1, match = ofType("Base.Pills") },
    { label = "suture needle", want = 1, match = ofType("Base.SutureNeedle") },
}

-- Every item the player carries, bags included (one walk, recursive).
local function carried(player)
    local out = {}
    local function walk(inv, depth)
        local items = m(inv, "getItems")
        if not items or depth > 3 then return end
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            table.insert(out, it)
            if m(it, "IsInventoryContainer") == true then walk(m(it, "getInventory"), depth + 1) end
        end
    end
    walk(player:getInventory(), 0)
    return out
end

local function countCarried(list, match)
    local n = 0
    for _, it in ipairs(list) do if match(it) then n = n + 1 end end
    return n
end

-- Base stock the kits may draw from: { {item, container} } for every container of the player's zone.
local SKIP_SRC = { bin = true, dumpster = true, composter = true }
local function baseStock(zone)
    local out = {}
    local ok, scan = pcall(BKZoneScan.scanBase, zone)
    if not ok or not scan then BKLog.warn("kit: scan failed " .. tostring(scan)); return out end
    for _, c in ipairs(scan.containers) do
        if not c.personal and not c.locked and not c.noDest and not SKIP_SRC[c.ctype] then
            local items = m(c.container, "getItems")
            for i = 0, (items and items:size() or 0) - 1 do
                local it = items:get(i)
                if it and m(it, "isFavorite") ~= true then
                    table.insert(out, { item = it, container = c.container, entry = c })
                end
            end
        end
    end
    return out
end

local function hasRoom(dest, player, item)
    local ok, room = pcall(function() return dest:hasRoomFor(player, item) end)
    if ok and room ~= nil then return room == true end
    return true
end

local function move(stockRow, dest)
    local item, src = stockRow.item, stockRow.container
    if item:getContainer() ~= src then return false end
    src:Remove(item)
    dest:AddItem(item)
    if item:getContainer() ~= dest then src:AddItem(item); return false end
    if stockRow.entry and stockRow.entry.obj and ItemPicker and ItemPicker.updateOverlaySprite then
        pcall(ItemPicker.updateOverlaySprite, stockRow.entry.obj)
    end
    stockRow.used = true
    return true
end

-- Take up to n items matching row from stock into dest. Returns how many moved.
local function take(stock, row, n, dest, player)
    if n <= 0 then return 0 end
    local cands = {}
    for _, s in ipairs(stock) do
        if not s.used and row.match(s.item) and (row.source == nil or row.source(s.item)) then table.insert(cands, s) end
    end
    if row.sort then
        table.sort(cands, function(a, b) return row.sort(a.item, b.item) end)
    elseif row.prefer then
        table.sort(cands, function(a, b)
            local pa, pb = row.prefer(a.item) and 1 or 0, row.prefer(b.item) and 1 or 0
            return pa > pb
        end)
    end
    local moved = 0
    for _, s in ipairs(cands) do
        if moved >= n then break end
        if hasRoom(dest, player, s.item) and move(s, dest) then moved = moved + 1 end
    end
    return moved
end

local function playerZone(player)
    return BKZones.at(math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
end

local function halo(player, text, bad)
    if not HaloTextHelper then return end
    pcall(bad and HaloTextHelper.addBadText or HaloTextHelper.addText, player, text)
end

-- Rule 6 ---------------------------------------------------------------------------------------------------

local function kitInventory(player)
    for _, it in ipairs(carried(player)) do
        if string.find(lower(m(it, "getType")), "firstaidkit", 1, true) and m(it, "IsInventoryContainer") == true then
            return m(it, "getInventory")
        end
    end
    return player:getInventory()
end

function BKKit.restockOff(player)
    return player and player:getModData().BKMedRestockOff == true
end

function BKKit.restock(player, force)
    if isClient() then return end -- v0.19.0: moves items directly, single player only
    if player == nil or BKKit.restockOff(player) then return end
    if m(player, "isAsleep") == true or m(player, "isDead") == true then return end
    local zone = playerZone(player)
    if zone == nil then return end
    local hour = math.floor(tonumber(m(getGameTime(), "getWorldAgeHours")) or 0)
    if not force and hour == BKKit.lastRestockHour then return end
    BKKit.lastRestockHour = hour
    local have = carried(player)
    local need = false
    for _, row in ipairs(BKKit.MED) do
        if countCarried(have, row.match) < row.want then need = true; break end
    end
    if not need then return end
    local stock = baseStock(zone)
    local dest = kitInventory(player)
    local parts = {}
    for _, row in ipairs(BKKit.MED) do
        local n = take(stock, row, row.want - countCarried(have, row.match), dest, player)
        if n > 0 then table.insert(parts, n .. " " .. row.label) end
    end
    if #parts > 0 then
        local msg = "Med kit topped up: " .. table.concat(parts, ", ")
        BKLog.info(msg)
        halo(player, msg)
    end
end

local function onTenMinutes()
    local ok, err = pcall(BKKit.restock, getSpecificPlayer(0), false)
    if not ok then BKLog.warn("restock failed: " .. tostring(err)) end
end

-- Rule 10 --------------------------------------------------------------------------------------------------

local function isClass(classes)
    return function(item)
        local class = BKItemClass.classify(item)
        return classes[class] == true
    end
end

local function isSpice(item) return m(item, "isSpice") == true end

-- Rows are built per call because the ammo rows depend on the gun in hand.
function BKKit.loadoutRows(player)
    local rows = {
        { label = "water", want = 1, match = function(it) return holdsCleanWater(it, 0.5) end },
        { label = "food", want = 4,
            match = function(it)
                return not isSpice(it) and isClass({ food_dry = true, food_canned = true })(it)
            end,
            sort = function(a, b) return hunger(a) > hunger(b) end },
        { label = "can opener", want = 1, match = ofType("Base.TinOpener"), onlyIf = "cans" },
        { label = "hammer", want = 1, match = function(it) return tag(it, "HAMMER") end },
        { label = "nails", want = 20, match = ofType("Base.Nails") },
        { label = "bandages", want = 4, match = ofType("Base.AlcoholBandage", "Base.Bandage"),
            prefer = function(it) return m(it, "getFullType") == "Base.AlcoholBandage" end },
        { label = "disinfectant", want = 1, match = ofType("Base.Disinfectant"), source = holdsAlcohol },
    }
    local gun = player:getPrimaryHandItem()
    if gun and m(gun, "IsWeapon") == true and m(gun, "isRanged") == true then
        local key = BKPlanner.ammoKey(gun)
        if key and key ~= "" then
            local function sameAmmo(it)
                return m(it, "IsWeapon") ~= true and BKPlanner.ammoKey(it) == key
            end
            table.insert(rows, { label = "ammo boxes", want = 2,
                match = function(it) return sameAmmo(it) and string.find(lower(m(it, "getType")), "box", 1, true) ~= nil end })
            local magType = m(gun, "getMagazineType")
            if magType and magType ~= "" then
                table.insert(rows, { label = "magazines", want = 2, match = ofType(magType) })
            end
            table.insert(rows, { label = "loose rounds", want = 30, onlyIf = "fewBoxes",
                match = function(it)
                    local t = lower(m(it, "getType"))
                    return sameAmmo(it) and not string.find(t, "box", 1, true) and not string.find(t, "clip", 1, true)
                        and not string.find(t, "magazine", 1, true)
                end })
        end
    end
    return rows
end

local function runBag(player)
    local back = m(player, "getClothingItem_Back")
    if back and m(back, "IsInventoryContainer") == true then return back end
    for _, it in ipairs({ player:getPrimaryHandItem(), player:getSecondaryHandItem() }) do
        if it and m(it, "IsInventoryContainer") == true then return it end
    end
    return nil
end

function BKKit.packLoadout(player)
    if isClient() then halo(player, "Run loadout is single player only", true); return end -- moves items directly
    local bag = runBag(player)
    if bag == nil then halo(player, "Run loadout: wear a backpack or hold a bag first", true); return end
    local zone = playerZone(player)
    if zone == nil then halo(player, "Run loadout: stand inside a Base Keeper zone", true); return end
    local dest = bag:getInventory()
    local stock = baseStock(zone)
    local have = carried(player)
    local parts, short = {}, {}
    local tookCans, boxes = false, 0
    for _, row in ipairs(BKKit.loadoutRows(player)) do
        local skip = (row.onlyIf == "cans" and not tookCans) or (row.onlyIf == "fewBoxes" and boxes >= 2)
        if not skip then
            local missing = row.want - countCarried(have, row.match)
            local n = take(stock, row, missing, dest, player)
            if row.label == "food" then
                -- a can in the bag (packed now or already there) needs an opener
                local items = m(dest, "getItems")
                for i = 0, (items and items:size() or 0) - 1 do
                    if BKItemClass.classify(items:get(i)) == "food_canned" then tookCans = true; break end
                end
            end
            if row.label == "ammo boxes" then boxes = countCarried(have, row.match) + n end
            if n > 0 then table.insert(parts, n .. " " .. row.label) end
            if missing > 0 and n < missing then table.insert(short, row.label) end
        end
    end
    local msg = (#parts > 0) and ("Packed " .. table.concat(parts, ", ")) or "Run loadout: already carrying everything"
    if #short > 0 then msg = msg .. " | short: " .. table.concat(short, ", ") end
    BKLog.info("run loadout: " .. msg)
    halo(player, msg, #parts == 0 and #short > 0)
end

-- Menu -----------------------------------------------------------------------------------------------------

table.insert(BKContextMenu.globalActions, {
    label = "Pack run loadout (bag on back)",
    fn = function(player)
        local ok, err = pcall(BKKit.packLoadout, player)
        if not ok then BKLog.warn("loadout failed: " .. tostring(err)) end
    end,
})
table.insert(BKContextMenu.globalActions, {
    label = function()
        local p = getSpecificPlayer(0)
        return BKKit.restockOff(p) and "Med kit auto-restock: OFF (turn on)" or "Med kit auto-restock: ON (turn off)"
    end,
    fn = function(player)
        local md = player:getModData()
        md.BKMedRestockOff = not (md.BKMedRestockOff == true)
        if not md.BKMedRestockOff then pcall(BKKit.restock, player, true) end
    end,
})

Events.EveryTenMinutes.Add(onTenMinutes)

return BKKit
