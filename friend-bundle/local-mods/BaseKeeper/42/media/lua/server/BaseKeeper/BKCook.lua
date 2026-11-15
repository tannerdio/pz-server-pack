-- Base Keeper: meal prep (v0.10.0: breakfast 06-12 and dinner 16-21, sized by calories to keep the player above
-- BKCook.GOAL_KG; see the constants). Originally breakfast only: once a game day the keeper preps meals from whatever the
-- zone's kitchen holds: any evolved recipe (stew, soup, salad, pie, sandwich...) whose base item is in a zone container
-- and that has ingredients in the zone's containers. Pots that need water are filled from a water source inside the
-- zone (rain collector, sink). The prepped pots go into the stove for the player to cook, or back where the base item
-- came from when the zone has no stove.
-- Accuracy: every ingredient is added through the vanilla EvolvedRecipe.addItem call with the player as the cook, so
-- cooking XP, chef name, nutrition, names and partial use are exactly what the right-click menu gives. This file
-- awards no XP of its own. Canned food is never used (jarred food is fine); rotten food, favourites, frozen food the
-- recipe refuses and finished meals are never used either.
-- Craft-window meals (omelette, pancakes, oatmeal, guacamole, pizza...) are the second engine: B42 craft recipes of
-- category Cooking that award Cooking XP, run through the game's own HandcraftLogic exactly as the craft window does
-- (inputs auto-picked by the game, performCurrentRecipe, OnCreate code, XP awarded by CraftRecipeData).
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/Engine/BKZoneScan"

if isClient() then return end

BKCook = BKCook or {}
BKCook.MEALS = 2                -- fallback meal count when the nutrition read fails
-- v0.10.0 calorie meals (Tanner 2026-11-05: "i need meals to keep me above 75 [kg]"). B42 weight rule: the calorie
-- pool (Nutrition:getCalories) below 0 loses weight (loss threshold min(0, (kg - 70) * 30) = 0 at 75 kg), above
-- ~1000 gains (more with carbs/lipids > 400). So each run preps enough to reach the pool target by the next run.
BKCook.GOAL_KG = 75             -- never drop below this
BKCook.SAFE_KG = 78             -- under this the target is the gain zone, at/above it just stay positive
BKCook.POOL_GAIN = 1300         -- calorie pool target while under SAFE_KG
BKCook.POOL_KEEP = 400          -- calorie pool target at/above SAFE_KG
BKCook.DAILY_BURN = 2800        -- estimated kcal burned per game day by an active survivor (logged, tune from play)
BKCook.MIN_MEALS = 1
BKCook.MAX_MEALS = 4
BKCook.MEAL_KCAL = 600          -- what one pot roughly holds; v0.14.3: "Prep a meal now" makes exactly one and thaws one
-- v0.14.3 (Tanner 2026-11-08, after the first working breakfast made a soup and a stir-fry: "that's too much, I could
-- only eat the stir fry... less is better since I can prep it on demand, don't even do it auto"): the timed runs are
-- OFF by default (menu toggle turns them back on); by hand = one meal whatever the calorie need.
BKCook.ROT_SOON_HOURS = 72      -- food rotting within this is used first regardless of calories (no waste)
BKCook.URGENT_BONUS = 0.6       -- v0.14.0: meal score per ingredient rotting within ROT_SOON_HOURS (eat it before it turns)
-- v0.14.0 thaw-ahead: B42 evolved recipes take no frozen food (no AllowFrozenItem anywhere in the scripts) and the
-- game drops frozen items before the keeper sees them, so meat in the freezer never reached a pot. The prep now moves
-- what the next run needs into a powered fridge. Food.updateFreezing (jar): freezingTime 100 -> 0 takes 1.5 h on a
-- shelf, 3 h in a powered fridge, 0.25 h in a hot oven; freezing back takes 4 h; the frozen flag only clears at 0. A
-- run that comes up short thaws now and is retried every ten game minutes until it cooks or its window closes.
BKCook.THAW_AHEAD = false       -- v0.14.4 (Tanner 2026-11-08: "thawing doesn't matter, disable that"): never move frozen food
BKCook.THAW_MAX_ITEMS = 6       -- frozen items moved to the fridge per run (when THAW_AHEAD is on)
BKCook.THAW_HOURS_FRIDGE = 3    -- hours a frozen item needs in a powered fridge
BKCook.RETRY_LOG_EVERY = 6      -- quiet retries (10 game minutes each) between full "nothing to prep" logs
-- two runs a day: breakfast covers until dinner, dinner covers the night and the morning
BKCook.RUNS = {
    { key = "am", label = "Breakfast", from = 6, to = 12, covers = 0.45 },
    { key = "pm", label = "Dinner", from = 16, to = 21, covers = 0.55 },
}
BKCook.NEAR_TILES = 4           -- the morning run needs the player inside the zone (any floor) or this close to it
BKCook.MAX_SPICES = 2
BKCook.MODDATA_KEY = "BaseKeeperCook"
BKCook.NO_SOURCE = { bin = true, dumpster = true, composter = true, trough = true }
BKCook.STOVES = { stove = 1, woodstove = 2, microwave = 3 } -- preferred first
BKCook.NON_PERISHABLE_OFFAGE = 1000000
-- craft recipes that only cut, open, pack or portion food are not meals
BKCook.CRAFT_SKIP_PREFIX = { "Slice", "Cut", "Halve", "Smash", "Scoop", "Get", "Open", "open_", "Put", "Empty", "Butcher",
    "Make2", "Make4" }
BKCook.CRAFT_SKIP_NAMES = { MakeJar = true } -- preserving is not a meal
BKCook.CHAIN_STEPS = 3          -- craft steps a meal may take (cake batter -> cake in pan -> cake with fruit)

-- Every item with CannedFood = true in the B42 item scripts (lower case type names). Jarred food (CannedCarrots,
-- CannedTomato... made with jars, tag preservedfood) is deliberately not in this list.
local CANNED_TYPES = {}
for _, n in ipairs({
    "WaterRationCan", "MysteryCan", "DentedCan", "CannedBolognese", "CannedBologneseOpen", "CannedCarrots2",
    "CannedCarrotsOpen", "CannedChili", "CannedChiliOpen", "CannedCornedBeef", "CannedCornedBeefOpen", "CannedCorn",
    "CannedCornOpen", "CannedFruitCocktail", "CannedFruitCocktailOpen", "CannedMilk", "CannedMilkOpen",
    "CannedMushroomSoup", "CannedMushroomSoupOpen", "CannedPeaches", "CannedPeachesOpen", "CannedPeas",
    "CannedPeasOpen", "CannedPineapple", "CannedPineappleOpen", "CannedPotato2", "CannedPotatoOpen", "CannedSardines",
    "CannedSardinesOpen", "CannedTomato2", "CannedTomatoOpen", "Dogfood", "DogfoodOpen", "TinnedBeans", "OpenBeans",
    "TinnedSoup", "TinnedSoupOpen", "TunaTin", "TunaTinOpen", "CannedFruitBeverage", "CannedFruitBeverageOpen",
    "WaterRationCan_Box", "MysteryCan_Box", "DentedCan_Box", "CannedBolognese_Box", "CannedCarrots_Box",
    "CannedChili_Box", "CannedCornedBeef_Box", "CannedCorn_Box", "CannedFruitCocktail_Box", "CannedMilk_Box",
    "CannedMushroomSoup_Box", "CannedPeaches_Box", "CannedPeas_Box", "CannedPineapple_Box", "CannedPotato_Box",
    "CannedSardines_Box", "CannedTomato_Box", "Dogfood_Box", "TinnedBeans_Box", "TinnedSoup_Box", "TunaTin_Box",
    "CannedFruitBeverage_Box", "Macandcheese_Box",
}) do CANNED_TYPES[string.lower(n)] = true end

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function lower(s) return string.lower(tostring(s or "")) end

local function itemId(item)
    return safe(function() return item:getID() end)
end

local function displayName(item)
    return tostring(safe(function() return item:getDisplayName() end) or safe(function() return item:getType() end) or "?")
end

-- Canned = the script list above, or an opening recipe for cans, or "canned"/"tinned" in the type name (mod items).
function BKCook.isCanned(item)
    -- v0.14.0: jarred food (B42 jars CannedCarrots, CannedBellPepper, CannedTomato... tag preservedfood) was refused by
    -- the name test below although jars are allowed; the tag decides first
    if ItemTag and ItemTag.PRESERVED_FOOD and safe(function() return item:hasTag(ItemTag.PRESERVED_FOOD) end) == true then
        return false
    end
    local t = lower(safe(function() return item:getType() end))
    if CANNED_TYPES[t] then return true end
    local opening = lower(safe(function() return item:getOpeningRecipe() end))
    if opening ~= "" and string.find(opening, "canned", 1, true) then return true end
    if string.find(t, "canned", 1, true) or string.find(t, "tinned", 1, true) then return true end
    return false
end

-- v0.14.2 (the real reason every pot said "0 usable food, N spice" since v0.4.0): the script-level
-- Item.isSpice() in B42 returns TRUE for every item of type FOOD (bytecode: itemType == FOOD -> 1; the Spice flag is
-- only consulted for DRAINABLE), so the old fallback through getScriptItem() filed buns, bread, radishes and peanut
-- butter as spices and no meal ever had a food in it. Food.isSpice() (the instance) reads the real flag; the script
-- call is only right for non-Food items (spiced drainables).
local function isSpice(item)
    if instanceof(item, "Food") then return safe(function() return item:isSpice() end) == true end
    return safe(function() return item:getScriptItem():isSpice() end) == true
end

-- Hours (game) until this item rots; non-perishables and non-food count as never.
-- v0.14.1: Food.age and OffAgeMax are in DAYS (Food.updateAge adds hours / 24, DaysTotallyRotten goes in as is), so
-- the difference is multiplied by 24. Until now "within 24 h" meant within 24 days, i.e. nearly everything.
local function hoursToRot(item)
    if not instanceof(item, "Food") then return 1e9 end
    local offMax = safe(function() return item:getOffAgeMax() end) or 1e9
    if offMax >= BKCook.NON_PERISHABLE_OFFAGE then return 1e9 end
    local age = safe(function() return item:getAge() end) or 0
    return (offMax - age) * 24
end

local function hungerValue(item)
    if not instanceof(item, "Food") then return 0 end
    return -(safe(function() return item:getHungChange() end) or 0)
end

local function kcal(item)
    if not instanceof(item, "Food") then return 0 end
    return math.max(0, tonumber(safe(function() return item:getCalories() end)) or 0)
end

-- { kg, pool, carbs, lipids, proteins } or nil
function BKCook.nutrition(player)
    local n = safe(function() return player:getNutrition() end)
    if n == nil then return nil end
    local kg = tonumber(safe(function() return n:getWeight() end))
    if kg == nil then return nil end
    return { kg = kg, pool = tonumber(safe(function() return n:getCalories() end)) or 0,
        carbs = tonumber(safe(function() return n:getCarbohydrates() end)) or 0,
        lipids = tonumber(safe(function() return n:getLipids() end)) or 0,
        proteins = tonumber(safe(function() return n:getProteins() end)) or 0 }
end

-- Calories this run should put on the table: burn until the next run + the gap to the pool target.
function BKCook.calorieNeed(player, run)
    local nut = BKCook.nutrition(player)
    if nut == nil then return nil, nil end
    local target = (nut.kg < BKCook.SAFE_KG) and BKCook.POOL_GAIN or BKCook.POOL_KEEP
    local covers = (run and run.covers) or 0.5
    local need = BKCook.DAILY_BURN * covers + target - nut.pool
    return math.max(0, need), nut, target
end

-- Meal count for a calorie need, given what one meal of this kitchen roughly holds.
function BKCook.mealsFor(need, perMeal)
    if need == nil then return BKCook.MEALS end
    perMeal = (perMeal and perMeal > 100) and perMeal or BKCook.MEAL_KCAL
    local n = math.ceil(need / perMeal)
    return math.max(BKCook.MIN_MEALS, math.min(BKCook.MAX_MEALS, n))
end

function BKCook.nutritionLine(nut, target)
    if nut == nil then return "nutrition unknown" end
    return string.format("weight %.1f kg (floor %d), calorie pool %d (target %d), carbs %d, fat %d, protein %d",
        nut.kg, BKCook.GOAL_KG, math.floor(nut.pool), target or 0, math.floor(nut.carbs), math.floor(nut.lipids),
        math.floor(nut.proteins))
end

-- Store -----------------------------------------------------------------------------------------------------

local function store()
    local d = ModData.getOrCreate(BKCook.MODDATA_KEY)
    -- v0.14.3: timed runs off by default, and switched off once on saves that had them on
    if d.autoOffV0143 ~= true then d.enabled = false; d.autoOffV0143 = true end
    if d.enabled == nil then d.enabled = false end
    if d.done == nil then d.done = {} end -- zone id -> date key of the last morning prep
    return d
end

-- The player is at the base: inside the zone rectangle (any floor) or within NEAR_TILES of it.
function BKCook.playerNear(zone, player)
    local x = tonumber(safe(function() return player:getX() end))
    local y = tonumber(safe(function() return player:getY() end))
    if x == nil or y == nil then return false end
    local m = BKCook.NEAR_TILES
    return x >= zone.x1 - m and x < zone.x2 + m and y >= zone.y1 - m and y < zone.y2 + m
end

function BKCook.isEnabled() return store().enabled ~= false end

function BKCook.setEnabled(on)
    store().enabled = on and true or false
    BKLog.info("breakfast prep " .. (on and "enabled" or "disabled"))
end

local function dateKey()
    local ok, key = pcall(function()
        local gt = getGameTime()
        return string.format("%d-%d-%d", gt:getYear(), gt:getMonth(), gt:getDay())
    end)
    return ok and key or tostring(os.date("%Y-%m-%d"))
end

-- Zone knowledge ----------------------------------------------------------------------------------------------

-- Water sources inside the zone: anything with water in it (rain collectors, sinks with water, barrels).
function BKCook.scanWater(zone)
    local out = {}
    local cell = getCell()
    for _, z in ipairs(BKZones.floors(zone)) do
    for x = zone.x1, zone.x2 - 1 do
        for y = zone.y1, zone.y2 - 1 do
            local sq = cell:getGridSquare(x, y, z)
            if sq then
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local obj = objs:get(i)
                    local has = safe(function() return obj.hasWater and obj:hasWater() end)
                    if has == true then
                        local amount = tonumber(safe(function() return obj:getFluidAmount() end)) or 0
                        if amount > 0 then
                            table.insert(out, {
                                obj = obj, amount = amount, x = x, y = y,
                                tainted = safe(function() return obj:isTaintedWater() end) == true,
                            })
                        end
                    end
                end
            end
        end
    end
    end
    -- clean water first, then the fullest
    table.sort(out, function(a, b)
        if a.tainted ~= b.tainted then return not a.tainted end
        return a.amount > b.amount
    end)
    return out
end

local function moveTo(item, dest)
    if dest == nil then return false end
    local src = safe(function() return item:getContainer() end)
    if src == dest then return true end
    if src then pcall(function() src:Remove(item) end) end
    pcall(function() dest:AddItem(item) end)
    return safe(function() return item:getContainer() end) == dest
end

local function ovens(scan)
    local out = {}
    for _, c in ipairs(scan.containers) do
        if BKCook.STOVES[c.ctype] and not c.locked and not c.personal then table.insert(out, c) end
    end
    table.sort(out, function(a, b) return BKCook.STOVES[a.ctype] < BKCook.STOVES[b.ctype] end)
    return out
end

local function stoveEntry(scan)
    local list = ovens(scan)
    local best = list[1]
    if best then
        best.alts = {}
        for i = 2, #list do table.insert(best.alts, list[i]) end
    end
    return best
end

-- v0.10.1 (Tanner: "always place it in the oven"): the chosen oven, else any other oven/stove in the zone.
-- Returns the entry it went into, or nil.
local function intoOven(item, stove)
    if stove == nil then return nil end
    local tries = { stove }
    for _, c in ipairs(stove.alts or {}) do table.insert(tries, c) end
    for _, c in ipairs(tries) do
        if moveTo(item, c.container) then return c end
    end
    return nil
end

local function isRotten(item) return safe(function() return item:isRotten() end) == true end

-- v0.10.1 (Tanner: "if one is already there no need to cook another"): a meal already waiting in any oven of the
-- zone = edible (not rotten) food with hunger in it. An empty or water-only pot is not food, so it does not count.
function BKCook.mealInOven(scan)
    for _, c in ipairs(ovens(scan)) do
        local items = safe(function() return c.container:getItems() end)
        for i = 0, (items and items:size() or 0) - 1 do
            local it = items:get(i)
            if instanceof(it, "Food") and not isRotten(it) and hungerValue(it) > 0 then
                return it, c
            end
        end
    end
    return nil
end

local function sourceContainers(scan)
    local list, lua = ArrayList.new(), {}
    for _, c in ipairs(scan.containers) do
        if not c.locked and not c.personal and not BKCook.NO_SOURCE[c.ctype] then
            list:add(c.container)
            table.insert(lua, c)
        end
    end
    return list, lua
end

-- base full type -> { minWater = n, recipes = {EvolvedRecipe...} }, built once from the loaded scripts
local baseIndex = nil
local function getBaseIndex()
    if baseIndex then return baseIndex end
    baseIndex = {}
    local ok, err = pcall(function()
        local all = getEvolvedRecipes()
        for i = 0, all:size() - 1 do
            local r = all:get(i)
            if safe(function() return r:isHidden() end) ~= true then
                local base = tostring(r:getBaseItem() or "")
                if base ~= "" then
                    if not string.find(base, ".", 1, true) then base = "Base." .. base end
                    local entry = baseIndex[base] or { minWater = 0, recipes = {} }
                    local mw = tonumber(safe(function() return r:getMinimumWater() end)) or 0
                    if mw > entry.minWater then entry.minWater = mw end
                    table.insert(entry.recipes, r)
                    baseIndex[base] = entry
                end
            end
        end
    end)
    if not ok then BKLog.warn("evolved recipe index failed: " .. tostring(err)) end
    local bases, recipes = 0, 0
    for _, e in pairs(baseIndex) do bases = bases + 1; recipes = recipes + #e.recipes end
    BKLog.info(string.format("evolved recipe index: %d recipes on %d base item types", recipes, bases))
    if bases == 0 then BKLog.warn("no evolved recipes found: breakfast prep cannot work") end
    return baseIndex
end

local function holdsWater(fc)
    if safe(function() return fc:isEmpty() end) == true then return true end
    if Fluid and Fluid.Water and safe(function() return fc:isPureFluid(Fluid.Water) end) == true then return true end
    if Fluid and Fluid.TaintedWater and safe(function() return fc:isPureFluid(Fluid.TaintedWater) end) == true then return true end
    return false
end

-- Fill a pot/bucket/mug from the zone's water. Returns true when the item ends up with water in it.
local function fillWithWater(item, waters, dry)
    local fc = safe(function() return item:getFluidContainer() end)
    if fc == nil then return false end
    if not holdsWater(fc) then return false end -- something else in it: leave it alone
    local free = tonumber(safe(function() return fc:getFreeCapacity() end)) or 0
    if free <= 0.001 then return true end
    for _, w in ipairs(waters) do
        local take = math.min(free, w.amount)
        if take > 0.001 then
            if dry then
                w.amount = w.amount - take
                return true
            end
            local ok, err = pcall(function() w.obj:transferFluidTo(fc, take) end)
            if ok then
                pcall(function() item:syncItemFields() end)
                w.amount = w.amount - take
                BKLog.dbg(string.format("filled %s with %.2f L from %s@%d,%d", displayName(item), take,
                    w.tainted and "tainted water" or "water", w.x, w.y))
                free = tonumber(safe(function() return fc:getFreeCapacity() end)) or 0
                if free <= 0.001 then return true end
            else
                BKLog.warn("fill failed: " .. tostring(err))
            end
        end
    end
    local amount = tonumber(safe(function() return fc:getAmount() end)) or 0
    return amount > 0.001
end

-- Ingredients -------------------------------------------------------------------------------------------------

-- Reason the item must not go into the meal, or nil when it may.
function BKCook.refuseReason(recipe, item, playerInv)
    if item == nil then return "nil" end
    if safe(function() return item:getContainer() end) == playerInv then return "in inventory" end
    if safe(function() return item:isFavorite() end) == true then return "favourite" end
    if BKCook.isCanned(item) then return "canned" end
    if instanceof(item, "Food") then
        if safe(function() return item:isRotten() end) == true then return "rotten" end
        if safe(function() return item:isBurnt() end) == true then return "burnt" end
        -- still thawing counts as frozen: the game clears the frozen flag only when freezingTime reaches 0
        if safe(function() return item:isFrozen() end) == true
                and safe(function() return recipe:isAllowFrozenItem() end) ~= true then
            return "frozen"
        end
        if safe(function() return item:haveExtraItems() end) == true then return "already a meal" end
    end
    if safe(function() return recipe:needToBeCooked(item) end) == false then return "needs cooking first" end
    return nil
end

-- v0.14.0: the keeper lists the ingredients itself. The game's getItemsCanBeUse is still asked and its answer taken as
-- is, but every Food in a source container whose type the recipe lists (recipe:getItemRecipe) is weighed too, with the
-- tests the game's checkItemCanBeUse applies (rotten, burnt and frozen out; a base already holding MaxItems takes no
-- more food; spices only when the game offered them or the base is a started meal the spice is not yet in, because
-- canAddSpicesEmpty has no getter) plus the keeper's own rules. In Tanner's kitchen the game's list came back with
-- spices only for days while the fridge held corn, radishes, onion and buns. Every pick is re-validated against the
-- game (getItemsCanBeUse on the inventory, exactly what ISAddItemInRecipe.isValid does) once it is in hand.
-- Returns usable, refused { reason -> n }, frozen { items the recipe would take once thawed }.
local function candidateIngredients(recipe, base, player, containerList, sources)
    local out, refused, frozen, seen = {}, {}, {}, {}
    local inv = player:getInventory()
    local function consider(it, fromGame)
        if it == nil or it == base then return end
        local id = itemId(it)
        if id and seen[id] then return end
        if id then seen[id] = true end
        if not fromGame and isSpice(it) then
            if safe(function() return recipe:isResultItem(base) end) ~= true
                    or safe(function() return recipe:isSpiceAdded(base, it) end) == true then
                return -- a spice the game did not offer: leave it to the game's rules
            end
        end
        local why = BKCook.refuseReason(recipe, it, inv)
        if why == "frozen" and instanceof(it, "Food") then table.insert(frozen, it) end
        if why then
            refused[why] = (refused[why] or 0) + 1
        else
            table.insert(out, it)
        end
    end
    local ok, err = pcall(function()
        local list = recipe:getItemsCanBeUse(player, base, containerList)
        if list == nil then return end
        for i = 0, list:size() - 1 do consider(list:get(i), true) end
    end)
    if not ok then BKLog.warn("getItemsCanBeUse failed: " .. tostring(err)) end
    local baseFull = false
    if safe(function() return base:haveExtraItems() end) == true then
        local n = tonumber(safe(function() return base:getExtraItems():size() end)) or 0
        local max = tonumber(safe(function() return recipe:getMaxItems() end)) or 0
        baseFull = n >= max
    end
    for _, c in ipairs(sources or {}) do
        local items = safe(function() return c.container:getItems() end)
        for i = 0, (items and items:size() or 0) - 1 do
            local it = items:get(i)
            if it ~= nil and instanceof(it, "Food") and safe(function() return recipe:getItemRecipe(it) end) ~= nil
                    and not (baseFull and not isSpice(it)) then
                consider(it, false)
            end
        end
    end
    return out, refused, frozen
end

-- Soonest-to-rot first, then the most filling; one of each type before repeats so a stew is not six carrots.
local function pickIngredients(recipe, candidates, used)
    local foods, spices = {}, {}
    for _, it in ipairs(candidates) do
        local id = itemId(it)
        if id == nil or not used[id] then
            if isSpice(it) then table.insert(spices, it) else table.insert(foods, it) end
        end
    end
    -- v0.10.0: food rotting within ROT_SOON_HOURS first (soonest first), then the most calories, then the most filling
    local function order(a, b)
        local ra, rb = hoursToRot(a), hoursToRot(b)
        local sa, sb = ra <= BKCook.ROT_SOON_HOURS, rb <= BKCook.ROT_SOON_HOURS
        if sa ~= sb then return sa end
        if sa and ra ~= rb then return ra < rb end
        local ka, kb = kcal(a), kcal(b)
        if ka ~= kb then return ka > kb end
        if ra ~= rb then return ra < rb end
        return hungerValue(a) > hungerValue(b)
    end
    table.sort(foods, order)
    table.sort(spices, order)
    local max = tonumber(safe(function() return recipe:getMaxItems() end)) or 0
    local picked, inPicked, seenType = {}, {}, {}
    for _, it in ipairs(foods) do
        if #picked >= max then break end
        local t = lower(it:getType())
        if not seenType[t] then
            seenType[t] = true
            table.insert(picked, it); inPicked[it] = true
        end
    end
    for _, it in ipairs(foods) do
        if #picked >= max then break end
        if not inPicked[it] then table.insert(picked, it); inPicked[it] = true end
    end
    local pickedSpices = {}
    for _, it in ipairs(spices) do
        if #pickedSpices >= BKCook.MAX_SPICES then break end
        table.insert(pickedSpices, it)
    end
    return picked, pickedSpices
end

-- Craft-window meals ---------------------------------------------------------------------------------------------

local craftIndex = nil

-- Item scripts of an InputScript/OutputScript -> { fullName -> true }, plus whether any is edible, and the names
local function itemScriptSet(list)
    local set, names, food = {}, {}, false
    if list then
        for i = 0, list:size() - 1 do
            local it = list:get(i)
            local full = tostring(safe(function() return it:getFullName() end) or "")
            if full ~= "" then
                set[full] = true
                table.insert(names, tostring(safe(function() return it:getDisplayName() end) or full))
                if (tonumber(safe(function() return it:getHungerChange() end)) or 0) < 0 then food = true end
            end
        end
    end
    return set, names, food
end

-- Every craft recipe in category Cooking that awards Cooking XP, with what it makes and what it takes:
--   kind "meal" = an output you can eat (hunger value), "step" = no edible output but another indexed recipe takes
--   the output (cake batter -> cake in a baking pan), "skip" = neither. Entries also know whether an edible output
--   is an evolved-recipe base (cake prep, pizza, bread dough), so kitchen ingredients can be added afterwards.
local function getCraftIndex()
    if craftIndex then return craftIndex end
    craftIndex = {}
    local cookingId = tostring(safe(function() return Perks.Cooking:getId() end) or "Cooking")
    local bases = getBaseIndex()
    local ok, err = pcall(function()
        local all = ScriptManager.instance:getAllCraftRecipes()
        for i = 0, all:size() - 1 do
            local r = all:get(i)
            local name = tostring(r:getName() or "")
            local category = tostring(safe(function() return r:getCategory() end) or "")
            local skip = BKCook.CRAFT_SKIP_NAMES[name] == true
            for _, pre in ipairs(BKCook.CRAFT_SKIP_PREFIX) do
                if string.sub(name, 1, #pre) == pre then skip = true; break end
            end
            local xp = 0
            local n = tonumber(safe(function() return r:getXPAwardCount() end)) or 0
            for a = 0, n - 1 do
                local award = r:getXPAward(a)
                if tostring(safe(function() return award:getPerk():getId() end)) == cookingId then
                    xp = xp + (tonumber(safe(function() return award:getAmount() end)) or 0)
                end
            end
            if category == "Cooking" and not skip and xp > 0 then
                local entry = { recipe = r, name = name, xp = xp, outputs = {}, outNames = {}, food = false,
                    evolvedBase = false, inputs = {}, next = {} }
                local outs = safe(function() return r:getOutputs() end)
                if outs then
                    for o = 0, outs:size() - 1 do
                        local script = outs:get(o)
                        if safe(function() return script:getResourceType() == ResourceType.Item end) == true then
                            local set, names, food = itemScriptSet(safe(function() return script:getPossibleResultItems() end))
                            for full in pairs(set) do
                                entry.outputs[full] = true
                                if food and bases[full] and bases[full].minWater == 0 then entry.evolvedBase = true end
                            end
                            for _, nm in ipairs(names) do table.insert(entry.outNames, nm) end
                            if food then entry.food = true end
                        end
                    end
                end
                local ins = safe(function() return r:getInputs() end)
                if ins then
                    for k = 0, ins:size() - 1 do
                        local script = ins:get(k)
                        if safe(function() return script:getResourceType() == ResourceType.Item end) == true then
                            local set = itemScriptSet(safe(function() return script:getPossibleInputItems() end))
                            table.insert(entry.inputs, { script = script, accepts = set })
                        end
                    end
                end
                -- a recipe whose outputs the game cannot name (item mappers) is taken as a meal: it is in Cooking
                -- and awards cooking XP, and the omelette is one of these
                local anyOut = false
                for _ in pairs(entry.outputs) do anyOut = true; break end
                if not anyOut then entry.food = true; entry.outNames = { "?" } end
                table.insert(craftIndex, entry)
            end
        end
        for _, entry in ipairs(craftIndex) do
            if not entry.food then
                for _, other in ipairs(craftIndex) do
                    if other ~= entry then
                        local takes = false
                        for _, input in ipairs(other.inputs) do
                            for full in pairs(entry.outputs) do
                                if input.accepts[full] then takes = true; break end
                            end
                            if takes then break end
                        end
                        if takes then table.insert(entry.next, other) end
                    end
                end
            end
            entry.kind = entry.food and "meal" or (#entry.next > 0 and "step" or "skip")
        end
    end)
    if not ok then BKLog.warn("craft recipe index failed: " .. tostring(err)) end
    local meals, steps, skipped = 0, 0, {}
    for _, e in ipairs(craftIndex) do
        if e.kind == "meal" then meals = meals + 1
        elseif e.kind == "step" then steps = steps + 1
        else table.insert(skipped, e.name) end
    end
    BKLog.info(string.format("craft recipe index: %d cooking recipes that award cooking XP: %d meals, %d steps toward a meal, %d with nothing edible to make from them%s",
        #craftIndex, meals, steps, #skipped, #skipped > 0 and (" (" .. table.concat(skipped, ", ") .. ")") or ""))
    return craftIndex
end

-- The craft window needs a surface for AnySurfaceCraft recipes: one near the player, else the stove or a counter.
local function craftSurface(logic, player, scan, stove)
    local obj = safe(function() return logic:findCraftSurface(player, 2) end)
    if obj then return obj end
    if stove and stove.obj then return stove.obj end
    for _, c in ipairs(scan.containers) do
        if c.ctype == "counter" and c.obj then return c.obj end
    end
    return nil
end

local function newLogic(player, recipe, containerList, surface)
    local logic = HandcraftLogic.new(player, nil, nil)
    if surface then logic:setIsoObject(surface) end
    logic:setContainers(containerList)
    logic:setRecipe(recipe)
    return logic
end

local function listToTable(list)
    local out = {}
    if list then for i = 0, list:size() - 1 do table.insert(out, list:get(i)) end end
    return out
end

-- Reason a craft recipe must not run with the inputs the game picked, or nil.
-- mustUse: when set ({ id -> true }), the picked inputs have to include one of those items (a chain step).
local function craftRefuseReason(entry, logic, player, usedIds, mustUse)
    if safe(function() return entry.recipe:needToBeLearn() end) == true
            and safe(function() return CraftRecipeManager.hasPlayerLearnedRecipe(entry.recipe, player) end) ~= true then
        return "not learned"
    end
    if safe(function() return logic:canPerformCurrentRecipe() end) ~= true then return "cannot perform" end
    local data = logic:getRecipeData()
    local consumed = listToTable(safe(function() return data:getAllNotKeepInputItems() end))
    local all = listToTable(safe(function() return data:getAllInputItems() end))
    if #all == 0 then return "no inputs" end
    local usesMust = false
    for _, it in ipairs(all) do
        local id = itemId(it)
        if id and usedIds[id] then return "ingredient already taken" end
        if id and mustUse and mustUse[id] then usesMust = true end
        if safe(function() return it:isFavorite() end) == true then return "favourite input" end
    end
    if mustUse and not usesMust then return "does not use what was just made" end
    for _, it in ipairs(consumed) do
        if BKCook.isCanned(it) then return "canned input" end
        if instanceof(it, "Food") and safe(function() return it:isRotten() end) == true then return "rotten input" end
        if safe(function() return it:getContainer() end) == player:getInventory() then return "input in inventory" end
    end
    return nil
end

-- For a "step" recipe: the first follow-on recipe whose other inputs the kitchen already satisfies, or nil.
local function viableNext(entry, player, containerList, surface)
    for _, other in ipairs(entry.next) do
        local okAll = safe(function()
            local logic = newLogic(player, other.recipe, containerList, surface)
            for _, input in ipairs(other.inputs) do
                local fromStep = false
                for full in pairs(entry.outputs) do
                    if input.accepts[full] then fromStep = true; break end
                end
                if not fromStep and logic:isInputSatisfied(input.script) ~= true then return false end
            end
            return true
        end)
        if okAll == true then return other end
    end
    return nil
end

-- Up to `slots` craft meals the kitchen can make right now, meals before steps, best cooking XP first, no shared
-- inputs. mustUse (optional, { id -> true }) restricts picks to recipes that take one of those items.
-- Returns picks, refused (recipe name -> reason, "cannot perform" left out), performable count.
function BKCook.planCraft(zone, player, scan, containerList, stove, slots, usedIds, mustUse)
    local picks, refused = {}, {}
    if slots <= 0 then return picks, refused, 0 end
    local index = getCraftIndex()
    local surface = nil
    local cands = {}
    for _, entry in ipairs(index) do
        if entry.kind ~= "skip" then
            local ok, err = pcall(function()
                local logic = newLogic(player, entry.recipe, containerList, nil)
                if surface == nil then surface = craftSurface(logic, player, scan, stove) end
                if surface then logic:setIsoObject(surface); logic:setRecipe(entry.recipe) end
                local why = craftRefuseReason(entry, logic, player, usedIds, mustUse)
                if why == nil and entry.kind == "step" then
                    local nxt = viableNext(entry, player, containerList, surface)
                    if nxt == nil then
                        why = "makes " .. table.concat(entry.outNames, "/") .. " but nothing here could finish it"
                    else
                        entry.via = nxt
                    end
                end
                if why then
                    if why ~= "cannot perform" then refused[entry.name] = why end
                else
                    local data = logic:getRecipeData()
                    local consumed = listToTable(data:getAllNotKeepInputItems())
                    local k = 0
                    for _, it in ipairs(consumed) do k = k + kcal(it) end
                    table.insert(cands, {
                        entry = entry, logic = logic, surface = surface,
                        inputs = listToTable(data:getAllInputItems()),
                        consumed = consumed, kcal = k,
                    })
                end
            end)
            if not ok then BKLog.warn("craft check failed for " .. entry.name .. ": " .. tostring(err)) end
        end
    end
    if #cands == 0 then
        local near = safe(function() return HandcraftLogic.new(player, nil, nil):findCraftSurface(player, 2) end)
        if near == nil then
            refused["every craft recipe"] = "no craft surface within 2 tiles of you (stand by a table or counter)"
        elseif safe(function() return player:tooDarkToRead() end) == true then
            refused["every craft recipe"] = "too dark to craft (needs daylight or a light)"
        end
    end
    table.sort(cands, function(a, b)
        if a.entry.food ~= b.entry.food then return a.entry.food end
        if (a.kcal or 0) ~= (b.kcal or 0) then return (a.kcal or 0) > (b.kcal or 0) end -- v0.10.0: calories first
        if a.entry.xp ~= b.entry.xp then return a.entry.xp > b.entry.xp end
        return #a.consumed > #b.consumed
    end)
    local taken = {}
    for _, cand in ipairs(cands) do
        if #picks >= slots then break end
        local clash = false
        for _, it in ipairs(cand.inputs) do
            local id = itemId(it)
            if id and (taken[id] or usedIds[id]) then clash = true; break end
        end
        if not clash then
            for _, it in ipairs(cand.inputs) do local id = itemId(it); if id then taken[id] = true end end
            table.insert(picks, cand)
        end
    end
    return picks, refused, #cands
end

-- What a craft pick makes, for the plan log
local function craftOutcome(cand)
    local e = cand.entry
    local out = "makes " .. table.concat(e.outNames, "/")
    if e.kind == "step" and e.via then out = out .. ", then " .. e.via.name end
    if e.evolvedBase then out = out .. ", then kitchen ingredients go in" end
    return out
end

local function craftSummary(cand)
    local counts, order = {}, {}
    for _, it in ipairs(cand.consumed) do
        local n = displayName(it)
        if not counts[n] then counts[n] = 0; table.insert(order, n) end
        counts[n] = counts[n] + 1
    end
    local parts = {}
    for _, n in ipairs(order) do table.insert(parts, counts[n] > 1 and (n .. " x" .. counts[n]) or n) end
    return table.concat(parts, ", ")
end

-- Planning ------------------------------------------------------------------------------------------------------

-- Returns { meals = {...}, stove = entry|nil, waters = {...}, notes = {...} }. dry = true never fills a pot.
function BKCook.plan(zone, player, dry, count)
    count = count or BKCook.MEALS
    local scan = BKZoneScan.scan(zone)
    local containerList, sources = sourceContainers(scan)
    local stove = stoveEntry(scan)
    local waters = BKCook.scanWater(zone)
    local index = getBaseIndex()
    local notes = {}
    local candidates = {}
    local filled = 0
    local basesSeen, itemsSeen = 0, 0

    for _, c in ipairs(sources) do
        local items = safe(function() return c.container:getItems() end)
        if items then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                itemsSeen = itemsSeen + 1
                local full = tostring(safe(function() return item:getFullType() end) or "")
                local entry = index[full]
                if entry then basesSeen = basesSeen + 1 end
                if entry and safe(function() return item:isFavorite() end) ~= true then
                    local ready = true
                    if entry.minWater > 0 then
                        if filled >= count then
                            ready = false
                        else
                            ready = fillWithWater(item, waters, dry)
                            if ready then filled = filled + 1 else table.insert(notes, displayName(item) .. ": no water for it") end
                        end
                    end
                    if ready then
                        -- the recipe code wants the water in the pot; a dry run never fills it, so it checks the
                        -- recipes from the script index instead and says so
                        local recipes = {}
                        local fc = safe(function() return item:getFluidContainer() end)
                        local dryEmpty = dry and entry.minWater > 0 and fc ~= nil
                            and (tonumber(safe(function() return fc:getAmount() end)) or 0) < entry.minWater
                        if dryEmpty then
                            recipes = entry.recipes
                            table.insert(notes, displayName(item) .. " @" .. c.x .. "," .. c.y
                                .. ": would be filled first (dry run), recipes taken from the scripts")
                        else
                            local list = safe(function()
                                return RecipeManager.getEvolvedRecipe(item, player, containerList, true)
                            end)
                            if list ~= nil then
                                for r = 0, list:size() - 1 do table.insert(recipes, list:get(r)) end
                            end
                        end
                        if #recipes == 0 then
                            local frozenBase = instanceof(item, "Food") and safe(function() return item:isFrozen() end) == true
                            table.insert(notes, displayName(item) .. (frozenBase
                                and ": frozen, no recipe takes a frozen base (thaw it first)"
                                or ": no recipe possible with what is in the zone"))
                        else
                            for _, recipe in ipairs(recipes) do
                                if safe(function() return recipe:isResultItem(item) end) ~= true
                                        and safe(function() return recipe:isHidden() end) ~= true then
                                    local cands, refused, frozenList = candidateIngredients(recipe, item, player, containerList, sources)
                                    table.insert(candidates, {
                                        base = item, src = c, recipe = recipe, cands = cands, refused = refused, frozen = frozenList,
                                        name = tostring(safe(function() return recipe:getUntranslatedName() end) or "?"),
                                        cookable = safe(function() return recipe:isCookable() end) == true,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- greedy: best meal first, then the best of what is left, preferring a different recipe for variety
    local used, meals, lastName = {}, {}, nil
    for _ = 1, count do
        local best, bestScore, bestPick, bestSpice = nil, 0, nil, nil
        for _, cand in ipairs(candidates) do
            local baseId = itemId(cand.base)
            if baseId == nil or not used[baseId] then
                local picked, spices = pickIngredients(cand.recipe, cand.cands, used)
                if #picked > 0 then
                    -- v0.10.0: calories decide (per 100 kcal), ingredient count and variety break ties
                    local k, urgent = 0, 0
                    for _, it in ipairs(picked) do
                        k = k + kcal(it)
                        if hoursToRot(it) <= BKCook.ROT_SOON_HOURS then urgent = urgent + 1 end
                    end
                    -- v0.14.0: a meal that uses up food about to turn beats a richer one that does not
                    local score = k / 100 + #picked * 0.2 + urgent * BKCook.URGENT_BONUS
                        + (cand.cookable and 0.5 or 0) + (cand.name ~= lastName and 0.4 or 0)
                    if score > bestScore then best, bestScore, bestPick, bestSpice = cand, score, picked, spices end
                end
            end
        end
        if best == nil then break end
        local baseId = itemId(best.base)
        if baseId then used[baseId] = true end
        for _, it in ipairs(bestPick) do local id = itemId(it); if id then used[id] = true end end
        for _, it in ipairs(bestSpice) do local id = itemId(it); if id then used[id] = true end end
        local mk = 0
        for _, it in ipairs(bestPick) do mk = mk + kcal(it) end
        for _, it in ipairs(bestSpice) do mk = mk + kcal(it) end
        table.insert(meals, { cand = best, picked = bestPick, spices = bestSpice, kcal = mk })
        lastName = best.name
    end

    if basesSeen == 0 then
        table.insert(notes, string.format("no pot/bowl/other recipe base among %d items in %d zone containers", itemsSeen, #sources))
    end
    if #waters == 0 then table.insert(notes, "no water source inside the zone") end
    if #meals == 0 then
        -- say what every base/recipe pair had, so an empty morning explains itself
        table.insert(notes, string.format("%d items in %d containers, %d recipe bases, %d base/recipe pairs, %d pots filled",
            itemsSeen, #sources, basesSeen, #candidates, filled))
        for _, cand in ipairs(candidates) do
            local foods, spices = 0, 0
            for _, it in ipairs(cand.cands) do if isSpice(it) then spices = spices + 1 else foods = foods + 1 end end
            local parts = {}
            for why, n in pairs(cand.refused) do table.insert(parts, why .. " " .. n) end
            table.insert(notes, string.format("%s/%s @%d,%d: %d usable food, %d spice, max %s, skipped: %s", cand.name,
                displayName(cand.base), cand.src.x, cand.src.y, foods, spices,
                tostring(safe(function() return cand.recipe:getMaxItems() end)),
                #parts > 0 and table.concat(parts, ", ") or "none"))
        end
    end

    local craft, craftRefused, craftCount = {}, {}, 0
    if dry and count - #meals > 0 then
        craft, craftRefused, craftCount = BKCook.planCraft(zone, player, scan, containerList, stove, count - #meals, used)
    end

    return { count = count, meals = meals, stove = stove, waters = waters, notes = notes, candidates = candidates, scan = scan,
        containerList = containerList, sources = sources, used = used, craft = craft, craftRefused = craftRefused,
        craftCount = craftCount }
end

local function ingredientSummary(meal)
    local counts, order = {}, {}
    for _, list in ipairs({ meal.picked, meal.spices }) do
        for _, it in ipairs(list) do
            local n = displayName(it)
            if not counts[n] then counts[n] = 0; table.insert(order, n) end
            counts[n] = counts[n] + 1
        end
    end
    local parts = {}
    for _, n in ipairs(order) do
        table.insert(parts, counts[n] > 1 and (n .. " x" .. counts[n]) or n)
    end
    return table.concat(parts, ", ")
end

-- true/false for an IsoStove (stove, microwave), nil for anything without an on/off state.
local function stoveOn(stove)
    local obj = stove and stove.obj
    if obj == nil or type(obj.Activated) ~= "function" then return nil end
    return safe(function() return obj:Activated() end) == true
end

local function stoveLabel(stove)
    local on = stoveOn(stove)
    local state = on == nil and "" or (on and " (ON)" or " (off)")
    return stove.ctype .. " @" .. stove.x .. "," .. stove.y .. state
end

function BKCook.currentRun()
    local hour = tonumber(safe(function() return getGameTime():getHour() end)) or 12
    for _, r in ipairs(BKCook.RUNS) do
        if hour >= r.from and hour < r.to then return r end
    end
    return hour < BKCook.RUNS[2].from and BKCook.RUNS[1] or BKCook.RUNS[2]
end

function BKCook.logPlan(zone, player)
    local run = BKCook.currentRun()
    local need, nut, target = BKCook.calorieNeed(player, run)
    local count = BKCook.mealsFor(need, nil)
    local p = BKCook.plan(zone, player, true, count)
    BKLog.info(string.format("%s plan for zone %s: %s; need ~%s kcal -> %d meal(s) planned, %d found", run.label,
        tostring(zone.id), BKCook.nutritionLine(nut, target), need and tostring(math.floor(need)) or "?", count, #p.meals))
    BKLog.info(string.format("  stove %s, %d water source(s)",
        p.stove and stoveLabel(p.stove) or "NONE (pots stay where they are)", #p.waters))
    for _, w in ipairs(p.waters) do
        BKLog.info(string.format("  water: %.1f L%s @%d,%d", w.amount, w.tainted and " (tainted)" or "", w.x, w.y))
    end
    for i, m in ipairs(p.meals) do
        BKLog.info(string.format("  meal %d: %s from %s @%d,%d (%d ingredients%s, ~%d kcal): %s", i, m.cand.name,
            displayName(m.cand.base), m.cand.src.x, m.cand.src.y, #m.picked,
            #m.spices > 0 and (" + " .. #m.spices .. " spice") or "", math.floor(m.kcal or 0), ingredientSummary(m)))
    end
    for _, cand in ipairs(p.candidates) do
        local parts = {}
        for why, n in pairs(cand.refused) do table.insert(parts, why .. " " .. n) end
        if #parts > 0 then
            BKLog.info(string.format("  %s/%s skipped ingredients: %s", cand.name, displayName(cand.base), table.concat(parts, ", ")))
        end
    end
    for _, n in ipairs(p.notes) do BKLog.info("  note: " .. n) end
    -- v0.14.0: what the freezer could feed once thawed, and what is thawing right now
    local thaw = BKCook.THAW_AHEAD and BKCook.thawCandidates(p) or {}
    if #thaw > 0 then
        local k = 0
        for _, it in ipairs(thaw) do k = k + kcal(it) end
        BKLog.info(string.format("  frozen but usable once thawed: %s (~%d kcal); a run moves up to %d of them to the fridge, ~%d h to thaw",
            BKCook.namesOf(thaw), math.floor(k), BKCook.THAW_MAX_ITEMS, BKCook.THAW_HOURS_FRIDGE))
    end
    local thawing = BKCook.thawing(p)
    if #thawing > 0 then
        local parts = {}
        for _, t in ipairs(thawing) do table.insert(parts, string.format("%s (~%.1f h)", displayName(t.item), t.hours)) end
        BKLog.info("  thawing now: " .. table.concat(parts, ", "))
    end
    for i, cand in ipairs(p.craft) do
        BKLog.info(string.format("  craft meal %d: %s (cooking XP %d, ~%d kcal in, %s): %s", #p.meals + i, cand.entry.name,
            cand.entry.xp, math.floor(cand.kcal or 0), craftOutcome(cand), craftSummary(cand)))
    end
    if count - #p.meals > 0 then
        BKLog.info(string.format("  craft recipes performable now: %d, picked %d", p.craftCount, #p.craft))
        for name, why in pairs(p.craftRefused) do BKLog.info("  craft " .. name .. " skipped: " .. why) end
    end
    if #p.meals == 0 and #p.craft == 0 then BKLog.info("  nothing to prep: no pot/bowl meal and no craft-window meal possible") end
end

-- v0.14.1 diagnostics (Tanner 2026-11-08: pots still "0 usable food" after the own scan): what the game itself
-- knows about the first pot/bowl base and the cold-storage food, so one paste of the console settles where the
-- ingredient list breaks (recipe item map, item types, getItemsCanBeUse per container).
function BKCook.logDiagnostics(zone, player)
    local scan = BKZoneScan.scan(zone)
    local containerList, sources = sourceContainers(scan)
    local index = getBaseIndex()
    local base, baseSrc = nil, nil
    for _, c in ipairs(sources) do
        local items = safe(function() return c.container:getItems() end)
        for i = 0, (items and items:size() or 0) - 1 do
            local it = items:get(i)
            local full = tostring(safe(function() return it:getFullType() end) or "")
            if index[full] and (base == nil or full == "Base.Pot") then base, baseSrc = it, c end
        end
    end
    if base == nil then BKLog.info("diag: no recipe base (pot, bowl, pan...) in any zone container"); return end
    BKLog.info(string.format("diag: base %s (%s) in %s @%d,%d, fluid %s L, %d containers in the list", displayName(base),
        tostring(base:getFullType()), baseSrc.ctype, baseSrc.x, baseSrc.y,
        tostring(safe(function() return base:getFluidContainer():getAmount() end)), containerList:size()))
    local recipes = {}
    local list = safe(function() return RecipeManager.getEvolvedRecipe(base, player, containerList, true) end)
    if list then for r = 0, list:size() - 1 do table.insert(recipes, list:get(r)) end end
    if #recipes == 0 then
        for _, r in ipairs((index[tostring(base:getFullType())] or {}).recipes or {}) do table.insert(recipes, r) end
        BKLog.info("diag: RecipeManager.getEvolvedRecipe accepted no recipe for it; the script index is used instead")
    end
    for ri, recipe in ipairs(recipes) do
        if ri > 2 then break end
        local map = safe(function() return recipe:getItemsList() end)
        local n = map and tonumber(safe(function() return map:size() end)) or -1
        local keys = {}
        pcall(function()
            local all = recipe:getPossibleItems() -- ArrayList<ItemRecipe>
            for k = 0, math.min(all:size(), 12) - 1 do table.insert(keys, tostring(all:get(k):getName())) end
        end)
        BKLog.info(string.format("diag: recipe name=%s untranslated=%s original=%s base=%s max=%s itemsList=%d keys: %s",
            tostring(recipe:getName()), tostring(recipe:getUntranslatedName()),
            tostring(safe(function() return recipe:getOriginalname() end)), tostring(recipe:getBaseItem()),
            tostring(recipe:getMaxItems()), n, #keys > 0 and table.concat(keys, ", ") or "(could not iterate)"))
        local game = safe(function() return recipe:getItemsCanBeUse(player, base, containerList) end)
        BKLog.info(string.format("diag:   getItemsCanBeUse with all %d containers: %d item(s)", containerList:size(), game and game:size() or -1))
        for _, c in ipairs(sources) do
            if c.ctype == "fridge" or c.ctype == "freezer" or c.ctype == "counter" then
                local one = ArrayList.new()
                one:add(c.container)
                local g1 = safe(function() return recipe:getItemsCanBeUse(player, base, one) end)
                local names = {}
                if g1 then for k = 0, math.min(g1:size(), 6) - 1 do table.insert(names, displayName(g1:get(k))) end end
                BKLog.info(string.format("diag:   with the %s @%d,%d alone: %d item(s) %s", c.ctype, c.x, c.y, g1 and g1:size() or -1,
                    table.concat(names, ", ")))
            end
        end
        local shown = 0
        for _, c in ipairs(sources) do
            local items = safe(function() return c.container:getItems() end)
            for i = 0, (items and items:size() or 0) - 1 do
                local it = items:get(i)
                if shown < 10 and (c.ctype == "fridge" or c.ctype == "freezer") and instanceof(it, "Food") and not isSpice(it) then
                    shown = shown + 1
                    local okIR, ir = pcall(function() return recipe:getItemRecipe(it) end)
                    local evo = {}
                    pcall(function()
                        local l = it:getScriptItem():getEvolvedRecipe()
                        for k = 0, l:size() - 1 do table.insert(evo, tostring(l:get(k))) end
                    end)
                    local inMap = map and safe(function() return map:containsKey(it:getType()) end)
                    BKLog.info(string.format("diag:   %s type=%s full=%s getItemRecipe=%s use=%s mapHasType=%s frozen=%s ft=%s rotten=%s noRecipes=%s needToBeCooked=%s script=%s",
                        displayName(it), tostring(it:getType()), tostring(it:getFullType()),
                        okIR and tostring(ir ~= nil) or ("ERR " .. tostring(ir)),
                        (okIR and ir) and tostring(safe(function() return ir:getUse() end)) or "-",
                        tostring(inMap), tostring(safe(function() return it:isFrozen() end)),
                        tostring(safe(function() return it:getFreezingTime() end)), tostring(safe(function() return it:isRotten() end)),
                        tostring(safe(function() return it:isNoRecipes(player) end)),
                        tostring(safe(function() return recipe:needToBeCooked(it) end)), table.concat(evo, ";")))
                end
            end
        end
    end
end

-- Doing ---------------------------------------------------------------------------------------------------------

local function refreshSprite(entry)
    if entry and entry.obj and ItemPicker and ItemPicker.updateOverlaySprite then
        pcall(ItemPicker.updateOverlaySprite, entry.obj)
    end
end

-- v0.14.0 thaw-ahead ----------------------------------------------------------------------------------------------

function BKCook.namesOf(list)
    local counts, order = {}, {}
    for _, it in ipairs(list) do
        local n = displayName(it)
        if not counts[n] then counts[n] = 0; table.insert(order, n) end
        counts[n] = counts[n] + 1
    end
    local parts = {}
    for _, n in ipairs(order) do table.insert(parts, counts[n] > 1 and (n .. " x" .. counts[n]) or n) end
    return table.concat(parts, ", ")
end

local function isThawing(item)
    return safe(function() return item:isThawing() end) == true
end

-- Frozen food some recipe of the zone would take and that still sits frozen solid in a freezer, best calories first
-- (frozen food does not age, so there is no "soonest to rot" among these).
function BKCook.thawCandidates(plan)
    local out, seen = {}, {}
    for _, cand in ipairs(plan.candidates or {}) do
        for _, it in ipairs(cand.frozen or {}) do
            local id = itemId(it)
            if id and not seen[id] and not (plan.used or {})[id] and not isThawing(it) then
                seen[id] = true
                table.insert(out, it)
            end
        end
    end
    table.sort(out, function(a, b)
        local ka, kb = kcal(a), kcal(b)
        if ka ~= kb then return ka > kb end
        return hungerValue(a) > hungerValue(b)
    end)
    return out
end

-- Food on its way from frozen to usable (out of the freezer, freezingTime not yet 0): { item, hours } with the fridge
-- hours it still needs.
function BKCook.thawing(plan)
    local out, seen = {}, {}
    for _, cand in ipairs(plan.candidates or {}) do
        for _, it in ipairs(cand.frozen or {}) do
            local id = itemId(it)
            if id and not seen[id] and isThawing(it) then
                seen[id] = true
                local ft = tonumber(safe(function() return it:getFreezingTime() end)) or 100
                table.insert(out, { item = it, hours = ft / 100 * BKCook.THAW_HOURS_FRIDGE })
            end
        end
    end
    return out
end

-- Calories of unfrozen food the pots could take right now that this plan did not use.
local function spareKcal(plan)
    local k, seen = 0, {}
    for _, cand in ipairs(plan.candidates or {}) do
        for _, it in ipairs(cand.cands or {}) do
            local id = itemId(it)
            if id and not seen[id] and not (plan.used or {})[id] and not isSpice(it) then
                seen[id] = true
                k = k + kcal(it)
            end
        end
    end
    return k
end

-- The powered fridge nearest the stove.
local function thawFridge(plan)
    local best, bestD = nil, nil
    for _, c in ipairs(plan.scan.containers) do
        if c.ctype == "fridge" and c.powered and not c.locked and not c.personal then
            local d = plan.stove and (math.abs(c.x - plan.stove.x) + math.abs(c.y - plan.stove.y)) or 0
            if best == nil or d < bestD then best, bestD = c, d end
        end
    end
    return best
end

-- Moves frozen food into the zone's powered fridge so it is thawed in about THAW_HOURS_FRIDGE. wantKcal = calories
-- still to cover; what already lies thawed or is thawing counts first, so retries never pull more out. The items are
-- marked (modData BKThaw = world hour) so the sorter leaves them alone (BKPlanner.THAW_HOLD_HOURS).
-- Returns moved items, their calories, and a reason when nothing could be done.
function BKCook.thawAhead(plan, wantKcal, forLabel)
    local fridge = thawFridge(plan)
    if fridge == nil then return {}, 0, "no powered fridge in the zone to thaw in" end
    local have = spareKcal(plan)
    for _, t in ipairs(BKCook.thawing(plan)) do have = have + kcal(t.item) end
    local moved, got = {}, 0
    if have >= (wantKcal or 0) then return moved, 0, nil end
    for _, it in ipairs(BKCook.thawCandidates(plan)) do
        if #moved >= BKCook.THAW_MAX_ITEMS or have + got >= wantKcal then break end
        if moveTo(it, fridge.container) then
            pcall(function() it:getModData().BKThaw = tonumber(getGameTime():getWorldAgeHours()) end)
            table.insert(moved, it)
            got = got + kcal(it)
        end
    end
    if #moved > 0 then
        refreshSprite(fridge)
        pcall(function() fridge.container:setHasBeenLooted(true) end)
        BKLog.info(string.format("  thawing for %s: %s (~%d kcal) -> fridge @%d,%d, ready in ~%d h", tostring(forLabel),
            BKCook.namesOf(moved), math.floor(got), fridge.x, fridge.y, BKCook.THAW_HOURS_FRIDGE))
    end
    return moved, got, nil
end

-- Container to container, the same calls the sorter uses. Returns true when the item ended up in dest.

-- Preps one meal: base and each ingredient go through the player's inventory (as the vanilla menu does), the vanilla
-- recipe call adds them, leftovers of partly used ingredients go back where they came from, and the finished pot
-- goes into the stove (or back to its source).
local function prepMeal(meal, player, stove)
    local inv = player:getInventory()
    local cand, recipe = meal.cand, meal.cand.recipe
    local base = cand.base
    local baseSrc = cand.src.container
    local xpBefore = tonumber(safe(function() return player:getXp():getXP(Perks.Cooking) end))
    if not moveTo(base, inv) then return nil, "could not take " .. displayName(base) end
    local added, failed, refused = 0, 0, 0
    local function addOne(ing)
        local src = safe(function() return ing:getContainer() end)
        if not moveTo(ing, inv) then failed = failed + 1; return end
        -- v0.14.0: the game's own check on the item in hand (ISAddItemInRecipe.isValid does exactly this)
        local okV, valid = pcall(function() return recipe:getItemsCanBeUse(player, base, nil):contains(ing) end)
        if okV and valid == false then
            refused = refused + 1
            BKLog.info("  game refused " .. displayName(ing) .. " for " .. tostring(cand.name) .. " once in hand: put back")
            if src then moveTo(ing, src) end
            return
        end
        if instanceof(ing, "Food") then pcall(function() ing:setChef(player:getUsername()) end) end
        local ok, res = pcall(function() return recipe:addItem(base, ing, player) end)
        if ok and res ~= nil then
            base = res
            added = added + 1
            if ISAddItemInRecipe and ISAddItemInRecipe.checkName then
                pcall(ISAddItemInRecipe.checkName, base, recipe)
                pcall(ISAddItemInRecipe.checkTemperature, base, ing, recipe)
            end
        else
            failed = failed + 1
            BKLog.warn("addItem failed for " .. displayName(ing) .. ": " .. tostring(res))
        end
        -- a partly used ingredient (half a cabbage) is still in the inventory: back to its shelf
        if safe(function() return ing:getContainer() end) == inv and src then
            if not moveTo(ing, src) then BKLog.warn("could not return " .. displayName(ing) .. " to its container") end
            refreshSprite({ obj = safe(function() return src:getParent() end) })
        end
    end
    for _, ing in ipairs(meal.picked) do addOne(ing) end
    for _, ing in ipairs(meal.spices) do addOne(ing) end
    refreshSprite(cand.src)

    local dest = baseSrc
    local where = cand.src.ctype .. " @" .. cand.src.x .. "," .. cand.src.y .. " (no oven in the zone)"
    local oven = intoOven(base, stove)
    if oven then
        dest, stove = oven.container, oven
        where = oven.ctype .. " @" .. oven.x .. "," .. oven.y
    elseif moveTo(base, baseSrc) then
        if stove then where = cand.src.ctype .. " @" .. cand.src.x .. "," .. cand.src.y .. " (every oven refused it)" end
    else
        where = "PLAYER INVENTORY (no container would take it)"
    end
    refreshSprite(stove)
    pcall(function() dest:setHasBeenLooted(true) end)
    local xpAfter = tonumber(safe(function() return player:getXp():getXP(Perks.Cooking) end))
    local xp = (xpBefore and xpAfter) and (xpAfter - xpBefore) or nil
    return {
        name = displayName(base), recipe = cand.name, added = added, failed = failed, refused = refused, where = where,
        xp = xp, summary = ingredientSummary(meal),
    }
end

-- Which picked items fill which input slot, read off the planning logic before anything moves.
local function manualInputsOf(cand)
    local map = {}
    local inputs = safe(function() return cand.entry.recipe:getInputs() end)
    if not inputs then return map end
    for i = 0, inputs:size() - 1 do
        local script = inputs:get(i)
        if safe(function() return script:getResourceType() == ResourceType.Item end) == true then
            local items = safe(function() return cand.logic:getSatisfiedInputInventoryItems(script) end)
            if items and items:size() > 0 then
                local list = ArrayList.new()
                for k = 0, items:size() - 1 do list:add(items:get(k)) end
                table.insert(map, { script = script, items = list })
            end
        end
    end
    return map
end

-- Makes one craft-window meal the way the craft window does. The game's perform step insists the player is within
-- reach of every container it was given, so the inputs go into the player's inventory and a fresh logic runs on
-- that inventory alone, told exactly which items to use (manual inputs, as the craft window sends them). Then
-- performCurrentRecipe, OnCreate, destroy/used processing; outputs to the stove, kept tools and leftovers back.
local function craftMeal(cand, player, stove)
    local inv = player:getInventory()
    local recipe = cand.entry.recipe
    local xpBefore = tonumber(safe(function() return player:getXp():getXP(Perks.Cooking) end))
    local manual = manualInputsOf(cand)
    local srcOf, moved = {}, {}
    local function putBack()
        for it, src in pairs(srcOf) do
            if safe(function() return it:getContainer() end) == inv then moveTo(it, src) end
            refreshSprite({ obj = safe(function() return src:getParent() end) })
        end
    end
    for _, it in ipairs(cand.inputs) do
        local src = safe(function() return it:getContainer() end)
        if src ~= inv then
            if not moveTo(it, inv) then putBack(); return nil, "could not take " .. displayName(it) end
            srcOf[it] = src
        end
        moved[it] = true
    end
    local containers = ArrayList.new()
    containers:add(inv)
    local logic = HandcraftLogic.new(player, nil, cand.surface)
    logic:setContainers(containers)
    logic:setRecipe(recipe)
    if #manual > 0 then
        logic:setManualSelectInputs(true)
        logic:clearManualInputs()
        for _, m in ipairs(manual) do
            if safe(function() return logic:setManualInputsFor(m.script, m.items) end) ~= true then
                putBack()
                return nil, "the game would not take the chosen " .. displayName(m.items:get(0))
            end
        end
    end
    safe(function() return logic:canPerformCurrentRecipe() end) -- first call applies the manual inputs (vanilla does the same)
    if safe(function() return logic:canPerformCurrentRecipe() end) ~= true then
        putBack()
        return nil, "recipe not performable once the inputs were in hand"
    end
    local data = logic:getRecipeData()
    cand.inputs = listToTable(data:getAllInputItems())
    cand.consumed = listToTable(data:getAllNotKeepInputItems())
    for _, it in ipairs(cand.inputs) do
        if not moved[it] then
            putBack()
            return nil, "the game reached for your own " .. displayName(it) .. " instead of the kitchen's"
        end
    end
    local summary = craftSummary(cand)
    local okPerform, performed = pcall(function() return logic:performCurrentRecipe() end)
    if not okPerform or performed ~= true then
        putBack()
        return nil, "performCurrentRecipe refused" .. (okPerform and "" or (": " .. tostring(performed)))
    end
    local outputs = ArrayList.new()
    pcall(function() logic:getCreatedOutputItems(outputs) end)
    local outs = listToTable(outputs)
    for _, it in ipairs(outs) do
        pcall(function() if not inv:contains(it) then inv:AddItem(it) end end)
    end
    pcall(function() data:luaCallOnCreate(player) end)
    pcall(function() data:processDestroyAndUsedItems(player) end)
    if #outs == 1 then
        -- the craft window records what went in on the result item
        pcall(function()
            local modData = outs[1]:getModData()
            local usedItems = data:getAllConsumedItems()
            for i = 0, usedItems:size() - 1 do
                local ft = usedItems:get(i):getFullType()
                modData[ft] = (modData[ft] or 0) + 1
            end
        end)
    end
    local firstSrc = nil
    for _, it in ipairs(cand.inputs) do
        if srcOf[it] then firstSrc = srcOf[it]; break end
    end
    local where = stove and (stove.ctype .. " @" .. stove.x .. "," .. stove.y) or "the shelf the inputs came from (no oven)"
    for _, it in ipairs(outs) do
        if safe(function() return it:getContainer() end) == inv then
            local oven = intoOven(it, stove)
            if oven then
                where = oven.ctype .. " @" .. oven.x .. "," .. oven.y
            elseif firstSrc and moveTo(it, firstSrc) then
                where = stove and "the shelf the inputs came from (every oven refused it)" or where
            else
                where = "PLAYER INVENTORY (no container would take it)"
            end
        end
    end
    putBack()
    refreshSprite(stove)
    pcall(function() if dest then dest:setHasBeenLooted(true) end end)
    local xpAfter = tonumber(safe(function() return player:getXp():getXP(Perks.Cooking) end))
    local xp = (xpBefore and xpAfter) and (xpAfter - xpBefore) or nil
    return {
        name = outs[1] and displayName(outs[1]) or cand.entry.name, recipe = "craft " .. cand.entry.name,
        added = #cand.consumed, failed = 0, where = where, xp = xp, summary = summary, outs = outs,
    }
end

-- A fresh craft output that is an evolved-recipe base (cake prep, pizza, bread dough): add what the kitchen has
-- through the vanilla evolved recipe, as a pot meal would. Returns the prepMeal result or nil.
local function evolvedStep(outs, player, plan, usedIds)
    local bases = getBaseIndex()
    for _, item in ipairs(outs) do
        local full = tostring(safe(function() return item:getFullType() end) or "")
        local entry = bases[full]
        if entry and entry.minWater == 0 and instanceof(item, "Food") then
            local src = nil
            local holder = safe(function() return item:getContainer() end)
            for _, c in ipairs(plan.scan.containers) do
                if c.container == holder then src = c; break end
            end
            if src == nil then return nil end
            local list = safe(function() return RecipeManager.getEvolvedRecipe(item, player, plan.containerList, true) end)
            local best, bestPick, bestSpice = nil, nil, nil
            if list then
                for r = 0, list:size() - 1 do
                    local recipe = list:get(r)
                    if safe(function() return recipe:isResultItem(item) end) ~= true
                            and safe(function() return recipe:isHidden() end) ~= true then
                        local cands = candidateIngredients(recipe, item, player, plan.containerList, plan.sources)
                        local picked, spices = pickIngredients(recipe, cands, usedIds)
                        if #picked > (bestPick and #bestPick or 0) then best, bestPick, bestSpice = recipe, picked, spices end
                    end
                end
            end
            if best == nil then return nil end
            for _, it in ipairs(bestPick) do local id = itemId(it); if id then usedIds[id] = true end end
            for _, it in ipairs(bestSpice) do local id = itemId(it); if id then usedIds[id] = true end end
            local meal = { picked = bestPick, spices = bestSpice, cand = {
                base = item, src = src, recipe = best, cookable = safe(function() return best:isCookable() end) == true,
                name = tostring(safe(function() return best:getUntranslatedName() end) or "?"),
            } }
            local ok, res, err = pcall(prepMeal, meal, player, plan.stove)
            if ok and res then return res end
            BKLog.warn("ingredient step failed on " .. displayName(item) .. ": " .. tostring(ok and err or res))
            return nil
        end
    end
    return nil
end

-- One craft-window meal, chained: a step recipe (cake batter) is followed by the recipe that finishes it (cake in
-- the baking pan), and an edible output that is an evolved base gets kitchen ingredients. Returns one result
-- covering the chain, or nil, refused (name -> reason), performable count.
local function craftChain(zone, player, plan, usedIds)
    local names, summaries, xp, last, mustUse = {}, {}, 0, nil, nil
    local firstRefused, firstCount = {}, 0
    for step = 1, BKCook.CHAIN_STEPS do
        local picks, refused, count = BKCook.planCraft(zone, player, plan.scan, plan.containerList, plan.stove, 1, usedIds, mustUse)
        local cand = picks[1]
        if step == 1 then firstRefused, firstCount = refused, count end
        if cand == nil then
            if last then BKLog.warn("craft chain stopped after " .. table.concat(names, " > ") .. ": " .. last.name .. " left in " .. last.where) end
            break
        end
        local res, err = craftMeal(cand, player, plan.stove)
        if res == nil then
            if step == 1 then return nil, { [cand.entry.name] = tostring(err) }, count end
            BKLog.warn("craft chain stopped at " .. cand.entry.name .. " (" .. tostring(err) .. "): " .. last.name .. " left in " .. last.where)
            break
        end
        for _, it in ipairs(cand.inputs) do local id = itemId(it); if id then usedIds[id] = true end end
        table.insert(names, cand.entry.name)
        table.insert(summaries, res.name .. " from " .. res.summary)
        xp = xp + (res.xp or 0)
        last = res
        if cand.entry.food then
            if cand.entry.evolvedBase then
                local ev = evolvedStep(res.outs, player, plan, usedIds)
                if ev then
                    table.insert(names, ev.recipe)
                    table.insert(summaries, ev.name .. " with " .. ev.summary)
                    xp = xp + (ev.xp or 0)
                    last = ev
                end
            end
            for _, it in ipairs(res.outs or {}) do local id = itemId(it); if id then usedIds[id] = true end end
            break
        end
        mustUse = {}
        local anyMust = false
        for _, it in ipairs(res.outs or {}) do local id = itemId(it); if id then mustUse[id] = true; anyMust = true end end
        if not anyMust then break end
    end
    if last == nil then return nil, firstRefused, firstCount end
    return {
        name = last.name, recipe = "craft " .. table.concat(names, " > "), added = last.added, failed = last.failed or 0,
        where = last.where, xp = xp, summary = table.concat(summaries, "; "),
    }
end

-- The prep never drives the stove: the pot or pan is left in it uncooked for the player. The stove is left exactly
-- as it was found (Tanner, 2026-11-05: "make sure the breakfast isn't leaving the oven on"), and the log says so.
local function leaveStoveAsFound(stove, wasOn, why)
    local on = stoveOn(stove)
    if on == nil then return end
    if on and not wasOn then
        pcall(function() stove.obj:Toggle() end)
        BKLog.warn(string.format("%s came on during the breakfast prep (%s): turned back off", stoveLabel(stove), tostring(why)))
    elseif on then
        BKLog.info(string.format("%s was already on before the breakfast prep (%s) and is left as found: turn it off yourself when the food is done",
            stoveLabel(stove), tostring(why)))
    end
end

-- Preps the zone's meals for one run. Returns the list of result tables (may be empty) plus fields kcal, need, nut,
-- ovenMeal, thawed (items moved to the fridge) and retry (a reason string: nothing final yet, try again next tick).
-- quiet = a retry tick: actions are logged, the plan notes are not.
function BKCook.prepZone(zone, player, why, run, quiet)
    run = run or BKCook.currentRun()
    local function say(s) if not quiet then BKLog.info(s) end end
    local need, nut, target = BKCook.calorieNeed(player, run)
    local count = BKCook.mealsFor(need, nil)
    if why == "manual" then count = 1 end -- v0.14.3: by hand = one meal
    say(string.format("%s (%s) zone %s: %s; need ~%s kcal -> up to %d meal(s)", run.label, tostring(why),
        tostring(zone.id), BKCook.nutritionLine(nut, target), need and tostring(math.floor(need)) or "?", count))
    if need ~= nil and need <= 0 then
        if why ~= "manual" then
            say("  calorie pool already above target: nothing prepped")
            return { need = need, nut = nut, kcal = 0 }
        end
        count, need = 1, nil -- asked for by hand: one meal anyway
    end
    local waiting = BKCook.mealInOven(BKZoneScan.scan(zone))
    if waiting then
        say(string.format("  %s is already in the oven: nothing new prepped", displayName(waiting)))
        return { need = need, nut = nut, kcal = 0, ovenMeal = displayName(waiting) }
    end
    local plan = BKCook.plan(zone, player, false, count)
    local stoveWasOn = stoveOn(plan.stove)
    local results = {}
    local function report(res)
        table.insert(results, res)
        BKLog.info(string.format("breakfast (%s) zone %s: %s [%s] %d ingredient(s)%s%s -> %s%s: %s", tostring(why),
            tostring(zone.id), res.name, res.recipe, res.added, res.failed > 0 and (", " .. res.failed .. " failed") or "",
            (res.refused or 0) > 0 and (", " .. res.refused .. " refused by the game") or "",
            res.where, res.xp and string.format(", cooking XP %+.1f", res.xp) or "", res.summary))
    end
    for _, meal in ipairs(plan.meals) do
        local ok, res, err = pcall(prepMeal, meal, player, plan.stove)
        if ok and res then report(res) else BKLog.warn("breakfast meal failed: " .. tostring(ok and err or res)) end
    end
    -- craft-window meals for the slots the pot meals left, planned on the live kitchen after those were made
    -- stop early once the pot meals already cover the need
    local got = 0
    for _, mm in ipairs(plan.meals) do got = got + (mm.kcal or 0) end
    local slots = count - #results
    if need ~= nil and got >= need then slots = 0 end
    local usedIds = plan.used or {}
    local craftRefused = {}
    for _ = 1, slots do
        local ok, res, refused = pcall(craftChain, zone, player, plan, usedIds)
        if not ok then
            BKLog.warn("craft meal failed: " .. tostring(res))
            break
        elseif res then
            report(res)
            for _, o in ipairs(res.outs or {}) do got = got + kcal(o) end
            if need ~= nil and got >= need then break end
        else
            craftRefused = refused or {}
            if #results == 0 then
                for name, r in pairs(craftRefused) do say("  craft " .. name .. " skipped: " .. r) end
            end
            break
        end
    end
    if #results == 0 then
        say(string.format("breakfast (%s) zone %s: nothing to prep", tostring(why), tostring(zone.id)))
        for _, n in ipairs(plan.notes) do say("  note: " .. n) end
    elseif need ~= nil and got < need then
        -- v0.10.2: fewer calories than needed: say why the pot meals stopped (same notes as an empty morning)
        say(string.format("  short: ~%d of ~%d kcal from %d meal(s); %d pot meal(s) possible", math.floor(got),
            math.floor(need), #results, #plan.meals))
        for _, n in ipairs(plan.notes) do say("  note: " .. n) end
        for _, cand in ipairs(plan.candidates or {}) do
            local foods = 0
            for _, it in ipairs(cand.cands) do if not isSpice(it) then foods = foods + 1 end end
            local parts = {}
            for w, n in pairs(cand.refused) do table.insert(parts, w .. " " .. n) end
            say(string.format("  %s/%s: %d usable food, skipped: %s", cand.name, displayName(cand.base), foods,
                #parts > 0 and table.concat(parts, ", ") or "none"))
        end
    end
    leaveStoveAsFound(plan.stove, stoveWasOn, why)
    -- v0.14.0 thaw-ahead: short of calories -> thaw for the rest of this run and come back; otherwise thaw what the
    -- next run is expected to need, so its meat is ready when it starts
    local nextRun = (run == BKCook.RUNS[1]) and BKCook.RUNS[2] or BKCook.RUNS[1]
    local short = need ~= nil and got < need
    local want = short and (need - got) or (BKCook.DAILY_BURN * (nextRun.covers or 0.5))
    if why == "manual" then want = BKCook.MEAL_KCAL end -- v0.14.3: thaw one meal's worth for the next time you ask
    local moved, thawWhy = {}, nil
    if BKCook.THAW_AHEAD then
        moved, _, thawWhy = BKCook.thawAhead(plan, want, short and (run.label .. ", this run") or nextRun.label)
    end
    if thawWhy then say("  thaw-ahead: " .. thawWhy) end
    local retry = nil
    if #results == 0 and why ~= "manual" then
        local thawing = BKCook.THAW_AHEAD and BKCook.thawing(plan) or {}
        if #moved > 0 or #thawing > 0 then
            local soonest = BKCook.THAW_HOURS_FRIDGE
            if #moved == 0 then
                for _, t in ipairs(thawing) do if t.hours < soonest then soonest = t.hours end end
            end
            retry = string.format("%d item(s) thawing, ~%.1f h to go", #moved + #thawing, soonest)
        end
        for _, r in pairs(craftRefused) do
            if string.find(r, "surface", 1, true) or string.find(r, "dark", 1, true) then retry = retry or r end
        end
    end
    if BKKeeper and BKKeeper.invalidate then BKKeeper.invalidate(zone.id) end
    results.kcal = got
    results.need = need
    results.nut = nut
    results.thawed = moved
    results.retry = retry
    return results
end

-- One run (breakfast or dinner): once per zone per run per game day, inside the run's window, and only while the
-- player is at that zone. A zone the player is away from is not marked done, so the meal is prepped when they come home.
-- Only the zone the player is nearest to cooks for them (one kitchen feeds one survivor).
-- v0.14.0: a run that made nothing but has food thawing (or lacked a craft surface / light) is not marked done
-- either: every ten game minutes it tries again, quietly, until it cooks or the window closes. Before this the first
-- tick of the window decided the whole run, so a dinner that fired while the player stood away from a counter was gone
-- for the day.
function BKCook.runMeals(run)
    local d = store()
    local player = getSpecificPlayer(0)
    if player == nil or safe(function() return player:isDead() end) == true then return end
    local today = dateKey()
    local key = today .. ":" .. run.key
    local names, total, nut, need, ovenMeal, retryNote, firstTry = {}, 0, nil, nil, nil, nil, false
    if d.done.player == key then return end
    d.tries = d.tries or {}
    for k in pairs(d.tries) do
        if string.sub(k, 1, #today) ~= today then d.tries[k] = nil end
    end
    for _, zone in ipairs(BKZones.list()) do
        local zid = tostring(zone.id)
        -- v0.10.2: a zone without an oven is not a kitchen (the chicken run cooked "nothing" right after zone 1 fed)
        if d.done[zid] ~= key and BKCook.playerNear(zone, player) and stoveEntry(BKZoneScan.scan(zone)) ~= nil then
            local tkey = key .. ":" .. zid
            local tries = tonumber(d.tries[tkey]) or 0
            local quiet = tries > 0 and (tries % BKCook.RETRY_LOG_EVERY) ~= 0
            local ok, results = pcall(BKCook.prepZone, zone, player, run.key, run, quiet)
            if ok then
                for _, r in ipairs(results) do table.insert(names, r.name) end
                total = total + (results.kcal or 0)
                nut, need = results.nut or nut, results.need or need
                ovenMeal = results.ovenMeal or ovenMeal
                if #results > 0 or results.ovenMeal or (results.need ~= nil and results.need <= 0) then
                    d.done[zid] = key
                    d.done.player = key -- fed: no other zone cooks this run
                    d.tries[tkey] = nil
                    break
                elseif results.retry then
                    d.tries[tkey] = tries + 1
                    retryNote = results.retry
                    firstTry = firstTry or tries == 0
                    if not quiet then
                        BKLog.info(string.format("  %s zone %s: not done, trying again every 10 minutes (%s)", run.label, zid, results.retry))
                    end
                else
                    d.done[zid] = key -- nothing to cook and nothing on the way: final for this run
                    d.tries[tkey] = nil
                end
            else
                d.done[zid] = key
                BKLog.warn(run.label .. " failed for zone " .. zid .. ": " .. tostring(results))
            end
        end
    end
    if #names > 0 then
        local tail = nut and string.format(" (~%d kcal) | %.1f kg, pool %d", math.floor(total), nut.kg, math.floor(nut.pool)) or ""
        pcall(function() player:setHaloNote(run.label .. " prepped: " .. table.concat(names, ", ") .. tail) end)
    elseif ovenMeal then
        pcall(function() player:setHaloNote(run.label .. ": " .. ovenMeal .. " is waiting in the oven") end)
    elseif retryNote and firstTry then
        pcall(function() player:setHaloNote(run.label .. ": " .. retryNote) end)
    elseif nut and not retryNote and nut.kg < BKCook.GOAL_KG + 1 then
        pcall(function() player:setHaloNote(string.format("%s: nothing to cook and you are at %.1f kg, eat something", run.label, nut.kg)) end)
    end
end

function BKCook.morning() return BKCook.runMeals(BKCook.RUNS[1]) end

local function tick()
    local d = store()
    if d.enabled == false then return end
    local hour = tonumber(safe(function() return getGameTime():getHour() end))
    if hour == nil then return end
    for _, run in ipairs(BKCook.RUNS) do
        if hour >= run.from and hour < run.to then
            local ok, err = pcall(BKCook.runMeals, run)
            if not ok then BKLog.warn(run.label .. " tick failed: " .. tostring(err)) end
        end
    end
end

Events.EveryTenMinutes.Add(tick)

return BKCook
