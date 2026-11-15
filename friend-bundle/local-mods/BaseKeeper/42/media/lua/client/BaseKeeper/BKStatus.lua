-- Base Keeper: base status. Every ten game minutes it looks through every zone's containers, floor and bags and
-- keeps two lists: alerts (cold storage going bad) and the wishlist (stock below the thresholds in BKStatus.NEEDS).
-- New alerts and newly low stock are announced once as halo text over the player and in the console; a persisting
-- alert is repeated every REMIND_HOURS. BKStatusWindow shows the current lists. Nothing here moves anything.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/Engine/BKPlanner"

BKStatus = BKStatus or {}

BKStatus.REMIND_HOURS = 12      -- a persisting alert (fridge without power, rotten food) is repeated this often
BKStatus.HUNGER_PER_DAY = 1.0   -- hunger points one survivor eats per game day (rough; tune in-game)
BKStatus.AMMO_MIN = 30          -- rounds per calibre present in the base
BKStatus.BOX_ROUNDS = 20        -- a "Box of ... Rounds" counts as this many (vanilla boxes hold 20 or 50)
BKStatus.CARTON_ROUNDS = 200    -- a "Carton of ..." counts as this many (vanilla cartons hold several boxes)
BKStatus.NOT_STOCK = { bin = true, dumpster = true, composter = true } -- what is in the bin is not stock

-- Wishlist thresholds. amount(item, class) returns what the item contributes, nil when it does not count.
-- Edit min values here; keys are stable so the announce memory survives edits.
BKStatus.NEEDS = {
    { key = "food", label = "Food", unit = "days", min = 3, amount = function(item, class)
        if not BKItemClass.isFood(class) or class == "trash" then return nil end
        local fn = item.getHungChange
        if type(fn) ~= "function" then return nil end
        local ok, h = pcall(fn, item)
        if ok and tonumber(h) and h < 0 then return -h / BKStatus.HUNGER_PER_DAY end
        return nil
    end },
    { key = "water", label = "Water", unit = "L", min = 10, fluid = { Water = true, TaintedWater = true } }, -- tainted boils
    { key = "bandage", label = "Bandages", min = 5, amount = function(item)
        local fn = item.getBandagePower
        local ok, p = type(fn) == "function" and pcall(fn, item)
        return (ok and tonumber(p) and p > 0) and 1 or nil
    end },
    { key = "disinfectant", label = "Disinfectant", min = 1, amount = function(item)
        local fn = item.getAlcoholPower
        local ok, p = type(fn) == "function" and pcall(fn, item)
        return (ok and tonumber(p) and p > 0) and 1 or nil
    end },
    { key = "painkillers", label = "Painkillers", min = 1, types = { Pills = 1 } },
    { key = "antibiotics", label = "Antibiotics", min = 1, types = { Antibiotics = 1 } },
    { key = "fuel", label = "Fuel", unit = "L", min = 10, fluid = { Petrol = true } },
    { key = "nails", label = "Nails", min = 50, types = { Nails = 1, NailsBox = 100 } },
    { key = "planks", label = "Planks", min = 10, types = { Plank = 1 } },
    { key = "batteries", label = "Batteries", min = 2, types = { Battery = 1 } },
    { key = "soap", label = "Soap", min = 1, amount = function(item)
        local ok, t = pcall(function() return string.lower(item:getType()) end)
        return (ok and t and string.find(t, "soap", 1, true)) and 1 or nil
    end },
}

BKStatus.current = { alerts = {}, wants = {}, at = nil, partial = false, zones = 0 }
BKStatus.version = 0           -- bumped on every refresh so the window re-renders its lines once
BKStatus.announced = {}        -- alert key -> world hours when last announced
BKStatus.lowBefore = {}        -- want key -> true while it was low at the previous refresh
BKStatus.firstDone = false

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

-- Java methods that only some item classes have (Food: getHungChange, isFresh...). Calling a missing one throws
-- and the game prints a stack trace even inside pcall, so the method is looked up first, as BKItemClass does.
local function call(item, method, ...)
    local fn = item[method]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, item, ...)
    if ok then return res end
    return nil
end

local function worldHours()
    return tonumber(safe(function() return getGameTime():getWorldAgeHours() end)) or 0
end

local function round1(n) return math.floor(n * 10 + 0.5) / 10 end

-- Items -------------------------------------------------------------------------------------------------------

-- fn(item, holderEntry) for every item in the zone: container contents, bags inside containers (one level),
-- floor items and the contents of floor bags.
function BKStatus.eachItem(scan, fn)
    local function visit(item, holder, depth, worldObj)
        fn(item, holder, worldObj)
        if depth > 0 then return end
        local inv = safe(function()
            if item.getInventory and item:getCategory() == "Container" then return item:getInventory() end
            return nil
        end)
        local items = inv and safe(function() return inv:getItems() end)
        if items then
            for i = 0, items:size() - 1 do
                local inner = items:get(i)
                if inner then visit(inner, holder, depth + 1) end
            end
        end
    end
    for _, c in ipairs(scan.containers) do
        if not BKStatus.NOT_STOCK[c.ctype] then
            local items = safe(function() return c.container:getItems() end)
            if items then
                for i = 0, items:size() - 1 do
                    local item = items:get(i)
                    if item then visit(item, c, 0) end
                end
            end
        end
    end
    for _, f in ipairs(scan.floorItems) do
        visit(f.item, nil, 0, f.worldObj)
    end
end

-- v0.10.4: an item on the floor keeps its fluid on the IsoWorldInventoryObject (item's own container is nil)
local function fluidLitres(item, fluidNames, worldObj)
    local fc = call(item, "getFluidContainer")
    if fc == nil and worldObj ~= nil then fc = call(worldObj, "getFluidContainer") end
    if fc == nil then return nil end
    return safe(function()
        local fluid = fc:getPrimaryFluid()
        if fluid == nil or not fluidNames[tostring(fluid:getFluidTypeString())] then return nil end
        return fc:getAmount()
    end)
end

-- B42 `getAmmoType()` returns an AmmoType object (itemKey "Base.Bullets9mm"), not the full type string; handing it
-- to a String-taking global throws a Java exception the game prints even inside pcall, so it is unwrapped here.
local function ammoLabel(ammoType, item)
    local fullType = ammoType
    if type(fullType) ~= "string" then
        fullType = call(ammoType, "getItemKey") or tostring(ammoType)
    end
    if type(fullType) == "string" then
        local script = safe(function() return getScriptManager():getItem(fullType) end)
        local name = script and safe(function() return script:getDisplayName() end)
        if name and name ~= "" then return tostring(name) end
    end
    return tostring(safe(function() return item:getDisplayName() end) or fullType)
end

-- "Box of 9x19mm Rounds", "Carton of 9x19mm Rounds", "9x19mm Round" and the magazine's round name all -> "9x19mm"
local function ammoKey(name)
    name = tostring(name or "")
    name = string.gsub(name, "^Box of ", "")
    name = string.gsub(name, "^Carton of ", "")
    name = string.gsub(name, " Rounds$", "")
    name = string.gsub(name, " Round$", "")
    name = string.gsub(name, " Boxes$", "")
    name = string.gsub(name, " Box$", "")
    return name
end
BKStatus.ammoLabel, BKStatus.ammoKey = ammoLabel, ammoKey -- shared with BKExport

-- Alerts ------------------------------------------------------------------------------------------------------

local function coldName(c)
    if c.ctype == "fridge" then return "Fridge" end
    return "Freezer"
end

local function perishable(item, class)
    if class == "food_frozen" or class == "food_freezable" or class == "food_perishable" then return true end
    return false
end

-- Alerts for one zone: unpowered cold storage holding perishables (announced), rotten food in cold storage
-- (announced), stale food in cold storage and perishables outside it (window only, quiet = true).
local function zoneAlerts(zone, scan, out)
    local outside = 0
    for _, c in ipairs(scan.containers) do
        if BKPlanner.COLD[c.ctype] then
            local items = safe(function() return c.container:getItems() end)
            local perish, rotten, stale = 0, 0, 0
            if items then
                for i = 0, items:size() - 1 do
                    local item = items:get(i)
                    if item then
                        local class = BKItemClass.classify(item)
                        if class == "trash" and call(item, "isRotten") == true then
                            rotten = rotten + 1
                        elseif perishable(item, class) then
                            perish = perish + 1
                            if call(item, "isFresh") == false then stale = stale + 1 end
                        end
                    end
                end
            end
            local where = string.format("%s @%d,%d", coldName(c), c.x, c.y)
            if not c.powered and perish > 0 then
                table.insert(out, { key = "power:" .. c.x .. "," .. c.y .. "," .. c.z, bad = true,
                    text = string.format("%s has no power, %d perishable%s inside", where, perish, perish == 1 and "" or "s") })
            end
            if rotten > 0 then
                table.insert(out, { key = "rotten:" .. c.x .. "," .. c.y .. "," .. c.z, bad = true,
                    text = string.format("%d rotten in %s", rotten, where) })
            end
            if stale > 0 then
                table.insert(out, { key = "stale:" .. c.x .. "," .. c.y .. "," .. c.z, quiet = true,
                    text = string.format("%d going stale in %s, eat soon", stale, where) })
            end
        end
    end
    BKStatus.eachItem(scan, function(item, holder)
        if holder and BKPlanner.COLD[holder.ctype] then return end
        local class = BKItemClass.classify(item)
        if perishable(item, class) and call(item, "isRotten") ~= true then outside = outside + 1 end
    end)
    if outside > 0 then
        table.insert(out, { key = "outside:" .. tostring(zone.id), quiet = true,
            text = string.format("%d perishable%s outside cold storage (zone %s)", outside, outside == 1 and "" or "s", tostring(zone.id)) })
    end
end

-- Wishlist ----------------------------------------------------------------------------------------------------

local function zoneStock(zone, scan, totals, ammo)
    BKStatus.eachItem(scan, function(item, _, worldObj)
        local class = BKItemClass.classify(item)
        for _, need in ipairs(BKStatus.NEEDS) do
            local n = nil
            if need.amount then
                n = need.amount(item, class)
            elseif need.types then
                local t = safe(function() return item:getType() end)
                n = t and need.types[t] or nil
            elseif need.fluid then
                n = fluidLitres(item, need.fluid, worldObj)
            end
            if n and n > 0 then totals[need.key] = (totals[need.key] or 0) + n end
        end
        if class == "ammo" then
            local maxAmmo = tonumber(call(item, "getMaxAmmo")) or 0
            if maxAmmo > 0 then
                -- a magazine: its rounds count under the calibre it takes
                local ammoType = call(item, "getAmmoType")
                local rounds = tonumber(call(item, "getCurrentAmmoCount")) or 0
                if ammoType and rounds > 0 then
                    local key = ammoKey(ammoLabel(ammoType, item))
                    ammo[key] = ammo[key] or { n = 0, label = key }
                    ammo[key].n = ammo[key].n + rounds
                end
            else
                -- loose round, box or carton: all under one calibre, boxes and cartons as conservative round counts
                local name = tostring(safe(function() return item:getDisplayName() end) or "")
                local lname = string.lower(name)
                local n = 1
                if string.find(lname, "^carton of ") then n = BKStatus.CARTON_ROUNDS
                elseif string.find(lname, "^box of ") then n = BKStatus.BOX_ROUNDS end
                local key = ammoKey(name)
                if key ~= "" then
                    ammo[key] = ammo[key] or { n = 0, label = key }
                    ammo[key].n = ammo[key].n + n
                end
            end
        end
    end)
    -- rain collectors, sinks, barrels: the cook's scan (server file, same Lua state in single player)
    if BKCook and BKCook.scanWater then
        for _, w in ipairs(safe(BKCook.scanWater, zone) or {}) do
            totals.water = (totals.water or 0) + (tonumber(w.amount) or 0)
        end
    end
end

-- Refresh -----------------------------------------------------------------------------------------------------

function BKStatus.refresh(why)
    local alerts, totals, ammo = {}, {}, {}
    local partial, zones = false, 0
    for _, zone in ipairs(BKZones.list()) do
        local ok, err = pcall(function()
            local scan = BKZoneScan.scan(zone)
            if (scan.missingSquares or 0) > 0 then partial = true end
            zoneAlerts(zone, scan, alerts)
            zoneStock(zone, scan, totals, ammo)
        end)
        if not ok then BKLog.warn("status scan failed for zone " .. tostring(zone.id) .. ": " .. tostring(err)) end
        zones = zones + 1
    end
    local wants = {}
    for _, need in ipairs(BKStatus.NEEDS) do
        local have = totals[need.key] or 0
        if have < need.min then
            table.insert(wants, { key = need.key, label = need.label, have = have, min = need.min, unit = need.unit })
        end
    end
    local ammoKeys = {}
    for k in pairs(ammo) do table.insert(ammoKeys, k) end
    table.sort(ammoKeys)
    for _, k in ipairs(ammoKeys) do
        if ammo[k].n < BKStatus.AMMO_MIN then
            table.insert(wants, { key = "ammo:" .. k, label = ammo[k].label, have = ammo[k].n, min = BKStatus.AMMO_MIN, unit = "rounds" })
        end
    end
    BKStatus.current = { alerts = alerts, wants = wants, at = worldHours(), partial = partial, zones = zones }
    BKStatus.version = BKStatus.version + 1
    BKStatus.announce(why)
    return BKStatus.current
end

function BKStatus.describeWant(w)
    local have = math.floor(w.have + 0.5)
    if w.unit == "days" or w.unit == "L" then have = round1(w.have) end
    return string.format("%s: %s%s (want %s)", w.label, tostring(have), w.unit and (" " .. w.unit) or "", tostring(w.min))
end

-- One halo line and console lines for what is new since the last refresh. Low stock is announced only when it
-- turns low (and once on the first refresh); a bad alert is repeated every REMIND_HOURS while it lasts.
function BKStatus.announce(why)
    local cur = BKStatus.current
    local now = cur.at or worldHours()
    local newAlerts, newLow = {}, {}
    local seen = {}
    for _, a in ipairs(cur.alerts) do
        seen[a.key] = true
        if a.bad then
            local last = BKStatus.announced[a.key]
            if last == nil or now - last >= BKStatus.REMIND_HOURS then
                BKStatus.announced[a.key] = now
                table.insert(newAlerts, a.text)
            end
        end
    end
    for key in pairs(BKStatus.announced) do
        if not seen[key] then BKStatus.announced[key] = nil end -- cleared: announce again if it comes back
    end
    local lowNow = {}
    if not cur.partial then
        for _, w in ipairs(cur.wants) do
            lowNow[w.key] = true
            if not BKStatus.lowBefore[w.key] then table.insert(newLow, w.label) end
        end
        BKStatus.lowBefore = lowNow
    end
    if #newAlerts == 0 and #newLow == 0 then return end
    for _, t in ipairs(newAlerts) do BKLog.info("ALERT " .. t) end
    if #newLow > 0 then BKLog.info("low stock: " .. table.concat(newLow, ", ")) end
    local player = getSpecificPlayer(0)
    if not player or not HaloTextHelper then return end
    for _, t in ipairs(newAlerts) do
        pcall(HaloTextHelper.addBadText, player, t)
    end
    if #newLow > 0 then
        pcall(HaloTextHelper.addText, player, "Low on " .. table.concat(newLow, ", "))
    end
end

function BKStatus.tick()
    if #BKZones.list() == 0 then return end
    local ok, err = pcall(BKStatus.refresh, BKStatus.firstDone and "tick" or "first")
    BKStatus.firstDone = true
    if not ok then BKLog.warn("status refresh failed: " .. tostring(err)) end
end

function BKStatus.logStatus()
    local cur = BKStatus.refresh("manual")
    BKLog.info(string.format("status: %d alert(s), %d low, %d zone(s)%s", #cur.alerts, #cur.wants, cur.zones,
        cur.partial and ", zone partly unloaded" or ""))
    for _, a in ipairs(cur.alerts) do BKLog.info("  alert: " .. a.text) end
    for _, w in ipairs(cur.wants) do BKLog.info("  low: " .. BKStatus.describeWant(w)) end
end

Events.EveryTenMinutes.Add(BKStatus.tick)

return BKStatus
