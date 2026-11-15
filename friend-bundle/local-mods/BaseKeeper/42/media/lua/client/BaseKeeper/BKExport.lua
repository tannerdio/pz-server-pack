-- Base Keeper: base inventory export. Writes everything inside the base outline to a text file the player (or a
-- planning session outside the game) can read: Zomboid/Lua/BaseKeeper_base.txt.
--   outline = every zone + every loot area no zone covers (basement areas; personal areas included, marked)
--   what    = every container (bins too, marked "not stock"), bags inside containers (BAG_DEPTH levels), every floor
--             item and floor bag, every vehicle parked on an outline tile (each part with an item container, plus the
--             gas tank), water sources, generators; then the player's own inventory; then a per-type summary and totals.
-- Items are grouped per container by type + state (fresh/stale/rotten, rots in N days, uses, litres, rounds,
-- condition, favourite, wishlist). Written from the Base Keeper menu ("Export base inventory (file)") and every game
-- hour while the player is near the base (BKExport.AUTO). A partly unloaded base is never auto-written over a good
-- file; the manual export writes anyway and says so in the header. Nothing here moves anything.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlanner"
require "BaseKeeper/BKStatus"
require "BaseKeeper/BKWishlist"
require "BaseKeeper/BKSections"
require "BaseKeeper/BKLayout"
require "BaseKeeper/UI/BKContextMenu"

BKExport = BKExport or {}

BKExport.FILE = "BaseKeeper_base.txt" -- lands in <user>/Zomboid/Lua/
BKExport.BAG_DEPTH = 3                -- bags inside bags inside containers
BKExport.AUTO = true                  -- rewrite every game hour while near the base
BKExport.lastAt = nil                 -- world hours of the last successful write
BKExport.lastStats = nil

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

-- Java methods only some item classes have: look the method up first, a missing one would print a stack trace.
local function call(obj, method, ...)
    if obj == nil then return nil end
    -- indexing a Java object of a class not exposed to Lua (VehicleParts) throws, so the lookup is guarded too
    local okI, fn = pcall(function() return obj[method] end)
    if not okI or type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, obj, ...)
    if ok then return res end
    return nil
end

local function num(v) return tonumber(v) end
local function f1(n) return string.format("%.1f", n) end
local function worldHours() return num(safe(function() return getGameTime():getWorldAgeHours() end)) or 0 end
local function player() return getSpecificPlayer(0) end

-- Items --------------------------------------------------------------------------------------------------------

-- One item -> { name, fullType, class, sure, state (string), hunger, litres, fluid, rounds, calibre, rotten, stale }
local function describe(item, p, worldObj)
    local d = {
        fullType = tostring(call(item, "getFullType") or "?"),
        name = tostring(call(item, "getDisplayName") or "?"),
    }
    local class, _, sure, group = BKItemClass.classify(item)
    d.class, d.sure, d.group = class, sure, group or "other"
    local parts = {}
    if call(item, "IsFood") == true then
        local h = num(call(item, "getHungChange"))
        if h and h < 0 then d.hunger = -h * 100; table.insert(parts, "hunger " .. math.floor(d.hunger + 0.5)) end
        local t = num(call(item, "getThirstChange"))
        if t and t < 0 then table.insert(parts, "thirst " .. math.floor(-t * 100 + 0.5)) end
        if call(item, "isRotten") == true then
            d.rotten = true
            table.insert(parts, "ROTTEN")
        else
            local offMax = num(call(item, "getOffAgeMax")) or 0
            if offMax > 0 and offMax < 1000000 then
                if call(item, "isFrozen") == true then
                    table.insert(parts, "frozen")
                else
                    if call(item, "isFresh") == false then d.stale = true; table.insert(parts, "stale") end
                    local left = offMax - (num(call(item, "getAge")) or 0)
                    table.insert(parts, "rots in " .. f1(math.max(0, left)) .. "d")
                end
            end
        end
        if call(item, "isCooked") == true then table.insert(parts, "cooked") end
    end
    if instanceof(item, "DrainableComboItem") then
        local cur, max = num(call(item, "getCurrentUses")), num(call(item, "getMaxUses"))
        if cur and max then table.insert(parts, string.format("uses %d/%d", cur, max)) end
    end
    local fc = call(item, "getFluidContainer")
    -- v0.10.3: a fluid item lying on the floor (gas can, water jug) keeps its fluid on the IsoWorldInventoryObject,
    -- so the item's own getFluidContainer is nil there and 3 floor gas cans were counted with no litres.
    if fc == nil and worldObj ~= nil then fc = call(worldObj, "getFluidContainer") end
    if fc ~= nil then
        local amount = num(call(fc, "getAmount")) or 0
        local cap = num(call(fc, "getCapacity")) or 0
        if amount > 0 then
            local fluid = call(fc, "getPrimaryFluid")
            local fname = fluid and tostring(call(fluid, "getFluidTypeString") or "fluid") or "fluid"
            d.litres, d.fluid = amount, fname
            table.insert(parts, string.format("%s/%s L %s", f1(amount), f1(cap), fname))
        else
            table.insert(parts, "empty")
        end
    end
    local maxAmmo = num(call(item, "getMaxAmmo")) or 0
    if maxAmmo > 0 then
        local rounds = num(call(item, "getCurrentAmmoCount")) or 0
        local ammoType = call(item, "getAmmoType")
        local calibre = ammoType and BKStatus.ammoKey(BKStatus.ammoLabel(ammoType, item)) or nil
        d.rounds, d.calibre = rounds, calibre
        table.insert(parts, string.format("rounds %d/%d%s", rounds, maxAmmo, calibre and (" " .. calibre) or ""))
    elseif class == "ammo" then
        -- loose round, box or carton (same conservative counts as the status window)
        local lname = string.lower(d.name)
        local n = 1
        if string.find(lname, "^carton of ") then n = BKStatus.CARTON_ROUNDS
        elseif string.find(lname, "^box of ") then n = BKStatus.BOX_ROUNDS end
        d.rounds, d.calibre = n, BKStatus.ammoKey(d.name)
    end
    local cmax = num(call(item, "getConditionMax")) or 0
    local cond = num(call(item, "getCondition"))
    if cmax > 0 and cond and cond < cmax then
        table.insert(parts, string.format("cond %d/%d", cond, cmax))
        if cond <= cmax / 2 then d.worn = true end
    end
    if call(item, "isBroken") == true then d.broken = true; table.insert(parts, "BROKEN") end
    if call(item, "isFavorite") == true then table.insert(parts, "favourite") end
    if BKWishlist and BKWishlist.status then
        local okW, wanted, s = pcall(BKWishlist.wanted, item, p)
        if okW and s then
            if wanted then
                table.insert(parts, string.format("WISHLIST short (have %d of %d)", s.have, s.want))
            elseif s.lit then
                table.insert(parts, "wishlist: unread, still useful")
            end
        elseif class == "literature" then
            local read = safe(function() return ISInventoryPane.isLiteratureRead(nil, p, item) end)
            if read == true then table.insert(parts, "read") end
        end
    end
    d.state = table.concat(parts, ", ")
    return d
end

-- Grouped lines for one list of items: "  3x Cabbage (Base.Cabbage) [food_perishable] hunger 12, rots in 4.2d".
-- Bags are walked up to `depth` levels, their contents indented under the bag line. tally(d, n) feeds the summary.
local function writeItems(lines, items, indent, p, depth, tally)
    if items == nil then return 0 end
    local groups, order = {}, {}
    local bags = {}
    local total = 0
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            total = total + 1
            local d = describe(item, p)
            local key = d.fullType .. "|" .. d.state
            if groups[key] == nil then
                groups[key] = { d = d, n = 0 }
                table.insert(order, key)
            end
            groups[key].n = groups[key].n + 1
            if tally then tally(d, 1) end
            local inv = safe(function()
                if item.getInventory and item:getCategory() == "Container" then return item:getInventory() end
                return nil
            end)
            if inv and depth > 0 then table.insert(bags, { item = item, inv = inv, d = d }) end
        end
    end
    table.sort(order, function(a, b)
        local ga, gb = groups[a], groups[b]
        if ga.d.class ~= gb.d.class then return ga.d.class < gb.d.class end
        if ga.d.name ~= gb.d.name then return ga.d.name < gb.d.name end
        return a < b
    end)
    for _, key in ipairs(order) do
        local g = groups[key]
        table.insert(lines, string.format("%s%dx %s (%s) [%s/%s%s]%s", indent, g.n, g.d.name, g.d.fullType, g.d.class,
            tostring(g.d.group), g.d.sure and "" or "?", g.d.state ~= "" and ("  " .. g.d.state) or ""))
    end
    for _, b in ipairs(bags) do
        local inner = safe(function() return b.inv:getItems() end)
        local n = inner and inner:size() or 0
        if n > 0 then
            table.insert(lines, string.format("%s  in %s (%s), %d item(s):", indent, b.d.name, b.d.fullType, n))
            writeItems(lines, inner, indent .. "    ", p, depth - 1, tally)
        end
    end
    return total
end

-- Where ---------------------------------------------------------------------------------------------------------

local function areaTag(x, y, z)
    local area = BKLoot.at(x, y, z)
    if area == nil then return "" end
    if BKLoot.isPersonal(area) then return string.format("  area %d [PERSONAL, hands off]", area.id) end
    return string.format("  area %d [%s]", area.id, BKLoot.labels(area))
end

local function containerHeader(c)
    local flags = {}
    if BKPlanner.COLD[c.ctype] then table.insert(flags, c.powered and "powered" or "NO POWER") end
    if c.locked then table.insert(flags, "locked") end
    if BKStatus.NOT_STOCK[c.ctype] then table.insert(flags, "not stock") end
    if c.personal then table.insert(flags, "personal") end
    local cap = num(call(c.container, "getCapacity")) or 0
    local weight = num(call(c.container, "getContentsWeight")) or 0
    local items = safe(function() return c.container:getItems() end)
    local n = items and items:size() or 0
    return string.format("== %s%s @%d,%d,%d  zone %s%s  %d item(s) %s/%d kg%s", c.ctype,
        c.room and (" (" .. c.room .. ")") or "", c.x, c.y, c.z, tostring(c.zoneId or "-"), areaTag(c.x, c.y, c.z),
        n, f1(weight), math.floor(cap), #flags > 0 and ("  " .. table.concat(flags, ", ")) or "")
end

-- Every rectangle that is part of the base: zones, then loot areas no zone covers (any tag, personal too).
local function outline()
    local zones = BKZones.list()
    local rects = {}
    for _, z in ipairs(zones) do table.insert(rects, { rect = z, kind = "zone" }) end
    for _, area in ipairs(BKLoot.list()) do
        local covered = false
        for _, z in ipairs(zones) do
            if BKZones.overlaps(z, area.x1, area.y1, area.x2, area.y2, area.z) then covered = true end
        end
        if not covered then
            table.insert(rects, { kind = "area", area = area,
                rect = { id = "area" .. tostring(area.id), x1 = area.x1, y1 = area.y1, x2 = area.x2, y2 = area.y2, z = area.z } })
        end
    end
    return rects
end

local function inOutline(rects, x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    for _, r in ipairs(rects) do
        if BKZones.contains(r.rect, x, y, z) then return r end
    end
    return nil
end

-- Vehicles parked on an outline tile: every part with an item container, plus fluid parts (gas tank).
-- `getCell():getVehicles()` is a java.util.Set the game's Lua cannot index (first live run: "Object tried to call nil"),
-- so vehicles are found tile by tile through `IsoGridSquare:getVehicleContainer()`, the same call BKZoneScan uses.
local function writeVehicles(lines, rects, p, tally)
    local cell = getCell()
    local seen = {}
    local found = {}
    for _, r in ipairs(rects) do
        for x = r.rect.x1, r.rect.x2 - 1 do
            for y = r.rect.y1, r.rect.y2 - 1 do
                local sq = cell:getGridSquare(x, y, r.rect.z)
                local v = sq and safe(function() return sq:getVehicleContainer() end) or nil
                if v then
                    local id = tostring(call(v, "getId") or call(v, "getSqlId") or tostring(v))
                    if not seen[id] then
                        seen[id] = true
                        table.insert(found, { v = v, r = r })
                    end
                end
            end
        end
    end
    local count = 0
    for _, hit in ipairs(found) do
        local v, r = hit.v, hit.r
        local x, y, z = num(call(v, "getX")) or 0, num(call(v, "getY")) or 0, num(call(v, "getZ")) or 0
        do
            count = count + 1
            local script = tostring(call(v, "getScriptName") or "?")
            local vs = call(v, "getScript")
            local vname = vs and tostring(call(vs, "getName") or script) or script
            -- `getParts()` returns a VehicleParts object that is not exposed to Lua (second live run: "attempted
            -- index ... of non-table"), so every part call goes through the vehicle itself, as vanilla Lua does.
            local owner = v
            local extra = {}
            local engine = num(call(v, "getEngineCondition"))
            if engine then table.insert(extra, string.format("engine %d%%", math.floor(engine))) end
            local batteryPart = call(v, "getPartById", "Battery")
            local batteryItem = batteryPart and call(batteryPart, "getInventoryItem")
            local charge = batteryItem and num(call(batteryItem, "getCurrentUsesFloat"))
            if charge then table.insert(extra, string.format("battery %d%%", math.floor(charge * 100 + 0.5))) end
            if call(v, "isEngineRunning") == true then table.insert(extra, "RUNNING") end
            table.insert(lines, string.format("== VEHICLE %s (%s) @%d,%d,%d  %s %s%s", vname, script, math.floor(x),
                math.floor(y), math.floor(z), r.kind, tostring(r.rect.id), #extra > 0 and ("  " .. table.concat(extra, ", ")) or ""))
            local nParts = num(call(owner, "getPartCount")) or 0
            for pi = 0, nParts - 1 do
                local part = call(owner, "getPartByIndex", pi)
                if part and call(part, "isContainer") == true then
                    local id = tostring(call(part, "getId") or "?")
                    local cont = call(part, "getItemContainer")
                    if cont ~= nil then
                        local items = safe(function() return cont:getItems() end)
                        local n = items and items:size() or 0
                        local cap = num(call(cont, "getCapacity")) or 0
                        local weight = num(call(cont, "getContentsWeight")) or 0
                        table.insert(lines, string.format("  -- %s: %d item(s) %s/%d kg", id, n, f1(weight), math.floor(cap)))
                        if n > 0 then writeItems(lines, items, "    ", p, BKExport.BAG_DEPTH, tally) end
                    else
                        local ctype = tostring(call(part, "getContainerContentType") or "?")
                        local amount = num(call(part, "getContainerContentAmount")) or 0
                        local cap = num(call(part, "getContainerCapacity")) or 0
                        table.insert(lines, string.format("  -- %s: %s %s/%d", id, ctype, f1(amount), math.floor(cap)))
                        if tally and string.lower(ctype) == "gasoline" then tally({ litres = amount, fluid = "Petrol", vehicle = true }, 1) end
                    end
                end
            end
        end
    end
    return count
end

local function writeGenerators(lines, scan)
    local n = 0
    for _, f in ipairs(scan.fixtures) do
        if f.kind == "generator" then
            local sq = getCell():getGridSquare(f.x, f.y, f.z)
            local objs = sq and sq:getObjects() or nil
            local nObjs = objs and objs:size() or 0
            for i = 0, nObjs - 1 do
                local obj = objs:get(i)
                if instanceof(obj, "IsoGenerator") then
                    n = n + 1
                    -- v0.10.3: B42 getFuel() is litres, not percent (a 71% generator printed "7%"); use
                    -- getFuelPercentage and show the litres against getMaxFuel.
                    local fuel = num(call(obj, "getFuel")) or 0
                    local maxFuel = num(call(obj, "getMaxFuel"))
                    local pct = num(call(obj, "getFuelPercentage"))
                    if pct == nil and maxFuel and maxFuel > 0 then pct = fuel / maxFuel * 100 end
                    table.insert(lines, string.format("  generator @%d,%d,%d  fuel %s%% (%s/%s L)  condition %d%%  %s", f.x, f.y, f.z,
                        pct and tostring(math.floor(pct + 0.5)) or "?", f1(fuel), maxFuel and f1(maxFuel) or "?",
                        math.floor(num(call(obj, "getCondition")) or 0),
                        call(obj, "isActivated") == true and "RUNNING" or "off"))
                end
            end
        end
    end
    return n
end

local function writeWater(lines, rect, tally)
    if not (BKCook and BKCook.scanWater) then return 0 end
    local waters = safe(BKCook.scanWater, rect) or {}
    for _, w in ipairs(waters) do
        table.insert(lines, string.format("  water source @%d,%d  %s L%s", w.x, w.y, f1(w.amount), w.tainted and " (tainted, boil)" or ""))
        if tally then tally({ litres = w.amount, fluid = w.tainted and "TaintedWater" or "Water", source = true }, 1) end
    end
    return #waters
end

-- Animals standing on an outline tile (chickens in the run, cows in the pasture) and hutches with their eggs.
-- Animals are not items: the sorter never touches them, hutches have no container, this is information only.
local function writeAnimals(lines, rect)
    local cell = getCell()
    local n = 0
    local seenHutch = {} -- a hutch spans several tiles and is listed once
    for x = rect.x1, rect.x2 - 1 do
        for y = rect.y1, rect.y2 - 1 do
            local sq = cell:getGridSquare(x, y, rect.z)
            if sq then
                local movers = safe(function() return sq:getMovingObjects() end)
                local nm = movers and movers:size() or 0
                for i = 0, nm - 1 do
                    local a = movers:get(i)
                    if instanceof(a, "IsoAnimal") then
                        n = n + 1
                        local parts = {}
                        local name = call(a, "getCustomName")
                        if name and name ~= "" then table.insert(parts, '"' .. tostring(name) .. '"') end
                        table.insert(parts, call(a, "isFemale") == true and "female" or "male")
                        if call(a, "isBaby") == true then table.insert(parts, "baby") end
                        local ageText = call(a, "getAgeText", false, 10)
                        if ageText and ageText ~= "" then table.insert(parts, "age " .. tostring(ageText)) end
                        local hunger, thirst, health = num(call(a, "getHunger")), num(call(a, "getThirst")), num(call(a, "getHealth"))
                        if hunger then table.insert(parts, "hunger " .. f1(hunger)) end
                        if thirst then table.insert(parts, "thirst " .. f1(thirst)) end
                        if health then table.insert(parts, "health " .. f1(health)) end
                        local milk = num(call(a, "getMilkQuantity")) or 0
                        if milk > 0 then table.insert(parts, "milk " .. f1(milk) .. " L") end
                        local breed = call(a, "getBreed")
                        local breedName = breed and tostring(call(breed, "getName") or "") or ""
                        table.insert(lines, string.format("  %s%s @%d,%d,%d  %s", tostring(call(a, "getAnimalType") or "animal"),
                            breedName ~= "" and (" (" .. breedName .. ")") or "", x, y, rect.z, table.concat(parts, ", ")))
                    end
                end
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local obj = objs:get(i)
                    if instanceof(obj, "IsoHutch") and not seenHutch[tostring(obj)] then
                        seenHutch[tostring(obj)] = true
                        local eggs = call(obj, "getEggs")
                        local nEggs = eggs and num(safe(function() return eggs:size() end)) or 0
                        local inside = call(obj, "getAnimalInside")
                        local nIn = inside and num(safe(function() return inside:size() end)) or 0
                        table.insert(lines, string.format("  hutch @%d,%d,%d  %d egg(s), %d animal(s) inside", x, y, rect.z, nEggs, nIn))
                    end
                end
            end
        end
    end
    return n
end

-- Player ---------------------------------------------------------------------------------------------------------

local function skillLine(p)
    local parts = {}
    local list = PerkFactory and PerkFactory.PerkList
    local n = list and num(safe(function() return list:size() end)) or 0
    for i = 0, n - 1 do
        local perk = safe(function() return list:get(i) end)
        local lvl = perk and num(call(p, "getPerkLevel", perk)) or 0
        if perk and lvl > 0 then
            table.insert(parts, tostring(call(perk, "getName") or call(perk, "getId") or "?") .. " " .. lvl)
        end
    end
    return table.concat(parts, ", ")
end

local function timeLine()
    local gt = getGameTime()
    local day = math.floor(worldHours() / 24) + 1
    local date = string.format("%d/%d/%d %02d:00", (num(call(gt, "getMonth")) or 0) + 1, (num(call(gt, "getDay")) or 0) + 1,
        num(call(gt, "getYear")) or 0, math.floor(num(call(gt, "getHour")) or 0))
    local temp = num(safe(function() return getClimateManager():getTemperature() end))
    return string.format("world day %d, %s%s", day, date, temp and string.format(", %s C outside", f1(temp)) or "")
end

-- Build ------------------------------------------------------------------------------------------------------------

-- Returns lines, stats. stats.partial = a rectangle had unloaded squares.
function BKExport.build()
    local p = player()
    local rects = outline()
    local lines = {}
    local stats = { items = 0, containers = 0, floor = 0, vehicles = 0, animals = 0, partial = false, rects = #rects }
    -- summary tallies (stock only: bins, vehicles' fluid parts and water sources are kept apart)
    local byType, typeOrder = {}, {}
    local totals = { hunger = 0, rotten = 0, water = 0, petrol = 0, petrolVehicles = 0, ammo = {} }
    local function tally(d, n)
        if d.fullType then
            local t = byType[d.fullType]
            if t == nil then
                t = { n = 0, name = d.name, class = d.class, group = d.group, sure = d.sure, hunger = 0, rotten = 0, stale = 0, litres = 0, fluid = nil, rounds = 0, calibre = d.calibre }
                byType[d.fullType] = t
                table.insert(typeOrder, d.fullType)
            end
            t.n = t.n + n
            if d.hunger and not d.rotten then t.hunger = t.hunger + d.hunger; totals.hunger = totals.hunger + d.hunger end
            if d.rotten then t.rotten = t.rotten + 1; totals.rotten = totals.rotten + 1 end
            if d.stale then t.stale = t.stale + 1 end
            if d.worn then t.worn = (t.worn or 0) + 1 end
            if d.broken then t.broken = (t.broken or 0) + 1 end
            if d.litres then t.litres = t.litres + d.litres; t.fluid = d.fluid end
            if d.rounds and d.calibre then
                t.rounds = t.rounds + d.rounds
                totals.ammo[d.calibre] = (totals.ammo[d.calibre] or 0) + d.rounds
            end
        end
        if d.litres and d.fluid then
            if d.fluid == "Water" or d.fluid == "TaintedWater" then totals.water = totals.water + d.litres end
            if d.fluid == "Petrol" then
                if d.vehicle then totals.petrolVehicles = totals.petrolVehicles + d.litres
                else totals.petrol = totals.petrol + d.litres end
            end
        end
    end

    table.insert(lines, "BASE KEEPER BASE INVENTORY")
    table.insert(lines, timeLine())
    if p then
        table.insert(lines, string.format("player @%d,%d,%d  skills: %s", math.floor(p:getX()), math.floor(p:getY()),
            math.floor(p:getZ()), skillLine(p)))
        -- v0.10.0: body weight and the calorie pool the meal prep is sized by
        local okN, nutLine = pcall(function()
            local n = p:getNutrition()
            return string.format("nutrition: weight %.1f kg, calorie pool %d, carbs %d, fat %d, protein %d%s",
                n:getWeight(), math.floor(n:getCalories()), math.floor(n:getCarbohydrates()), math.floor(n:getLipids()),
                math.floor(n:getProteins()), n:isIncWeight() and " (gaining)" or (n:isDecWeight() and " (losing)" or ""))
        end)
        if okN and nutLine then table.insert(lines, nutLine) end
    end
    for _, r in ipairs(rects) do
        if r.kind == "zone" then
            table.insert(lines, "zone " .. BKZones.describe(r.rect))
        else
            table.insert(lines, "loot area (no zone over it) " .. BKLoot.describe(r.area))
        end
    end
    for _, area in ipairs(BKLoot.list()) do
        table.insert(lines, "loot area " .. BKLoot.describe(area))
    end
    table.insert(lines, "")
    table.insert(lines, "Legend: Nx name (type) [class] state. class? = guessed. kg = contents/capacity. Bins are not stock.")

    local body, floorLines, vehicleLines, fixtureLines, animalLines, water = {}, {}, {}, {}, {}, 0
    for _, r in ipairs(rects) do
        local ok, err = pcall(function()
            local scan = BKZoneScan.scan(r.rect)
            if (scan.missingSquares or 0) > 0 then stats.partial = true end
            table.insert(body, "")
            table.insert(body, string.format("#### %s %s: %d containers, %d floor items, %d unloaded squares", r.kind,
                tostring(r.rect.id), #scan.containers, #scan.floorItems, scan.missingSquares or 0))
            for _, c in ipairs(scan.containers) do
                stats.containers = stats.containers + 1
                table.insert(body, containerHeader(c))
                local items = safe(function() return c.container:getItems() end)
                local n = writeItems(body, items, "  ", p, BKExport.BAG_DEPTH, (not BKStatus.NOT_STOCK[c.ctype]) and tally or nil)
                stats.items = stats.items + n
            end
            for _, f in ipairs(scan.floorItems) do
                stats.floor = stats.floor + 1
                local d = describe(f.item, p, f.worldObj)
                tally(d, 1)
                local flags = {}
                if f.placed then table.insert(flags, "placed (never sorted)") end
                if f.personal then table.insert(flags, "personal") end
                table.insert(floorLines, string.format("  @%d,%d,%d %s (%s) [%s/%s%s]%s%s", f.x, f.y, f.z, d.name, d.fullType,
                    d.class, tostring(d.group), d.sure and "" or "?", d.state ~= "" and ("  " .. d.state) or "",
                    #flags > 0 and ("  " .. table.concat(flags, ", ")) or ""))
            end
            for _, b in ipairs(scan.floorBags) do
                local inner = safe(function() return b.inventory:getItems() end)
                local n = inner and inner:size() or 0
                if n > 0 then
                    table.insert(floorLines, string.format("  in floor bag %s @%d,%d,%d, %d item(s):",
                        tostring(call(b.item, "getDisplayName") or "?"), b.x, b.y, b.z, n))
                    stats.items = stats.items + writeItems(floorLines, inner, "    ", p, BKExport.BAG_DEPTH - 1, tally)
                end
            end
            writeGenerators(fixtureLines, scan)
            water = water + writeWater(fixtureLines, r.rect, tally)
            stats.animals = stats.animals + writeAnimals(animalLines, r.rect)
        end)
        if not ok then
            stats.partial = true
            table.insert(body, "!! scan failed for " .. tostring(r.rect.id) .. ": " .. tostring(err))
            BKLog.warn("export scan failed for " .. tostring(r.rect.id) .. ": " .. tostring(err))
        end
    end
    local okV, errV = pcall(function() stats.vehicles = writeVehicles(vehicleLines, rects, p, tally) end)
    if not okV then BKLog.warn("export vehicle scan failed: " .. tostring(errV)) end

    -- carried (not in the summary)
    local carried = {}
    if p then
        local inv = safe(function() return p:getInventory() end)
        local items = inv and safe(function() return inv:getItems() end)
        writeItems(carried, items, "  ", p, 4, nil)
    end

    -- summary by class, then fine group (v0.12.0), per type
    table.sort(typeOrder, function(a, b)
        local ta, tb = byType[a], byType[b]
        if ta.class ~= tb.class then return ta.class < tb.class end
        if tostring(ta.group) ~= tostring(tb.group) then return tostring(ta.group) < tostring(tb.group) end
        if ta.n ~= tb.n then return ta.n > tb.n end
        return ta.name < tb.name
    end)
    local summary = {}
    local lastClass, lastGroup = nil, nil
    for _, ft in ipairs(typeOrder) do
        local t = byType[ft]
        if t.class ~= lastClass or t.group ~= lastGroup then
            lastClass, lastGroup = t.class, t.group
            table.insert(summary, string.format("-- %s / %s (%s)", t.class, tostring(t.group), BKTaxonomy.label(t.group)))
        end
        local notes = {}
        if t.hunger > 0 then table.insert(notes, "hunger " .. math.floor(t.hunger + 0.5)) end
        if t.rotten > 0 then table.insert(notes, t.rotten .. " rotten") end
        if t.stale > 0 then table.insert(notes, t.stale .. " stale") end
        if (t.worn or 0) > 0 then table.insert(notes, t.worn .. " under half condition") end
        if (t.broken or 0) > 0 then table.insert(notes, t.broken .. " BROKEN") end
        if t.litres > 0 then table.insert(notes, f1(t.litres) .. " L " .. tostring(t.fluid)) end
        if t.rounds > 0 and t.calibre then table.insert(notes, t.rounds .. " rounds " .. t.calibre) end
        table.insert(summary, string.format("%5d  %s (%s)%s%s", t.n, t.name, ft, t.sure and "" or " ?",
            #notes > 0 and ("  " .. table.concat(notes, ", ")) or ""))
    end
    local ammoKeys = {}
    for k in pairs(totals.ammo) do table.insert(ammoKeys, k) end
    table.sort(ammoKeys)
    local ammoParts = {}
    for _, k in ipairs(ammoKeys) do table.insert(ammoParts, string.format("%s %d", k, totals.ammo[k])) end

    table.insert(lines, "")
    table.insert(lines, "#### TOTALS (stock in containers, on the floor and in vehicles; bins excluded)")
    table.insert(lines, string.format("  %d items in %d containers, %d on the floor, %d vehicle(s), %d water source(s), %d animal(s)",
        stats.items, stats.containers, stats.floor, stats.vehicles, water, stats.animals))
    table.insert(lines, string.format("  food: hunger %d total (about %s days at 100 a day), %d rotten", math.floor(totals.hunger + 0.5),
        f1(totals.hunger / 100), totals.rotten))
    table.insert(lines, string.format("  water: %s L (bottles + sources, tainted included)", f1(totals.water)))
    table.insert(lines, string.format("  petrol: %s L in cans/containers, %s L in vehicle tanks", f1(totals.petrol), f1(totals.petrolVehicles)))
    table.insert(lines, "  ammo: " .. (#ammoParts > 0 and table.concat(ammoParts, ", ") or "none"))
    if stats.partial then
        table.insert(lines, "  !! a rectangle was partly unloaded or failed to scan: counts incomplete, export again from the base")
    end
    table.insert(lines, "")
    table.insert(lines, "#### SUMMARY BY TYPE (count  name (type) [notes])")
    for _, l in ipairs(summary) do table.insert(lines, l) end
    table.insert(lines, "")
    table.insert(lines, "#### CARRIED (player inventory, not counted above)")
    for _, l in ipairs(carried) do table.insert(lines, l) end
    table.insert(lines, "")
    table.insert(lines, "#### FLOOR (inbox) " .. stats.floor .. " item(s)")
    for _, l in ipairs(floorLines) do table.insert(lines, l) end
    table.insert(lines, "")
    table.insert(lines, "#### VEHICLES on the outline: " .. stats.vehicles)
    for _, l in ipairs(vehicleLines) do table.insert(lines, l) end
    table.insert(lines, "")
    table.insert(lines, "#### ANIMALS on the outline: " .. stats.animals .. " (never sorted; hutches listed with their eggs)")
    for _, l in ipairs(animalLines) do table.insert(lines, l) end
    table.insert(lines, "")
    -- v0.11.0 sections: touching storage containers per room, their profile, suggested and accepted role
    table.insert(lines, "#### SECTIONS (storage runs outside loot areas; role = accepted, suggested = keeper's proposal)")
    for _, zone in ipairs(BKZones.list()) do
        local okS, sections = pcall(BKSections.forZone, zone, 0)
        if okS and sections then
            table.insert(lines, string.format("-- zone %s: %d section(s)", tostring(zone.id), #sections))
            for _, sec in ipairs(sections) do table.insert(lines, "  " .. BKSections.describe(sec)) end
        end
    end
    table.insert(lines, "")
    -- v0.13.0 layout: what the Zone Theory planner would give every storage tile (roles already applied show in
    -- SECTIONS above; this block is the proposal, computed fresh, never applied by the export)
    table.insert(lines, "#### LAYOUT (Zone Theory proposal per storage tile; apply from the Sections menu)")
    for _, zone in ipairs(BKZones.list()) do
        local okL, plan = pcall(BKLayout.plan, zone)
        if okL and plan then
            table.insert(lines, "-- " .. plan.summary)
            for _, l in ipairs(plan.lines) do table.insert(lines, l) end
            if BKLayout.lastPlan then BKLayout.lastPlan[zone.id] = nil end -- a proposal for the file, not a pending plan
        else
            table.insert(lines, "-- zone " .. tostring(zone.id) .. ": layout failed: " .. tostring(plan))
        end
    end
    table.insert(lines, "")
    table.insert(lines, "#### FIXTURES")
    for _, l in ipairs(fixtureLines) do table.insert(lines, l) end
    table.insert(lines, "")
    table.insert(lines, "#### CONTAINERS")
    for _, l in ipairs(body) do table.insert(lines, l) end
    return lines, stats
end

-- Write --------------------------------------------------------------------------------------------------------------

function BKExport.write(why, force)
    if #BKZones.list() == 0 then
        if force then BKLog.info("export: no zone marked, nothing to export") end
        return false
    end
    local ok, lines, stats = pcall(BKExport.build)
    if not ok then BKLog.warn("export build failed: " .. tostring(lines)); return false end
    if stats.partial and not force then
        BKLog.dbg("export skipped (" .. tostring(why) .. "): base partly unloaded")
        return false
    end
    local w = safe(function() return getFileWriter(BKExport.FILE, true, false) end)
    if w == nil then BKLog.warn("export: cannot open Lua/" .. BKExport.FILE); return false end
    local okW, errW = pcall(function()
        for _, l in ipairs(lines) do w:write(l .. "\r\n") end
    end)
    pcall(function() w:close() end)
    if not okW then BKLog.warn("export write failed: " .. tostring(errW)); return false end
    BKExport.lastAt = worldHours()
    BKExport.lastStats = stats
    BKLog.info(string.format("export (%s): %d items, %d containers, %d floor, %d vehicle(s)%s -> Lua/%s", tostring(why),
        stats.items, stats.containers, stats.floor, stats.vehicles, stats.partial and " (PARTIAL)" or "", BKExport.FILE))
    return true
end

local function onExport(p)
    local ok = BKExport.write("manual", true)
    if p and HaloTextHelper then
        pcall(HaloTextHelper.addText, p, ok and ("Base inventory written to Lua/" .. BKExport.FILE) or "Base export failed, see console")
    end
end

local function onHour()
    if not BKExport.AUTO then return end
    if not (BKWishlist and BKWishlist.nearBase and BKWishlist.nearBase()) then return end
    BKExport.write("hourly", false)
end

table.insert(BKContextMenu.globalActions, { label = "Export base inventory (file)", fn = onExport })
Events.EveryHours.Add(onHour)

return BKExport
