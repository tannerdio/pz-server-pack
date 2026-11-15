-- Base Keeper: laundry (v0.11.0, Tanner 2026-11-06: "auto clean bandages and clothes in storage, give xp if the game
-- would give it for me doing it"). The game gives no XP for either: craftRecipe CleanBandage has no xpAward and
-- ISWashClothing:complete never calls addXp, so none is awarded here.
--
-- Every ten game minutes, only while the player is inside a zone (or within NEAR_TILES of it), per zone:
--   * dirty bandages / rags / denim and leather strips (items with ItemAfterCleaning) in storage become the clean item,
--     0.5 L of water each from a water source in the zone (vanilla CleanBandage: categories[Water], so rain water does).
--   * bloody or dirty clothing in storage (decided with Tanner: washer/dryer when powered, else hand-wash, no soap):
--       washer path: a powered clothing washer with water, idle and empty, is loaded with dirty clothes and switched on
--       (same call as vanilla ISToggleClothingWasher). Once it is off again, or every load is clean, the clean clothes
--       go to an idle powered dryer which is switched on; with no dryer they go back to storage wet. Once the dryer is
--       off or every load is dry, they go back to the best clothing container (BKPlanner rules, sections, areas).
--       An appliance the keeper switched on is switched off again when its load is done, so it ends as found.
--       Only loads the keeper put in are ever taken out.
--     hand-wash fallback (no usable washer in the zone): vanilla ISWashClothing:complete without soap, water by
--       ISWashClothing.GetRequiredWater from the zone's water source; the item comes out 100% wet like vanilla.
-- Sources: containers in the zone and the loot areas it owns, minus personal areas, locked containers, bins and
-- appliances; never what the player carries, never vehicles. Rain water is used before clean water.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/BKSections"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlaces"
require "BaseKeeper/Engine/BKPlanner"
require "BaseKeeper/UI/BKContextMenu"

BKLaundry = BKLaundry or {}

BKLaundry.MODDATA_KEY = "BaseKeeperLaundry"
BKLaundry.NEAR_TILES = 4
BKLaundry.BANDAGES_PER_TICK = 6
BKLaundry.HANDWASH_PER_TICK = 3
BKLaundry.BANDAGE_WATER = 0.5          -- litres, craftRecipe CleanBandage
BKLaundry.MIN_CYCLE_HOURS = 1.5        -- a running appliance whose whole load is done is switched off after this
BKLaundry.STUCK_HOURS = 12             -- a load still not done after this is taken out as it is
BKLaundry.SKIP_SOURCE = { bin = true, dumpster = true, composter = true }

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function m(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return nil end
    local ok2, r = pcall(fn, obj, ...)
    if ok2 then return r end
    return nil
end

local function worldHours() return tonumber(safe(function() return getGameTime():getWorldAgeHours() end)) or 0 end
local function name(item) return tostring(m(item, "getDisplayName") or m(item, "getFullType") or "?") end

local function store()
    local d = ModData.getOrCreate(BKLaundry.MODDATA_KEY)
    if d.loads == nil then d.loads = {} end
    return d
end

function BKLaundry.enabled() return store().off ~= true end

-- Item state ------------------------------------------------------------------------------------------------------

local function isClothing(item) return instanceof(item, "Clothing") end

local function coveredParts(item)
    local bct = m(item, "getBloodClothingType")
    if bct == nil or BloodClothingType == nil then return nil end
    return safe(function() return BloodClothingType.getCoveredParts(bct) end)
end

-- blood + dirt over every covered part (what ISWashClothing.GetRequiredWater reads), plus the item-level values
local function grime(item)
    local total = (tonumber(m(item, "getBloodLevel")) or 0) + (tonumber(m(item, "getDirtiness")) or 0)
    local parts = coveredParts(item)
    if parts then
        for i = 0, parts:size() - 1 do
            local p = parts:get(i)
            total = total + (tonumber(safe(function() return item:getBlood(p) end)) or 0)
                + (tonumber(safe(function() return item:getDirt(p) end)) or 0)
        end
    end
    return total
end

local function dirtyBandage(item)
    if isClothing(item) then return nil end
    local after = m(item, "getItemAfterCleaning")
    if after == nil or after == "" then return nil end
    return tostring(after)
end

local function dirtyClothes(item)
    return isClothing(item) and m(item, "isEquipped") ~= true and grime(item) > 0
end

local function wet(item) return (tonumber(m(item, "getWetness")) or 0) > 0 end

-- Water ------------------------------------------------------------------------------------------------------------

-- Water sources in the zone, rain water first (vanilla washes with tainted water too), then the fullest.
local function waterSources(zone)
    if not (BKCook and BKCook.scanWater) then return {} end
    local list = safe(BKCook.scanWater, zone) or {}
    table.sort(list, function(a, b)
        if a.tainted ~= b.tainted then return a.tainted end
        return a.amount > b.amount
    end)
    return list
end

local function takeWater(sources, litres)
    for _, w in ipairs(sources) do
        local have = tonumber(safe(function() return w.obj:getFluidAmount() end)) or 0
        if have >= litres then
            local ok = pcall(function() w.obj:useFluid(litres) end)
            if ok then return true end
        end
    end
    return false
end

-- Moving -----------------------------------------------------------------------------------------------------------

local function moveTo(item, dest)
    local src = m(item, "getContainer")
    if src == dest then return true end
    if not BKPlanner.fitsLive(dest, item) then return false end
    if src then
        pcall(function() src:Remove(item) end)
        pcall(sendRemoveItemFromContainer, src, item)
    end
    pcall(function() dest:AddItem(item) end)
    pcall(sendAddItemToContainer, dest, item)
    if m(item, "getContainer") ~= dest then
        if src then pcall(function() src:AddItem(item) end) end
        return false
    end
    return true
end

local function plannerScan(zone)
    local scan = BKZoneScan.scanBase(zone)
    BKPlaces.infer(scan)
    BKLoot.annotate(scan)
    BKSections.annotate(scan)
    BKPlanner.indexContents(scan)
    return scan
end

-- Back to storage through the normal rules (areas, sections, seasons); false when nothing has room.
local function putAway(scan, item, from)
    local class = BKItemClass.classify(item)
    local c = BKPlanner.bestDestination(scan, class, true, item, from, from.container, nil, true)
    if c == nil then return false end
    return moveTo(item, c.container)
end

-- Appliances -------------------------------------------------------------------------------------------------------

local function applianceKey(c) return string.format("%s@%d,%d,%d", c.ctype, c.x, c.y, c.z) end

local function findAppliances(scan)
    local washer, dryer = nil, nil
    for _, c in ipairs(scan.containers) do
        if not c.personal and not c.locked then
            local obj = c.obj
            if c.ctype == "clothingwasher" and washer == nil and instanceof(obj, "IsoClothingWasher") then
                washer = c
            elseif (c.ctype == "clothingdryer" or c.ctype == "clothingdryerbasic") and dryer == nil
                    and instanceof(obj, "IsoClothingDryer") then
                dryer = c
            end
        end
    end
    return washer, dryer
end

local function powered(c) return m(c.container, "isPowered") == true end
local function running(c) return m(c.obj, "isActivated") == true end
local function hasWater(c) return (tonumber(m(c.obj, "getFluidAmount")) or 0) > 0 end
local function isEmpty(c)
    local items = m(c.container, "getItems")
    return items == nil or items:size() == 0
end

local function setRunning(c, on, kind)
    pcall(function() c.obj:setActivated(on) end)
    pcall(function()
        local change = kind == "washer" and IsoObjectChange.WASHER_STATE or IsoObjectChange.DRYER_STATE
        c.obj:sendObjectChange(change)
    end)
end

-- The tracked items still inside this appliance.
local function loadItems(c, load)
    local out = {}
    local items = m(c.container, "getItems")
    if items == nil then return out end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and load.ids[tostring(m(it, "getID"))] then table.insert(out, it) end
    end
    return out
end

local function usableWasher(c) return c ~= nil and powered(c) and hasWater(c) end
local function usableDryer(c) return c ~= nil and powered(c) end

-- Steps ------------------------------------------------------------------------------------------------------------

local function eachSourceItem(scan, fn)
    for _, c in ipairs(scan.containers) do
        if not c.personal and not c.locked and not c.noDest and not BKLaundry.SKIP_SOURCE[c.ctype] then
            local items = m(c.container, "getItems")
            if items then
                -- copy first: the callback may replace items in this container
                local list = {}
                for i = 0, items:size() - 1 do table.insert(list, items:get(i)) end
                for _, it in ipairs(list) do
                    if fn(it, c) == false then return end
                end
            end
        end
    end
end

local function cleanBandages(zone, scan, water, report)
    local n = 0
    eachSourceItem(scan, function(item, c)
        if n >= BKLaundry.BANDAGES_PER_TICK then return false end
        local after = dirtyBandage(item)
        if after then
            if not takeWater(water, BKLaundry.BANDAGE_WATER) then report.noWater = true; return false end
            local fav = m(item, "isFavorite") == true
            local cont = c.container
            pcall(function() cont:Remove(item) end)
            pcall(sendRemoveItemFromContainer, cont, item)
            local new = safe(function() return cont:AddItem(after) end)
            if new then
                if fav then pcall(function() new:setFavorite(true) end) end
                pcall(sendAddItemToContainer, cont, new)
                n = n + 1
            else
                pcall(function() cont:AddItem(item) end) -- put the dirty one back rather than lose it
            end
        end
    end)
    report.bandages = n
end

-- vanilla ISWashClothing:complete with noSoap = true
local function handWash(item)
    local parts = coveredParts(item)
    if parts then
        for i = 0, parts:size() - 1 do
            local p = parts:get(i)
            pcall(function() item:setBlood(p, 0) end)
            pcall(function() item:setDirt(p, 0) end)
        end
    end
    pcall(function() item:setWetness(100) end)
    pcall(function() item:setDirtiness(0) end)
    pcall(function() item:setBloodLevel(0) end)
    pcall(syncItemFields, getSpecificPlayer(0), item)
end

local function requiredWater(item)
    if ISWashClothing and ISWashClothing.GetRequiredWater then
        local v = safe(ISWashClothing.GetRequiredWater, item)
        if tonumber(v) then return tonumber(v) end
    end
    return 4 + grime(item)
end

local function handWashClothes(zone, scan, water, report)
    local n = 0
    eachSourceItem(scan, function(item, c)
        if n >= BKLaundry.HANDWASH_PER_TICK then return false end
        if dirtyClothes(item) then
            if not takeWater(water, requiredWater(item)) then report.noWater = true; return false end
            handWash(item)
            n = n + 1
        end
    end)
    report.handwashed = n
end

local function loadWasher(zone, scan, washer, d, report)
    local ids, n = {}, 0
    eachSourceItem(scan, function(item, c)
        if dirtyClothes(item) and m(washer.container, "isItemAllowed", item) ~= false then
            if moveTo(item, washer.container) then
                ids[tostring(m(item, "getID"))] = true
                n = n + 1
            end
        end
    end)
    if n > 0 then
        setRunning(washer, true, "washer")
        d.loads[applianceKey(washer)] = { kind = "washer", ids = ids, at = worldHours(), zone = zone.id }
    end
    report.loaded = n
end

-- Washer finished (off, or the whole load clean for MIN_CYCLE_HOURS): to the dryer, else back to storage wet.
local function unloadWasher(zone, scan, washer, dryer, d, report)
    local key = applianceKey(washer)
    local load = d.loads[key]
    local items = loadItems(washer, load)
    if #items == 0 then d.loads[key] = nil; return end
    local age = worldHours() - (load.at or 0)
    local allClean = true
    for _, it in ipairs(items) do if grime(it) > 0 then allClean = false end end
    if running(washer) then
        if not ((allClean and age >= BKLaundry.MIN_CYCLE_HOURS) or age >= BKLaundry.STUCK_HOURS) then return end
        setRunning(washer, false, "washer")
    end
    local toDryer = usableDryer(dryer) and not running(dryer) and d.loads[applianceKey(dryer)] == nil
    local dryIds, moved = {}, 0
    for _, it in ipairs(items) do
        local ok = false
        if toDryer and moveTo(it, dryer.container) then
            dryIds[tostring(m(it, "getID"))] = true
            ok = true
        elseif not toDryer then
            ok = putAway(scan, it, washer)
        end
        if ok then moved = moved + 1 end
    end
    if toDryer and moved > 0 then
        setRunning(dryer, true, "dryer")
        d.loads[applianceKey(dryer)] = { kind = "dryer", ids = dryIds, at = worldHours(), zone = zone.id }
    end
    -- whatever did not move stays tracked and is retried next tick
    if #loadItems(washer, load) == 0 then d.loads[key] = nil end
    report.washed = moved
    report.toDryer = toDryer
end

local function unloadDryer(zone, scan, dryer, d, report)
    local key = applianceKey(dryer)
    local load = d.loads[key]
    local items = loadItems(dryer, load)
    if #items == 0 then d.loads[key] = nil; return end
    local age = worldHours() - (load.at or 0)
    local allDry = true
    for _, it in ipairs(items) do if wet(it) then allDry = false end end
    if running(dryer) then
        if not ((allDry and age >= BKLaundry.MIN_CYCLE_HOURS) or age >= BKLaundry.STUCK_HOURS) then return end
        setRunning(dryer, false, "dryer")
    end
    local moved = 0
    for _, it in ipairs(items) do
        if putAway(scan, it, dryer) then moved = moved + 1 end
    end
    if #loadItems(dryer, load) == 0 then d.loads[key] = nil end
    report.dried = moved
end

function BKLaundry.runZone(zone, why)
    -- v0.19.0: laundry changes containers directly in this Lua state; on a multiplayer client that would desync
    if isClient() then return end
    local d = store()
    local scan = plannerScan(zone)
    if (scan.missingSquares or 0) > 0 then return end
    local water = waterSources(zone)
    local report = {}
    local washer, dryer = findAppliances(scan)

    cleanBandages(zone, scan, water, report)

    if dryer and d.loads[applianceKey(dryer)] then unloadDryer(zone, scan, dryer, d, report) end
    if washer and d.loads[applianceKey(washer)] then unloadWasher(zone, scan, washer, dryer, d, report) end
    if usableWasher(washer) then
        if not running(washer) and isEmpty(washer) and d.loads[applianceKey(washer)] == nil then
            loadWasher(zone, scan, washer, d, report)
        end
    elseif not (washer and d.loads[applianceKey(washer)]) then
        handWashClothes(zone, scan, water, report)
    end

    local parts = {}
    if (report.bandages or 0) > 0 then table.insert(parts, report.bandages .. " bandage(s) cleaned") end
    if (report.loaded or 0) > 0 then table.insert(parts, report.loaded .. " item(s) into the washer, washer on") end
    if (report.washed or 0) > 0 then
        table.insert(parts, report.washed .. (report.toDryer and " washed item(s) into the dryer, dryer on" or " washed item(s) back to storage (wet, no dryer)"))
    end
    if (report.dried or 0) > 0 then table.insert(parts, report.dried .. " dry item(s) back to storage") end
    if (report.handwashed or 0) > 0 then table.insert(parts, report.handwashed .. " item(s) hand-washed (wet)") end
    if report.noWater then table.insert(parts, "out of water") end
    if #parts > 0 or why == "manual" then
        BKLog.info(string.format("laundry (%s) zone %s: %s; washer %s, dryer %s, %d water source(s)", why, tostring(zone.id),
            #parts > 0 and table.concat(parts, ", ") or "nothing to do",
            washer and ((usableWasher(washer) and "ready" or "unpowered/no water") .. (running(washer) and ", running" or "")) or "none",
            dryer and ((usableDryer(dryer) and "ready" or "unpowered") .. (running(dryer) and ", running" or "")) or "none",
            #water))
    end
    return report
end

local function playerNear(zone)
    local p = getSpecificPlayer(0)
    if p == nil or m(p, "isAsleep") == true then return false end
    local x, y, n = p:getX(), p:getY(), BKLaundry.NEAR_TILES
    return x >= zone.x1 - n and x < zone.x2 + n and y >= zone.y1 - n and y < zone.y2 + n
end

function BKLaundry.tick()
    if isClient() then return end -- single player only (see runZone)
    if not BKLaundry.enabled() then return end
    for _, zone in ipairs(BKZones.list()) do
        -- a load already in an appliance is finished even when the player has walked off
        local busy = false
        for _, load in pairs(store().loads) do if load.zone == zone.id then busy = true end end
        if playerNear(zone) or busy then
            local ok, err = pcall(BKLaundry.runZone, zone, "tick")
            if not ok then BKLog.warn("laundry failed in zone " .. tostring(zone.id) .. ": " .. tostring(err)) end
        end
    end
end

Events.EveryTenMinutes.Add(BKLaundry.tick)

table.insert(BKContextMenu.zoneActions, {
    label = function() return BKLaundry.enabled() and "Laundry: on (turn off)" or "Laundry: off (turn on)" end,
    fn = function() local d = store(); d.off = not (d.off == true); BKLog.info("laundry " .. (d.off and "off" or "on")) end,
})
table.insert(BKContextMenu.zoneActions, {
    label = "Do laundry now (console)",
    fn = function(player, zone)
        local ok, err = pcall(BKLaundry.runZone, zone, "manual")
        if not ok then BKLog.warn("laundry failed: " .. tostring(err)) end
    end,
})

return BKLaundry
