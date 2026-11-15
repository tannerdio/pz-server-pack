-- Base Keeper: scans a zone rectangle and returns what is in it. World knowledge only; no NPC, no rules.
--   scan(zone) -> {
--     containers = { {obj, container, ctype, x, y, z, square, room, locked, powered, index, personal}, ... },
--     fixtures   = { {kind = "stove"|"fridge"|"freezer"|"bed"|"water"|"bench"|"vehicle"|..., x, y, z}, ... },
--     floorItems = { {item, worldObj, container, x, y, z, square, personal}, ... },
--   personal = true on everything inside a "Personal (hands off)" loot area (BKLoot): never a source or destination.
--   }
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"

BKZoneScan = BKZoneScan or {}

-- Container type strings that are never a sorting destination.
BKZoneScan.NO_DEST = {
    stove = true, woodstove = true, microwave = true, fireplace = true, barbecue = true, barbecuepropane = true,
    campfire = true, brazier = true, clothingdryer = true, clothingdryerbasic = true, clothingwasher = true,
    dishwasher = true, trough = true, coffin = true, inventorymale = true, inventoryfemale = true,
    -- composter is deliberately absent: BKPlanner.allowed lets rotten food in (nothing else scores there)
    cashregister = true, vendingpop = true, vendingsnack = true, postbox = true, mannequin = true, scarecrow = true,
    doghouse = true, shelter = true, tent = true, stonefurnace = true, toaster = true, coffeemaker = true,
    logs = true, plankstash = true, TradeUI = true,
    restaurantdisplay = true, displaycasebakery = true, displaycasebutcher = true, grocerstand = true,
    newspaper_knews = true, newspaper_dispatch = true, newspaper_herald = true, newspaper_times = true,
    fruitbusha = true, fruitbushb = true, fruitbushc = true, fruitbushd = true, fruitbushe = true,
    corn = true,
}

-- Container types that also act as room fixtures for place inference.
BKZoneScan.FIXTURE_TYPES = {
    stove = "stove", woodstove = "stove", microwave = "stove", fridge = "fridge", freezer = "freezer",
    icecream = "freezer", toolcabinet = "toolcabinet", metal_shelves = "metal_shelves", garagestorage = "garage",
    garage_storage = "garage", medicine = "medicine", wardrobe = "wardrobe", dresser = "wardrobe",
    clothingrack = "wardrobe", desk = "desk", filingcabinet = "desk", officedrawers = "desk",
    clothingwasher = "laundry", clothingdryer = "laundry", clothingdryerbasic = "laundry", dishwasher = "stove",
    counter = "counter", overhead = "counter", dishescabinet = "counter", cupboard = "counter",
    militarycrate = "armory", militarylocker = "armory", gunbox = "armory", locker = "locker",
}

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function roomName(sq)
    local room = safe(function() return sq:getRoom() end)
    if room == nil then return nil end
    local name = safe(function() return room:getName() end)
    if name == nil or name == "" then return nil end
    return string.lower(tostring(name))
end

local function isLocked(obj)
    if obj.isLockedByPadlock then
        local v = safe(function() return obj:isLockedByPadlock() end)
        if v == true then return true end
    end
    return false
end

local function scanObject(obj, sq, out, x, y, z, room)
    -- fixtures and containers are probed separately so one failing probe never hides a container
    local okF, errF = pcall(function()
        -- fixtures that are not containers
        if obj.getProperties then
            local props = obj:getProperties()
            if props then
                if IsoFlagType and IsoFlagType.bed and props:has(IsoFlagType.bed) then
                    table.insert(out.fixtures, { kind = "bed", x = x, y = y, z = z })
                end
                if IsoFlagType and IsoFlagType.waterPiped and props:has(IsoFlagType.waterPiped) then
                    table.insert(out.fixtures, { kind = "water", x = x, y = y, z = z })
                end
            end
        end
        if instanceof(obj, "IsoStove") then
            table.insert(out.fixtures, { kind = "stove", x = x, y = y, z = z })
        end
        -- rain collectors, barrels, wells: a fluid store that is not an item container (v0.9.0: empties go near it)
        if obj.getFluidCapacity and not (obj.getContainer and obj:getContainer()) then
            local cap = tonumber(obj:getFluidCapacity()) or 0
            if cap > 0 then table.insert(out.fixtures, { kind = "rainwater", x = x, y = y, z = z }) end
        end
        -- a door between inside and outside (v0.9.0: in-season clothing waits by it)
        if instanceof(obj, "IsoDoor") and sq then
            local cell = getCell()
            local inside, outside = false, false
            for _, d in ipairs({ { 0, 0 }, { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
                local n = (d[1] == 0 and d[2] == 0) and sq or cell:getGridSquare(x + d[1], y + d[2], z)
                if n then
                    if n:isOutside() then outside = true else inside = true end
                end
            end
            if inside and outside then table.insert(out.fixtures, { kind = "door", x = x, y = y, z = z }) end
        end
        if instanceof(obj, "IsoGenerator") then
            table.insert(out.fixtures, { kind = "generator", x = x, y = y, z = z })
        end
        if obj.hasComponent and ComponentType and ComponentType.CraftBench and obj:hasComponent(ComponentType.CraftBench) then
            table.insert(out.fixtures, { kind = "bench", x = x, y = y, z = z })
        end
    end)
    if not okF then
        out.scanErrors = (out.scanErrors or 0) + 1
        BKLog.dbg("fixture scan error " .. tostring(errF))
    end
    local ok, err = pcall(function()
        local count = obj.getContainerCount and obj:getContainerCount() or 0
        if count == 0 and obj.getContainer and obj:getContainer() then count = 1 end
        for i = 0, count - 1 do
            local cont = (count == 1 and obj.getContainer and obj:getContainer()) or obj:getContainerByIndex(i)
            if cont then
                local ctype = tostring(cont:getType() or "other")
                local fixtureKind = BKZoneScan.FIXTURE_TYPES[ctype]
                if fixtureKind and fixtureKind ~= "counter" then
                    table.insert(out.fixtures, { kind = fixtureKind, x = x, y = y, z = z })
                elseif fixtureKind == "counter" then
                    table.insert(out.fixtures, { kind = "counter", x = x, y = y, z = z })
                end
                local powered = safe(function() return cont:isPowered() end)
                table.insert(out.containers, {
                    obj = obj, container = cont, ctype = ctype, index = i,
                    x = x, y = y, z = z, square = sq, room = room,
                    locked = isLocked(obj), powered = powered == true,
                    noDest = BKZoneScan.NO_DEST[ctype] == true,
                    zoneId = out.zone and out.zone.id or nil,
                })
            end
        end
    end)
    if not ok then
        out.scanErrors = (out.scanErrors or 0) + 1
        BKLog.dbg("container scan error " .. tostring(err))
    end
end

function BKZoneScan.scanSquare(sq, out)
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local room = roomName(sq)
    local personal = BKLoot.isPersonalAt(x, y, z) or nil
    local objs = sq:getObjects()
    local firstNew = #out.containers + 1
    for i = 0, objs:size() - 1 do
        scanObject(objs:get(i), sq, out, x, y, z, room)
    end
    if personal then
        for i = firstNew, #out.containers do out.containers[i].personal = true end
    end
    local wobs = sq:getWorldObjects()
    for i = 0, wobs:size() - 1 do
        local wo = wobs:get(i)
        local item = safe(function() return wo:getItem() end)
        if item then
            -- a bag on the floor: its contents are an inbox too; the bag itself stays where it is
            local bagInv = safe(function()
                if item.getInventory and item:getCategory() == "Container" then return item:getInventory() end
                return nil
            end)
            -- the Place cursor (ISDropWorldItemAction) and extended placement mark the world object; plain drops do not
            local placed = safe(function()
                return wo:isIgnoreRemoveSandbox() == true or wo:isExtendedPlacement() == true
            end) == true
            table.insert(out.floorItems, {
                item = item, worldObj = wo, container = safe(function() return item:getContainer() end),
                x = x, y = y, z = z, square = sq, room = room, isBag = bagInv ~= nil, placed = placed,
                personal = personal,
            })
            if bagInv then
                table.insert(out.floorBags, { item = item, inventory = bagInv, x = x, y = y, z = z, square = sq,
                    personal = personal })
            end
        end
    end
    if sq.getVehicleContainer then
        local v = safe(function() return sq:getVehicleContainer() end)
        if v then table.insert(out.fixtures, { kind = "vehicle", x = x, y = y, z = z }) end
    end
end

-- Zones never trade items (Tanner, 2026-11-05: "items should not be sorted from one base zone to another"): a zone
-- sees only its own floor, bags and containers. A tagged loot area no zone covers (a basement under the house zone)
-- belongs to the zone directly above or below it (same x/y footprint, any floor), else to the first zone, so each
-- uncovered area has exactly one owner that both fills and tidies it. Its floor is not an inbox.
function BKZoneScan.areaOwner(area, zones)
    zones = zones or BKZones.list()
    for _, z in ipairs(zones) do
        if BKZones.overlaps(z, area.x1, area.y1, area.x2, area.y2, area.z) then return nil end -- covered: not uncovered
    end
    for _, z in ipairs(zones) do
        if BKZones.overlaps(z, area.x1, area.y1, area.x2, area.y2, z.z) then return z end
    end
    return zones[1]
end

function BKZoneScan.scanBase(zone)
    local out = BKZoneScan.scan(zone)
    local zones = BKZones.list()
    for _, area in ipairs(BKLoot.list()) do
        if BKLoot.hasCategories(area) and not BKLoot.isPersonal(area) then -- a personal area has nothing to scan for
            local owner = BKZoneScan.areaOwner(area, zones)
            if owner and owner.id == zone.id then
                local pseudo = { id = "area" .. tostring(area.id), x1 = area.x1, y1 = area.y1, x2 = area.x2, y2 = area.y2, z = area.z }
                local o = BKZoneScan.scan(pseudo)
                for _, c in ipairs(o.containers) do c.zoneId = zone.id; table.insert(out.containers, c) end
                for _, f in ipairs(o.fixtures) do table.insert(out.fixtures, f) end
                out.missingSquares = out.missingSquares + (o.missingSquares or 0)
                out.scanErrors = out.scanErrors + (o.scanErrors or 0)
            end
        end
    end
    return out
end

function BKZoneScan.scan(zone)
    local out = { containers = {}, fixtures = {}, floorItems = {}, floorBags = {}, zone = zone, missingSquares = 0, scanErrors = 0 }
    local cell = getCell()
    -- v0.16.0: every floor of the footprint (BKZones.floors); only the marked floor counts as "not loaded" when a
    -- square is missing, because upper floors and basements have no squares where there is no building
    out.floors = BKZones.floors(zone)
    for _, z in ipairs(out.floors) do
        for x = zone.x1, zone.x2 - 1 do
            for y = zone.y1, zone.y2 - 1 do
                local sq = cell:getGridSquare(x, y, z)
                if sq then
                    BKZoneScan.scanSquare(sq, out)
                elseif z == zone.z then
                    out.missingSquares = out.missingSquares + 1
                end
            end
        end
    end
    -- dedupe fixtures of the same kind on the same tile (multi-container objects add one per container)
    local seen, uniq = {}, {}
    for _, f in ipairs(out.fixtures) do
        local key = f.kind .. ":" .. f.x .. ":" .. f.y .. ":" .. f.z
        if not seen[key] then seen[key] = true; table.insert(uniq, f) end
    end
    out.fixtures = uniq
    BKLog.dbg(string.format("scan zone %s: %d containers, %d fixtures, %d floor items, %d unloaded squares",
        tostring(zone.id), #out.containers, #out.fixtures, #out.floorItems, out.missingSquares))
    return out
end

return BKZoneScan
