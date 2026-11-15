-- Base Keeper: the wishlist. What the base should have, how much of it is there (base zone + loot areas + what the
-- player carries), and which loot is worth picking up. Two kinds of entries:
--   * fixed rows: a fullType (or several that count as one, or a prefix) with a want count, seeded from
--     BKWishlist.SEED and edited in game (ModData "BaseKeeperWishlist": items = overrides, removed = dropped seeds);
--   * the literature rule: any skill book, recipe magazine or skill VHS/CD is wanted while the player still gets
--     something from it (not read, not outgrown, recipes not all known, tape not fully watched and the skill under
--     the media XP cutoff) and no unread copy is in the base or on the player. Nothing to seed, nothing to remove.
-- Counting: base containers (bins excluded), bags one level deep and floor items, same walk as BKStatus, plus the
-- player's inventory. The base part is recounted on container updates while the player is near a zone (debounced),
-- every ten game minutes and when the window opens; away from the base the last full count is kept in ModData.
-- Nothing here moves anything. UI (row tint, tooltip, right-click) lives in UI/BKWishlistUI.lua.
require "ISUI/ISInventoryPane"
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/BKStatus"

BKWishlist = BKWishlist or {}

BKWishlist.MODDATA_KEY = "BaseKeeperWishlist"
BKWishlist.NEAR_TILES = 12          -- base recount on container updates only within this many tiles of a zone/area
BKWishlist.DEBOUNCE_MS = 400        -- real ms between recounts triggered by container updates
BKWishlist.MEDIA_CUTOFF_DEFAULT = 3 -- used when SandboxVars.LevelForMediaXPCutoff is missing
BKWishlist.CUSTOM_GROUP = "Custom"
BKWishlist.GROUPS = { "Medical", "Trapping", "Hunting", "Smithing", "Winter", "Camper", "Stock", "Custom" }

-- Seed rows. key = first type. types: any of these counts; prefix: any fullType starting with it counts; a row may
-- carry both (the canned row: prefix Base.Canned plus the tins that do not start with it).
-- Literature is NOT seeded as fixed rows: lit = true rows are shown in the window through the literature rule
-- (want 1 unread copy while the rule says the player still needs it) and never counted as plain items.
BKWishlist.SEED = {
    -- Trapping
    { types = { "Base.Saw", "Base.GardenSaw", "Base.CrudeSaw" }, want = 2, group = "Trapping", label = "Saw" },
    { types = { "Base.Twine" }, want = 10, group = "Trapping" },
    { types = { "Base.Wire" }, want = 10, group = "Trapping" }, -- 5 per cage trap, Trapping 3 needed: not urgent
    { types = { "Base.Pliers" }, want = 1, group = "Trapping" },
    { types = { "Base.WoodenStick2" }, want = 20, group = "Trapping" },
    { types = { "Base.Carrots", "Base.Cabbage", "Base.Potato", "Base.Apple", "Base.Corn", "Base.Lettuce" }, want = 10, group = "Trapping", label = "Trap bait (fresh veg/fruit)" },
    { types = { "Base.HuntingMag1" }, lit = true, group = "Trapping" }, -- snare
    { types = { "Base.HuntingMag2" }, lit = true, group = "Trapping" }, -- stick trap, wooden box trap
    { types = { "Base.HuntingMag3" }, lit = true, group = "Trapping" },
    { types = { "Base.BookTrapping2" }, lit = true, group = "Trapping" },
    { types = { "Base.BookTrapping3" }, lit = true, group = "Trapping" },
    -- Hunting (added 2026-11-05: deer into the powered freezer is the best winter calorie source; ammo is plentiful,
    -- .308 381 and 5.56 300 rounds, so the wants are a quiet scoped rifle, butchering/tracking skill and salt)
    { types = { "Base.HuntingRifle", "Base.VarmintRifle" }, want = 2, group = "Hunting", label = "Hunting rifle (MSR788 .308 or R700)" },
    { types = { "Base.x4Scope", "Base.x8Scope" }, want = 1, group = "Hunting", label = "Rifle scope x4/x8" },
    { types = { "Base.Salt" }, want = 4, group = "Hunting" },
    { types = { "Base.BookButchering1" }, lit = true, group = "Hunting" },
    { types = { "Base.BookButchering2" }, lit = true, group = "Hunting" },
    { types = { "Base.BookTracking1" }, lit = true, group = "Hunting" },
    { types = { "Base.BookTracking3" }, lit = true, group = "Hunting" },
    -- Smithing (parked 2026-11-06, Tanner "update it": winter food first; uncomment to bring the group back)
    --[[
    { types = { "Base.Stone2" }, want = 15, group = "Smithing" },
    { types = { "Base.ConcretePowder", "Base.BucketConcreteFull" }, want = 2, group = "Smithing", label = "Concrete (bag or bucket)" },
    { types = { "Base.ScrapMetal" }, want = 20, group = "Smithing" },
    { types = { "Base.MetalBar" }, want = 6, group = "Smithing" },
    { types = { "Base.MetalPipe" }, want = 6, group = "Smithing" },
    { types = { "Base.Whetstone", "Base.File" }, want = 2, group = "Smithing", label = "Whetstone or file" },
    { types = { "Base.LargeBellows" }, want = 1, group = "Smithing" },
    { types = { "Base.SmithingMag1" }, lit = true, group = "Smithing" },
    { types = { "Base.SmithingMag9" }, lit = true, group = "Smithing" },
    { types = { "Base.SmithingMag6" }, lit = true, group = "Smithing" },
    { types = { "Base.SmithingMag5" }, lit = true, group = "Smithing" },
    { types = { "Base.SmithingMag3" }, lit = true, group = "Smithing" },
    { types = { "Base.BookBlacksmith2" }, lit = true, group = "Smithing" },
    { types = { "Base.BookMasonry2" }, lit = true, group = "Smithing" },
    --]]
    -- Medical (added 2026-11-06: no antibiotics in the base; the only cure for an infected wound)
    { types = { "Base.Antibiotics" }, want = 5, group = "Medical" },
    -- Winter (re-sized 2026-11-05 from the day-52 export: well + generators + Rosewood pump, so water and fuel are
    -- logistics, not stock; the gaps are fire starters, a fishing rod, firewood and calorie-dense dry food)
    { types = { "Base.Axe" }, want = 1, group = "Winter" },
    { types = { "Base.Lighter", "Base.LighterDisposable", "Base.LighterBBQ", "Base.Matches", "Base.Matchbox" }, want = 6, group = "Winter", label = "Lighter or matches" },
    { types = { "Base.Candle", "Base.CandleBox" }, want = 6, group = "Winter", label = "Candle (or box)" },
    { types = { "Base.Battery" }, want = 10, group = "Winter" },
    { types = { "Base.Torch", "Base.HandTorch" }, want = 3, group = "Winter", label = "Flashlight" },
    { types = { "Base.Log", "Base.Firewood", "Base.FirewoodBundle" }, want = 30, group = "Winter", label = "Logs / firewood (fireplace, smithing)" },
    { types = { "Base.FishingRod", "Base.CraftedFishingRod" }, want = 2, group = "Winter", label = "Fishing rod" },
    { types = { "Base.FishingLine", "Base.PremiumFishingLine" }, want = 6, group = "Winter", label = "Fishing line (2 per rod)" },
    { types = { "Base.AnimalFeedBag" }, want = 4, group = "Winter" },
    { prefix = "Base.Canned", types = { "Base.TinnedBeans", "Base.TinnedSoup", "Base.TunaTin", "Base.Dogfood", "Base.MysteryCan", "Base.DentedCan", "Base.WaterRationCan" },
      want = 150, group = "Winter", label = "Canned food", key = "Base.Canned*" }, -- 2026-11-06: 80 -> 150 (120-day bank by Dec 1)
    { types = { "Base.Rice", "Base.Pasta", "Base.OatsRaw", "Base.Flour2", "Base.Cereal", "Base.DriedKidneyBeans", "Base.DriedSplitPeas",
        "Base.DriedLentils", "Base.DriedWhiteBeans", "Base.DriedBlackBeans", "Base.DriedChickpeas" },
      want = 100, group = "Winter", label = "Dry staples (rice, pasta, oats, flour, cereal, dried beans)" }, -- 40 -> 100
    { types = { "Base.EmptyJar" }, want = 20, group = "Winter" }, -- 8 -> 20: jar the garden
    { types = { "Base.JarLid" }, want = 20, group = "Winter" },
    { types = { "Base.Vinegar2" }, want = 3, group = "Winter" },
    { types = { "Base.Sugar" }, want = 3, group = "Winter" },
    { types = { "Base.WaterBottle" }, want = 6, group = "Winter" },
    { types = { "Base.Socks_Long" }, want = 4, group = "Winter" },
    { types = { "Base.LongJohns", "Base.LongJohns_Bottoms", "Base.LongJohns_Crafted_Cotton", "Base.LongJohns_Bottoms_Crafted_Cotton" }, want = 2, group = "Winter", label = "Long johns" },
    -- Camper (parked 2026-11-06 with Smithing)
    --[[
    { types = { "Base.Screwdriver" }, want = 2, group = "Camper" },
    { types = { "Base.Wrench" }, want = 1, group = "Camper" },
    { types = { "Base.LugWrench" }, want = 1, group = "Camper" },
    { types = { "Base.Jack" }, want = 1, group = "Camper" },
    { prefix = "Base.ModernTire", want = 2, group = "Camper", label = "Spare tire", key = "Base.ModernTire*" },
    { types = { "Base.RubberHose" }, want = 1, group = "Camper" },
    { prefix = "Base.SleepingBag", want = 1, group = "Camper", label = "Sleeping bag", key = "Base.SleepingBag*" },
    { types = { "Base.Pillow" }, want = 1, group = "Camper" },
    { types = { "Base.MechanicMag1" }, lit = true, group = "Camper" },
    { types = { "Base.MechanicMag2" }, lit = true, group = "Camper" },
    --]]
}

-- Three-letter skill codes used by recorded media lines (vanilla ISRadioInteractions) -> Perks field name.
BKWishlist.MEDIA_CODES = {
    SPR = "Sprinting", LFT = "Lightfoot", NIM = "Nimble", SNE = "Sneak", BAA = "Axe", BUA = "Blunt", CRP = "Woodwork",
    COO = "Cooking", FRM = "Farming", DOC = "Doctor", ELC = "Electricity", MTL = "MetalWelding", FKN = "FlintKnapping",
    CRV = "Carving", AIM = "Aiming", REL = "Reloading", FIS = "Fishing", TRA = "Trapping", FOR = "PlantScavenging",
    TAI = "Tailoring", MEC = "Mechanics", CMB = "Combat", SPE = "Spear", SBU = "SmallBlunt", LBA = "LongBlade",
    SBA = "SmallBlade", MAS = "Masonry", POT = "Pottery", BLA = "Blacksmith", GLA = "Glassmaking", HUS = "Husbandry",
    BUT = "Butchering", TRK = "Tracking",
}

BKWishlist.data = nil        -- ModData: { items = { [key] = { want, group, label } }, removed = { [key] = true }, have, lit, haveAt, haveDay }
BKWishlist.carried = {}      -- fullType -> count on the player (plain items)
BKWishlist.carriedLit = {}   -- fullType -> unread wanted copies on the player
BKWishlist.version = 0       -- bumped whenever counts or rows change; UI re-renders on it
BKWishlist.dirty = false
BKWishlist.lastCountMs = 0
BKWishlist.partial = false
BKWishlist.lastBaseAt = nil  -- world hours of the last full base count this session (nil = cache from ModData only)

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function call(obj, method, ...)
    local fn = obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, obj, ...)
    if ok then return res end
    return nil
end

local function worldHours()
    return tonumber(safe(function() return getGameTime():getWorldAgeHours() end)) or 0
end

local function nowMs()
    return tonumber(safe(getTimestampMs)) or 0
end

local function player()
    return getSpecificPlayer(0)
end

-- Data -------------------------------------------------------------------------------------------------------

local function store()
    if BKWishlist.data == nil then BKWishlist.data = ModData.getOrCreate(BKWishlist.MODDATA_KEY) end
    local d = BKWishlist.data
    if d.items == nil then d.items = {} end
    if d.removed == nil then d.removed = {} end
    if d.have == nil then d.have = {} end
    if d.lit == nil then d.lit = {} end
    return d
end

local function bump()
    BKWishlist.version = BKWishlist.version + 1
end

function BKWishlist.rowKey(row)
    return row.key or (row.types and row.types[1]) or row.prefix
end

function BKWishlist.displayName(fullType)
    local script = safe(function() return getScriptManager():getItem(fullType) end)
    local name = script and safe(function() return script:getDisplayName() end)
    if name and name ~= "" then return tostring(name) end
    local short = string.gsub(tostring(fullType), "^[^.]*%.", "")
    return short
end

function BKWishlist.rowLabel(row)
    if row.label then return row.label end
    return BKWishlist.displayName(BKWishlist.rowKey(row))
end

-- Every active row: seeds (minus removed, with want/group overrides) + custom rows added in game.
function BKWishlist.rows()
    local d = store()
    local out, seen = {}, {}
    for _, seed in ipairs(BKWishlist.SEED) do
        local key = BKWishlist.rowKey(seed)
        seen[key] = true
        if not d.removed[key] then
            local row = { key = key, types = seed.types, prefix = seed.prefix, want = seed.want, group = seed.group,
                label = seed.label, lit = seed.lit }
            local o = d.items[key]
            if o then
                if o.want then row.want = o.want end
                if o.group then row.group = o.group end
            end
            table.insert(out, row)
        end
    end
    local customKeys = {}
    for key, o in pairs(d.items) do
        if not seen[key] and not d.removed[key] then table.insert(customKeys, key) end
    end
    table.sort(customKeys)
    for _, key in ipairs(customKeys) do
        local o = d.items[key]
        table.insert(out, { key = key, types = { key }, want = o.want, group = o.group or BKWishlist.CUSTOM_GROUP, label = o.label, lit = o.lit })
    end
    return out
end

-- Row for a fullType, if any (first match: exact type list, then prefix).
function BKWishlist.rowFor(fullType)
    if fullType == nil then return nil end
    for _, row in ipairs(BKWishlist.rows()) do
        if row.types then
            for _, t in ipairs(row.types) do
                if t == fullType then return row end
            end
        end
        if row.prefix and string.sub(fullType, 1, string.len(row.prefix)) == row.prefix then
            return row
        end
    end
    return nil
end

-- In-game edits ----------------------------------------------------------------------------------------------

-- Sets the want count of the row this fullType belongs to (a seed row keyed by another type of its list included),
-- or adds a custom row for the exact type. A removed seed row is not revived: the type gets its own row.
function BKWishlist.setWant(fullType, want)
    local d = store()
    local row = BKWishlist.rowFor(fullType)
    local key = (row and not row.lit) and row.key or fullType
    d.removed[key] = nil
    d.items[key] = d.items[key] or {}
    d.items[key].want = want
    BKLog.info(string.format("wishlist: want %d %s", want, tostring(key)))
    BKWishlist.dirty = true
    bump()
end

function BKWishlist.remove(fullType)
    local d = store()
    local row = BKWishlist.rowFor(fullType)
    local key = row and row.key or fullType
    d.items[key] = nil
    d.removed[key] = true
    BKLog.info("wishlist: removed " .. tostring(key))
    bump()
end

function BKWishlist.resetSeeds()
    local d = store()
    d.removed = {}
    for _, seed in ipairs(BKWishlist.SEED) do d.items[BKWishlist.rowKey(seed)] = nil end
    BKLog.info("wishlist: seed rows restored")
    BKWishlist.dirty = true
    bump()
end

-- Literature rule ---------------------------------------------------------------------------------------------

local function mediaCutoff()
    local v = SandboxVars and tonumber(SandboxVars.LevelForMediaXPCutoff) or nil
    return v or BKWishlist.MEDIA_CUTOFF_DEFAULT
end

local function perkLevel(p, perkName)
    local perk = Perks and Perks[perkName] or nil
    if perk == nil then return nil end
    return tonumber(safe(function() return p:getPerkLevel(perk) end))
end

-- A tape or CD still trains something: any line code for a skill the player has below the media XP cutoff.
local function mediaWanted(md, p)
    local n = tonumber(call(md, "getLineCount")) or 0
    local cutoff = mediaCutoff()
    for i = 0, n - 1 do
        local line = safe(function() return md:getLine(i) end)
        local codes = line and tostring(call(line, "getCodes") or "") or ""
        for code in string.gmatch(codes, "([A-Z][A-Z][A-Z])[+-]?[%d%.]*") do
            local perkName = BKWishlist.MEDIA_CODES[code]
            if perkName then
                local lvl = perkLevel(p, perkName)
                if lvl ~= nil and lvl < cutoff then return true end
            end
        end
    end
    return false
end

-- True when this item is a skill book, recipe magazine or skill tape the player still gets something from.
function BKWishlist.literatureWanted(item, p)
    p = p or player()
    if item == nil or p == nil then return false end
    local md = call(item, "getMediaData")
    if md ~= nil then
        local seen = call(item, "hasBeenSeen", p) == true or call(item, "hasBeenHeard", p) == true
        -- takes the MediaData, not the tape (vanilla ISLiteratureUI passes the media entry)
        local all = safe(function() return getZomboidRadio():getRecordedMedia():hasListenedToAll(p, md) end)
        if seen or all == true then return false end
        return mediaWanted(md, p)
    end
    if call(item, "IsLiterature") ~= true then return false end
    local skill = call(item, "getSkillTrained")
    local recipes = call(item, "getLearnedRecipes")
    local nRecipes = recipes and tonumber(safe(function() return recipes:size() end)) or 0
    if (skill == nil or skill == "") and nRecipes == 0 then return false end -- novels, comics, maps
    local read = safe(function() return ISInventoryPane.isLiteratureRead(nil, p, item) end)
    return read ~= true
end

-- Same question for a seeded literature row without an item in hand (window): from the script item.
function BKWishlist.literatureRowWanted(fullType, p)
    p = p or player()
    if p == nil then return false end
    local script = safe(function() return getScriptManager():getItem(fullType) end)
    if script == nil then return false end
    local skill = call(script, "getSkillTrained")
    if skill and skill ~= "" and SkillBook and SkillBook[skill] and SkillBook[skill].perk then
        local maxLvl = tonumber(call(script, "getMaxLevelTrained")) or 0
        local lvl = tonumber(safe(function() return p:getPerkLevel(SkillBook[skill].perk) end)) or 0
        if maxLvl < lvl + 1 then return false end -- outgrown
        local readList = call(p, "getAlreadyReadBook")
        if readList and safe(function() return readList:contains(fullType) end) == true then return false end
        return true
    end
    local recipes = call(script, "getLearnedRecipes")
    local n = recipes and tonumber(safe(function() return recipes:size() end)) or 0
    if n > 0 then
        local known = call(p, "getKnownRecipes")
        if known and safe(function() return known:containsAll(recipes) end) == true then return false end
        return true
    end
    return false
end

-- Counting ---------------------------------------------------------------------------------------------------

local function addCount(plain, lit, item, p)
    local fullType = call(item, "getFullType")
    if fullType == nil then return end
    if BKWishlist.literatureWanted(item, p) then
        lit[fullType] = (lit[fullType] or 0) + 1
    else
        plain[fullType] = (plain[fullType] or 0) + 1
    end
end

-- Player inventory, bags inside it at any depth.
function BKWishlist.countCarried()
    local p = player()
    local plain, lit = {}, {}
    if p == nil then return plain, lit end
    local function walk(inv, depth)
        local items = inv and safe(function() return inv:getItems() end)
        if items == nil then return end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                addCount(plain, lit, item, p)
                if depth < 4 then
                    local inner = safe(function()
                        if item.getInventory and item:getCategory() == "Container" then return item:getInventory() end
                        return nil
                    end)
                    if inner then walk(inner, depth + 1) end
                end
            end
        end
    end
    walk(safe(function() return p:getInventory() end), 0)
    BKWishlist.carried, BKWishlist.carriedLit = plain, lit
    return plain, lit
end

-- Tagged loot areas no zone covers (another floor): same rule as BKZoneScan.scanBase.
local function uncoveredAreas(zones)
    local out = {}
    for _, area in ipairs(BKLoot.list()) do
        if BKLoot.hasCategories(area) and not BKLoot.isPersonal(area) then
            local covered = false
            for _, z in ipairs(zones) do
                if BKZones.overlaps(z, area.x1, area.y1, area.x2, area.y2, area.z) then covered = true end
            end
            if not covered then
                table.insert(out, { id = "area" .. tostring(area.id), x1 = area.x1, y1 = area.y1, x2 = area.x2, y2 = area.y2, z = area.z })
            end
        end
    end
    return out
end

-- Full base count. Returns false (and keeps the cache) when a zone is partly unloaded.
function BKWishlist.countBase()
    local p = player()
    local zones = BKZones.list()
    if p == nil or #zones == 0 then return false end
    local plain, lit = {}, {}
    local partial = false
    local rects = {}
    for _, z in ipairs(zones) do table.insert(rects, z) end
    for _, a in ipairs(uncoveredAreas(zones)) do table.insert(rects, a) end
    for _, rect in ipairs(rects) do
        local ok, err = pcall(function()
            local scan = BKZoneScan.scan(rect)
            if (scan.missingSquares or 0) > 0 then partial = true end
            BKStatus.eachItem(scan, function(item) addCount(plain, lit, item, p) end)
        end)
        if not ok then BKLog.warn("wishlist count failed for " .. tostring(rect.id) .. ": " .. tostring(err)); partial = true end
    end
    BKWishlist.partial = partial
    if partial then return false end
    local d = store()
    d.have, d.lit = plain, lit
    d.haveAt = worldHours()
    BKWishlist.lastBaseAt = d.haveAt
    return true
end

function BKWishlist.nearBase()
    local p = player()
    if p == nil then return false end
    local x, y = p:getX(), p:getY()
    local m = BKWishlist.NEAR_TILES
    local function near(r)
        return x >= r.x1 - m and x < r.x2 + m and y >= r.y1 - m and y < r.y2 + m
    end
    for _, z in ipairs(BKZones.list()) do
        if near(z) then return true end
    end
    for _, a in ipairs(BKLoot.list()) do
        if near(a) then return true end
    end
    return false
end

-- Recount: carried always, base when near (or forced). Bumps the version when anything changed.
function BKWishlist.recount(why, force)
    local before = BKWishlist.version
    BKWishlist.countCarried()
    local didBase = false
    if force or BKWishlist.nearBase() then didBase = BKWishlist.countBase() end
    BKWishlist.lastCountMs = nowMs()
    BKWishlist.dirty = false
    bump()
    BKLog.dbg(string.format("wishlist recount (%s): base %s", tostring(why), didBase and "counted" or (BKWishlist.partial and "partly unloaded, cache kept" or "cache")))
    return BKWishlist.version ~= before
end

-- Have for a row (base cache + carried). Literature rows count unread copies.
function BKWishlist.have(row)
    local d = store()
    local plain, lit = d.have, d.lit
    local n = 0
    local function add(tbl, carriedTbl, key)
        n = n + (tbl[key] or 0) + (carriedTbl[key] or 0)
    end
    if row.types then
        for _, t in ipairs(row.types) do
            if row.lit then add(lit, BKWishlist.carriedLit, t) else add(plain, BKWishlist.carried, t) end
        end
    end
    if row.prefix then
        local len = string.len(row.prefix)
        local function addPrefix(tbl)
            for k, v in pairs(tbl) do
                if string.sub(k, 1, len) == row.prefix then n = n + v end
            end
        end
        if row.lit then addPrefix(lit); addPrefix(BKWishlist.carriedLit) else addPrefix(plain); addPrefix(BKWishlist.carried) end
    end
    return n
end

-- Unread copies of this fullType in base + carried (literature rule).
function BKWishlist.haveUnread(fullType)
    local d = store()
    return (d.lit[fullType] or 0) + (BKWishlist.carriedLit[fullType] or 0)
end

-- Status for an item in any container: nil when not wanted, else { have, want, label, group, lit }.
-- The highlight shows when have < want.
function BKWishlist.status(item, p)
    local fullType = call(item, "getFullType")
    if fullType == nil then return nil end
    local row = BKWishlist.rowFor(fullType)
    if row and not row.lit then
        return { have = BKWishlist.have(row), want = row.want or 1, label = BKWishlist.rowLabel(row), group = row.group, lit = false }
    end
    if BKWishlist.literatureWanted(item, p) then
        local group = row and row.group or "Skills"
        return { have = BKWishlist.haveUnread(fullType), want = 1, label = BKWishlist.displayName(fullType), group = group, lit = true }
    end
    return nil
end

function BKWishlist.wanted(item, p)
    local s = BKWishlist.status(item, p)
    return s ~= nil and s.have < s.want, s
end

-- Window lines -----------------------------------------------------------------------------------------------

-- Short rows grouped, in GROUPS order. Each: { text, short = true/false }.
function BKWishlist.report()
    local p = player()
    local byGroup = {}
    local total, short = 0, 0
    for _, row in ipairs(BKWishlist.rows()) do
        local have, want, show = 0, row.want or 1, true
        if row.lit then
            local fullType = row.types and row.types[1] or row.key
            if BKWishlist.literatureRowWanted(fullType, p) then
                have, want = BKWishlist.haveUnread(fullType), 1
            else
                show = false -- read, outgrown or recipes known
            end
        else
            have = BKWishlist.have(row)
        end
        if show then
            total = total + 1
            if have < want then
                short = short + 1
                byGroup[row.group] = byGroup[row.group] or {}
                table.insert(byGroup[row.group], { label = BKWishlist.rowLabel(row), have = have, want = want, lit = row.lit })
            end
        end
    end
    local d = store()
    return { byGroup = byGroup, total = total, short = short, baseAt = d.haveAt, partial = BKWishlist.partial, live = BKWishlist.lastBaseAt ~= nil }
end

function BKWishlist.groupOrder(byGroup)
    local order = {}
    local seen = {}
    for _, g in ipairs(BKWishlist.GROUPS) do
        if byGroup[g] then table.insert(order, g); seen[g] = true end
    end
    local extra = {}
    for g in pairs(byGroup) do
        if not seen[g] then table.insert(extra, g) end
    end
    table.sort(extra)
    for _, g in ipairs(extra) do table.insert(order, g) end
    return order
end

local function dayText(hours)
    if hours == nil then return "never" end
    local day = math.floor(hours / 24) + 1
    local h = math.floor(hours - (day - 1) * 24)
    return string.format("day %d %02d:00", day, h)
end

function BKWishlist.lines()
    local rep = BKWishlist.report()
    local lines = {}
    local function add(text, kind) table.insert(lines, { text = text, kind = kind }) end
    if rep.short == 0 then
        add(string.format("  all %d wishlist rows stocked", rep.total), "ok")
    else
        for _, g in ipairs(BKWishlist.groupOrder(rep.byGroup)) do
            add("  " .. string.upper(g), "head")
            for _, r in ipairs(rep.byGroup[g]) do
                add(string.format("    %s %d/%d", r.label, r.have, r.want), "want")
            end
        end
    end
    if rep.baseAt == nil then
        add("  (base not counted yet, stand near it)", "head")
    elseif not rep.live then
        add("  (base counts from " .. dayText(rep.baseAt) .. ", last session)", "head")
    elseif rep.partial then
        add("  (base partly unloaded, last full count " .. dayText(rep.baseAt) .. ")", "head")
    end
    return lines
end

function BKWishlist.logReport()
    BKWishlist.recount("manual", true)
    local rep = BKWishlist.report()
    BKLog.info(string.format("wishlist: %d of %d rows short, base counted %s%s", rep.short, rep.total, dayText(rep.baseAt),
        rep.partial and " (partly unloaded)" or ""))
    for _, g in ipairs(BKWishlist.groupOrder(rep.byGroup)) do
        for _, r in ipairs(rep.byGroup[g]) do
            BKLog.info(string.format("  %s: %s %d/%d%s", g, r.label, r.have, r.want, r.lit and " (unread)" or ""))
        end
    end
end

-- Triggers ---------------------------------------------------------------------------------------------------

local function onContainerUpdate()
    BKWishlist.dirty = true
end

local function onTick()
    if not BKWishlist.dirty then return end
    if nowMs() - BKWishlist.lastCountMs < BKWishlist.DEBOUNCE_MS then return end
    local ok, err = pcall(BKWishlist.recount, "container")
    if not ok then BKLog.warn("wishlist recount failed: " .. tostring(err)); BKWishlist.dirty = false end
end

local function onTenMinutes()
    if #BKZones.list() == 0 then return end
    local ok, err = pcall(BKWishlist.recount, "tick")
    if not ok then BKLog.warn("wishlist recount failed: " .. tostring(err)) end
end

local function onStart()
    local d = store()
    local n = 0
    for _ in pairs(d.items) do n = n + 1 end
    BKLog.info(string.format("wishlist loaded: %d seed rows, %d edits, base counted %s", #BKWishlist.SEED, n, dayText(d.haveAt)))
    BKWishlist.dirty = true
end

Events.OnContainerUpdate.Add(onContainerUpdate)
Events.OnTick.Add(onTick)
Events.EveryTenMinutes.Add(onTenMinutes)
Events.OnGameStart.Add(onStart)

return BKWishlist
