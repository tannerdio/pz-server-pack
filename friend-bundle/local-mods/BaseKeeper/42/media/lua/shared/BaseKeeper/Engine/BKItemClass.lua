-- Base Keeper: item classification. Pure function of the InventoryItem; no world or NPC knowledge.
-- Order of evidence: Java class (instanceof / IsFood...) > ItemTag enum > Food state > script fields probed via
-- pcall > item type name > DisplayCategory. DisplayCategory is last because BetterSorting rewrites it at load,
-- so both the vanilla and BetterSorting vocabularies are accepted as a weak hint only.
require "BaseKeeper/BKLog"
require "BaseKeeper/Engine/BKCatalog"
require "BaseKeeper/Engine/BKTaxonomy"

BKItemClass = BKItemClass or {}

-- v0.12.0: the catalog (every vanilla item -> fine group + coarse class, generated from media/scripts) is consulted
-- first; the heuristics below only decide mod items. Live state still wins: rotten -> trash, a lighter at 0 ->
-- depleted, an empty bottle -> empties, a bottle refilled with something poisonous -> hygiene/medical.
BKItemClass.catalogIndex = nil
local function catalogIndex()
    if BKItemClass.catalogIndex then return BKItemClass.catalogIndex end
    local idx, n = {}, 0
    for _, entry in ipairs(BKCatalog and BKCatalog.DATA or {}) do
        for _, name in ipairs(entry.n or {}) do
            local key = string.find(name, ".", 1, true) and name or ("Base." .. name)
            idx[key] = entry
            n = n + 1
        end
    end
    BKItemClass.catalogIndex = idx
    BKLog.info("item catalog: " .. n .. " vanilla items in " .. tostring(BKTaxonomy and #BKTaxonomy.GROUPS or 0) .. " groups")
    return idx
end

-- { g = group, c = class } for a vanilla item, nil for anything the catalog does not list.
function BKItemClass.catalogEntry(item)
    local ok, ft = pcall(function() return item:getFullType() end)
    if not ok or ft == nil then return nil end
    return catalogIndex()[tostring(ft)]
end

BKItemClass.CLASSES = {
    "food_frozen", "food_freezable", "food_perishable", "food_canned", "food_dry", "drink", "cooking",
    "tool", "mechanics", "fuel", "build_material", "medical", "hygiene", "clothing", "weapon", "ammo",
    "literature", "electronics", "container", "empties", "depleted", "junk", "trash", "other",
}

local NON_PERISHABLE_OFFAGE = 1000000 -- Java Food default OffAgeMax is 1e9; anything below means it rots
local PANTRY_DAYS = 30                -- v0.14.0: food that keeps this long (sealed jars, mac and cheese) is pantry stock
                                      -- (v0.14.1: Food.OffAgeMax is in days, not hours; 30*24 only caught the 1500-day jars)

-- Optional Java methods are probed once per method name; a missing method never throws twice.
local probeCache = {}
local function call(item, method, ...)
    if probeCache[method] == false then return nil end
    local fn = item[method]
    if type(fn) ~= "function" then probeCache[method] = false; return nil end
    local ok, res = pcall(fn, item, ...)
    if not ok then probeCache[method] = false; return nil end
    probeCache[method] = true
    return res
end

local function tag(item, name)
    local t = ItemTag and ItemTag[name]
    if t == nil then return false end
    local ok, res = pcall(item.hasTag, item, t)
    return ok and res == true
end

local function lower(s) return string.lower(tostring(s or "")) end

-- Short words that would match too much as substrings ("pan" in "spanner", "oil" in "foil") only match whole.
local EXACT_ONLY = { pan = true, oil = true, plate = true, bottle = true, jar = true, cup = true, glass = true,
    whisk = true, tin = true,
    door = true, seat = true, hood = true, log = true, bowl = true, pot = true, mug = true, fork = true,
    spoon = true, knife = true, sand = true, wire = true, tile = true, sack = true, stone = true, brick = true }

local function anyMatch(s, patterns)
    for _, p in ipairs(patterns) do
        if EXACT_ONLY[p] then
            if s == p then return true end
        elseif string.find(s, p, 1, true) then
            return true
        end
    end
    return false
end

-- DisplayCategory hints, vanilla and BetterSorting (id BetterSortCC) vocabularies.
local CATEGORY_HINT = {
    -- vanilla
    Food = "food_dry", Cooking = "cooking", CookingWeapon = "cooking", Tool = "tool", ToolWeapon = "tool",
    VehicleMaintenance = "mechanics", VehicleMaintenanceWeapon = "mechanics", Material = "build_material",
    MaterialWeapon = "build_material", FirstAid = "medical", Bandage = "medical", Clothing = "clothing",
    Accessory = "clothing", ProtectiveGear = "clothing", Bag = "container", Container = "container",
    Weapon = "weapon", WeaponCrafted = "weapon", WeaponPart = "weapon", Ammo = "ammo", Literature = "literature",
    SkillBook = "literature", Cartography = "literature", Electronics = "electronics",
    Communications = "electronics", LightSource = "electronics", Junk = "junk", JunkWeapon = "junk",
    Household = "hygiene", Appearance = "hygiene", Camping = "tool", Gardening = "tool",
    GardeningWeapon = "tool", Fishing = "tool", Trapping = "tool", Explosives = "weapon",
    -- BetterSorting
    FoodP = "food_perishable", FoodN = "food_dry", FoodA = "drink", FoodB = "drink", CookImp = "cooking",
    CookIng = "food_dry", CookIngP = "food_perishable", CookBev = "drink", CookBevP = "drink",
    ToolB = "tool", ToolC = "tool", ToolF = "tool", ToolG = "tool", ToolH = "tool", ToolL = "electronics",
    ToolM = "mechanics", Mech = "mechanics", Fuel = "fuel", Build = "build_material", BuildP = "build_material",
    CraftG = "build_material", CraftBlack = "build_material", CraftCarv = "build_material",
    CraftChem = "medical", CraftMas = "build_material", CraftTailor = "clothing", CraftAmmo = "ammo",
    MedI = "medical", MedM = "medical", MedT = "medical", Drugs = "medical", Clean = "hygiene",
    AppearC = "hygiene", ClothAcc = "clothing", ClothArm = "clothing", ClothBack = "container",
    ClothBag = "container", ClothBody = "clothing", ClothFeet = "clothing", ClothHead = "clothing",
    ClothJew = "clothing", ClothLeg = "clothing", ClothMisc = "clothing", ClothUnder = "clothing",
    ContB = "container", ContH = "container", ContL = "container", ContS = "container",
    ElecC = "electronics", ElecI = "electronics", ElecJ = "junk", ElecL = "electronics",
    LitC = "literature", LitE = "literature", LitR = "literature", LitS = "literature", LitW = "literature",
    MediaA = "electronics", MediaG = "electronics", MediaS = "electronics", MediaV = "electronics",
    MiscJ = "junk", Misc = "other", MiscK = "other", SurCamp = "tool", SurFarm = "tool", SurFish = "tool",
    SurTrap = "tool", WepAmmo = "ammo", WepAmmoMag = "ammo", WepBomb = "weapon", WepBow = "weapon",
    WepFire = "weapon", WepMAxe = "weapon", WepMBladeL = "weapon", WepMBladeS = "weapon",
    WepMBluntL = "weapon", WepMBluntS = "weapon", WepMSpear = "weapon", WepMelee = "weapon",
    WepPart = "weapon", WepRange = "weapon", WepShield = "weapon",
}

local CANNED_NAMES = { "canned", "tinned", "tin", "cannedfood", "jarof" }
local FREEZER_NAMES = { "icecream", "popsicle", "frozen" }
local HYGIENE_NAMES = { "soap", "toothbrush", "toothpaste", "towel", "toiletpaper", "razor", "shampoo",
    "comb", "hairspray", "cologne", "perfume", "makeup", "lipstick", "tissue", "sponge", "bleach", "cleaning" }
local FUEL_NAMES = { "petrol", "gascan", "propane", "charcoal", "kerosene", "lighterfluid", "coal" }
-- exact type names that are fuel beyond doubt (a certain class migrates into a loot area; a guess does not)
local SURE_FUEL_TYPES = { propanetank = true, charcoal = true, coal = true }
-- shop safety gear that lives with the tools, not the wardrobe (Tanner, 2026-11-04: "cant find my welding mask")
local TOOL_WEAR_NAMES = { "weldingmask", "oldweldinggoggles", "safetygoggles", "earmuff_protectors" } -- WeldingMask, Glasses_*, Hat_EarMuff_Protectors
local MECH_NAMES = { "tire", "brake", "muffler", "suspension", "carbattery", "enginepart", "gastank",
    "windshield", "headlight", "jack", "lugwrench", "tirepump", "carkey", "sparkplug", "radiator", "alternator",
    "engineoil", "oil" }
local BUILD_NAMES = { "plank", "nails", "screws", "log", "sheetmetal", "metalbar", "metalpipe", "stone",
    "bricks", "brick", "mortar", "concrete", "wire", "barbedwire", "cement", "gravel", "sand", "tarp",
    "hinge", "doorknob", "rope", "sheetrope", "twine", "duct", "glue", "paint", "wallpaper", "tile", "sack",
    "smallsheetmetal", "woodenstick", "branch", "sturdystick", "woodglue" }
-- things that only belong in a bin (type names, lower case)
local TRASH_NAMES = { "tincanempty", "popempty", "beercanempty", "fishingtrash" }
local COOKING_NAMES = { "pan", "pot", "saucepan", "bowl", "plate", "bakingtray", "muffintray", "roastingpan",
    "kettle", "griddle", "rollingpin", "spatula", "grater", "whisk", "cuttingboard", "canopener", "mug",
    "glass", "cup", "fork", "spoon", "butterknife", "ladle" }

-- raw and cooked meat/fish keep months frozen instead of days in the fridge (v0.9.0 rule 7)
local FREEZE_FOODTYPES = { Meat = true, Seafood = true, Poultry = true, Fish = true, Beef = true, Game = true,
    Sausage = true, Roe = true }
-- junk beyond doubt (v0.9.0 rule 3): mementos are tagged; the rest by exact type
local SURE_JUNK_TYPES = { money = true, creditcard = true, hairdryer = true }
-- empty fluid holders that are cookware or canning stock, not "empties" (substring match on the type name)
local NOT_EMPTIES = { "mug", "cup", "glass", "bowl", "pot", "pan", "kettle", "jar", "bucket", "watering", "wateredcan",
    "petrol", "gascan", "jerrycan", "bleach", "spray", "bottleopener" }

local function foodClass(item)
    local offAgeMax = call(item, "getOffAgeMax")
    local perishable = offAgeMax ~= nil and offAgeMax < NON_PERISHABLE_OFFAGE
    -- v0.14.0: a sealed jar keeps 1500+ days and mac and cheese a year; they filled the fridge as "perishable"
    -- (Tanner 2026-11-08). Judged on total life, so the class does not flip as the item ages. Frozen stays frozen.
    if perishable and offAgeMax >= PANTRY_DAYS then perishable = false end
    local frozen = call(item, "isFrozen") == true
    local freezing = (call(item, "getFreezingTime") or 0) > 0
    local canFreeze = call(item, "canBeFrozen")
    local hunger = call(item, "getHungChange") or call(item, "getHungerChange") or 0
    local thirst = call(item, "getThirstChange") or 0
    local opening = nil
    opening = call(item, "getOpeningRecipe")
    local typeName = lower(item:getType())
    local canned = (opening ~= nil and opening ~= "") or anyMatch(typeName, CANNED_NAMES)
    if call(item, "isRotten") == true then return "trash" end
    if frozen or freezing then return "food_frozen" end
    if canned and not perishable then return "food_canned" end
    if thirst < 0 and hunger >= -0.05 and not perishable then return "drink" end -- milk/juice spoil: they stay cold (v0.9.0)
    if perishable then
        if canFreeze ~= false and anyMatch(typeName, FREEZER_NAMES) then return "food_freezable" end
        if canFreeze ~= false and FREEZE_FOODTYPES[tostring(call(item, "getFoodType") or "")] then return "food_freezable" end
        return "food_perishable"
    end
    return "food_dry"
end

-- Reasons that come from the game's own class, tags or food state are certain; names and DisplayCategory are guesses.
local SURE_REASONS = { food = true, class = true, tag = true, fluid = true, itemtype = true, key = true, trash = true,
    catalog = true }

-- The live fluid check shared by catalog "drink" items and the heuristics: empties, poison (bleach -> hygiene,
-- alcohol -> medical), rubbing alcohol -> medical, small drinkable -> drink. Returns class, reason or nil.
local function fluidClass(item, typeName, fluid)
    if fluid == nil then return nil end
    -- empty bottles are water containers, not trash (v0.9.0 rule 2); cookware, jars, buckets and fuel cans are not
    if call(item, "isEmptyOfFluid") == true and not anyMatch(typeName, NOT_EMPTIES)
            and not anyMatch(typeName, HYGIENE_NAMES) and not tag(item, "JAR") then
        local okc, cap = pcall(function() return fluid:getCapacity() end)
        if okc and tonumber(cap) and tonumber(cap) <= 2.5 then return "empties", "fluid" end
    end
    if call(item, "isEmptyOfFluid") ~= true and not anyMatch(typeName, HYGIENE_NAMES) and not anyMatch(typeName, FUEL_NAMES) then
        -- rubbing alcohol has no Poison block (fluids.txt: Alcoholic/Medical/Industrial), so check it by fluid
        -- (v0.8.8: disinfectant was filed as a drink and sat in the fridge); a refilled bottle with water stays a drink
        -- v0.10.4: `Fluid.RubbingAlcohol` did not catch the base's bottles (they still sorted to the kitchen as
        -- drinks); the primary fluid's type string ("RubbingAlcohol", as the export prints it) is what works.
        local okn, fname = pcall(function() return tostring(fluid:getPrimaryFluid():getFluidTypeString()) end)
        if okn and fname == "RubbingAlcohol" then return "medical", "fluid" end
        if Fluid and Fluid.RubbingAlcohol then
            local okr, hasAlc = pcall(function() return fluid:contains(Fluid.RubbingAlcohol) end)
            if okr and hasAlc then return "medical", "fluid" end
        end
        -- bleach, cleaning liquid: the fluid definition carries a Poison block, water does not
        local okp, poison = pcall(function() return fluid:isPoisonous() end)
        if okp and poison == true then
            local alcohol = tonumber(call(item, "getAlcoholPower")) or 0
            if alcohol > 0 then return "medical", "fluid" end
            return "hygiene", "fluid"
        end
        local okc, cap = pcall(function() return fluid:getCapacity() end)
        if okc and tonumber(cap) and tonumber(cap) <= 2.5 then return "drink", "fluid" end
    end
    return nil
end

-- Returns class, reason, sure (true when the classification is certain), group (BKTaxonomy key).
function BKItemClass.classify(item)
    if item == nil then return "other", "nil", false, "other" end
    local entry = BKItemClass.catalogEntry(item)
    local forced = nil -- fine group decided together with the class (v0.20.0 mod items)
    local ok, res, why = pcall(function()
        local typeName = lower(item:getType())
        local category = tostring(item:getCategory() or "")
        local isFood = item.IsFood and item:IsFood()

        -- v0.12.0 catalog: a vanilla item's static class, unless the game decides it live (food state, fluids)
        if entry and entry.c == "food" then
            if isFood then return foodClass(item), "food" end
            -- v0.20.0: an empty milk carton / milk bottle is an empty bottle, not dairy for the pantry
            local efc, efw = fluidClass(item, typeName, call(item, "getFluidContainer"))
            if efc == "empties" then return efc, efw end
            return "food_dry", "catalog" -- scripted with FoodType but not a Food object (vinegar jug, mixes)
        end
        -- animal by-products the game scripts as food (ItemType base:food) but nobody eats (v0.8.6, Tanner
        -- 2026-11-05: feathers and droppings ended up on the kitchen counter): dung is fertilizer and goes with the
        -- gardening supplies, feathers are a crafting material
        if string.sub(typeName, 1, 5) == "dung_" then return "tool", "itemtype" end
        if typeName == "chickenfeather" or typeName == "turkeyfeather" then return "build_material", "itemtype" end
        -- powders and tablets the game scripts as drainables, not food or drink (v0.9.0 rule 1: pantry, not fridge)
        -- v0.20.0: water purification tablets are no longer pantry food; the catalog files them under camping
        if string.find(typeName, "milkpowder", 1, true) then return "food_dry", "itemtype" end
        if tag(item, "PURIFY_WATER") and entry == nil then forced = "camping"; return "tool", "itemtype" end
        if isFood and entry == nil then return foodClass(item), "food" end
        if tag(item, "EMPTY_CAN") then return "trash", "trash" end -- Pop3Empty and friends (v0.9.0 rule 2)
        -- refillable things at zero (lighter, blow torch, propane bottle): KeepOnDeplete keeps them when empty (rule 5)
        if call(item, "isKeepOnDeplete") == true and tonumber(call(item, "getCurrentUses")) == 0 then
            return "depleted", "itemtype"
        end
        if entry then
            if entry.c == "drink" then
                local fc, fw = fluidClass(item, typeName, call(item, "getFluidContainer"))
                if fc then return fc, fw end
                return "drink", "catalog"
            end
            if entry.c == "empties" then
                -- a crafted bottle filled with something is a drink again
                local fc, fw = fluidClass(item, typeName, call(item, "getFluidContainer"))
                if fc then return fc, fw end
            end
            if isFood and entry.c ~= "other" and call(item, "isRotten") == true then return "trash", "trash" end
            return entry.c, "catalog"
        end
        -- v0.20.0 mod items (gun packs and others the catalog does not list), by what the game itself says they
        -- are instead of by their name. All certain, so "Sort now" may move them. Seen on Tanner's base 2026-11-27:
        -- every modded gun was a "melee weapon", bipods/silencers too, gun cleaning kits were cleaning supplies,
        -- modded ammo boxes and magazines were only guesses, picked-up furniture was "unsorted".
        if category == "Moveable" or instanceof(item, "Moveable") then forced = "furniture"; return "other", "itemtype" end
        local rawDisplay = tostring(item:getDisplayCategory() or "")
        local isWeapon = category == "Weapon" or (item.IsWeapon and item:IsWeapon()) == true
        if category == "WeaponPart" or instanceof(item, "WeaponPart") or rawDisplay == "WeaponPart"
                or rawDisplay == "WepPart" or typeName == "cleaningkit" then
            forced = "weapon_part"; return "weapon", "class"
        end
        if isWeapon and type(item.isRanged) == "function" then
            local okR, ranged = pcall(item.isRanged, item)
            if okR and ranged == true then forced = "weapon_gun"; return "weapon", "class" end
        end
        if not isWeapon then
            -- a magazine holds rounds; boxes, cartons and loose rounds carry the game's own Ammo category
            if (tonumber(call(item, "getMaxAmmo")) or 0) > 0 or rawDisplay == "Ammo" or rawDisplay == "WepAmmo"
                    or rawDisplay == "WepAmmoMag" then
                forced = "ammo"; return "ammo", "itemtype"
            end
            if string.find(typeName, "tirerepair", 1, true) then forced = "mechanics"; return "mechanics", "itemtype" end
        end
        if tag(item, "IS_MEMENTO") or SURE_JUNK_TYPES[typeName] then return "junk", "itemtype" end
        if anyMatch(typeName, TRASH_NAMES) then return "trash", "trash" end
        -- dirty bandages/rags/strips are medical (v0.10.2, Tanner: "bandages can be cleaned? sort them back to medical";
        -- v0.8.8 had sent them to the bin): they wash back into clean ones (ItemAfterCleaning), REUSABLE_BANDAGE below
        if SURE_FUEL_TYPES[typeName] then return "fuel", "itemtype" end
        if anyMatch(typeName, TOOL_WEAR_NAMES) then return "tool", "itemtype" end
        if category == "Clothing" or (item.IsClothing and item:IsClothing()) then return "clothing", "class" end
        if category == "Container" or (item.IsInventoryContainer and item:IsInventoryContainer()) then
            return "container", "class"
        end
        if tag(item, "AMMO") or tag(item, "SHOTGUN_SHELL") or tag(item, "PISTOL_MAGAZINE") or tag(item, "RIFLE_MAGAZINE") then
            return "ammo", "tag"
        end
        if tag(item, "PETROL") then return "fuel", "tag" end
        if tag(item, "SIPHON_GAS") then return "tool", "tag" end
        local fluid = call(item, "getFluidContainer")
        if fluid ~= nil and Fluid and Fluid.Petrol then
            local okf, hasPetrol = pcall(function() return fluid:contains(Fluid.Petrol) end)
            if okf and hasPetrol then return "fuel", "fluid" end
        end
        local fc, fw = fluidClass(item, typeName, fluid)
        if fc then return fc, fw end
        if tag(item, "CAR_BATTERY") then return "mechanics", "tag" end
        if tag(item, "HAMMER") or tag(item, "SAW") or tag(item, "SCREWDRIVER") or tag(item, "WRENCH")
            or tag(item, "PIPE_WRENCH") or tag(item, "CROWBAR") or tag(item, "PRY_BAR") or tag(item, "SLEDGEHAMMER")
            or tag(item, "PICK_AXE") or tag(item, "CLUB_HAMMER") or tag(item, "STONE_MAUL") or tag(item, "SCISSORS")
            or tag(item, "SEWING_NEEDLE") or tag(item, "BLOW_TORCH") or tag(item, "WELDING_MASK")
            or tag(item, "DIG_PLOW") or tag(item, "DIG_GRAVE") or tag(item, "CHOP_TREE") or tag(item, "SCYTHE")
            or tag(item, "HAND_SCYTHE") or tag(item, "SHEAR") or tag(item, "FISHING_ROD") or tag(item, "PAINTBRUSH")
            or tag(item, "REMOVE_BARRICADE") then
            return "tool", "tag"
        end
        if tag(item, "REUSABLE_BANDAGE") then return "medical", "tag" end
        if tag(item, "RAZOR") or tag(item, "TOILET_BRUSH") or tag(item, "CLEAN_STAINS") then return "hygiene", "tag" end
        if tag(item, "ROPE") or tag(item, "WALLPAPER_PASTE") or tag(item, "PLASTER_BUCKET") then return "build_material", "tag" end
        if tag(item, "PEN") or tag(item, "PENCIL") or tag(item, "WRITE") or tag(item, "PICTUREBOOK") then return "literature", "tag" end
        if tag(item, "GENERATOR") then return "mechanics", "tag" end

        local strType = call(item, "getStringItemType")
        if strType == "Medical" then return "medical", "itemtype" end
        if category == "Literature" or (item.IsLiterature and item:IsLiterature()) or (item.IsMap and item:IsMap()) then
            return "literature", "class"
        end
        if category == "Key" then return "other", "key" end
        if category == "Radio" or instanceof(item, "Radio") then return "electronics", "class" end

        if anyMatch(typeName, FUEL_NAMES) then return "fuel", "name" end
        if anyMatch(typeName, HYGIENE_NAMES) then return "hygiene", "name" end
        if anyMatch(typeName, COOKING_NAMES) and category ~= "Weapon" then return "cooking", "name" end
        -- household items that BetterSorting files under a crafting/building category
        if anyMatch(typeName, { "aluminumfoil", "aluminiumfoil", "plasticwrap", "wax paper", "waxpaper" }) then return "cooking", "name" end
        if anyMatch(typeName, { "garbagebag", "trashbag", "plasticbag", "paperbag", "ziploc" }) then return "container", "name" end

        local display = tostring(item:getDisplayCategory() or "")
        local hint = CATEGORY_HINT[display]

        if category == "Weapon" or (item.IsWeapon and item:IsWeapon()) then
            -- hammers, axes, crowbars are weapons too; the tag check above already caught tools
            if hint == "tool" or hint == "cooking" or hint == "build_material" or hint == "mechanics" or hint == "junk" then
                return hint, "weapon+hint"
            end
            if anyMatch(typeName, { "axe", "hatchet", "machete", "shovel", "spade", "hoe", "rake", "pick" }) then
                return "tool", "weapon+name"
            end
            return "weapon", "class"
        end
        if anyMatch(typeName, MECH_NAMES) and (hint == "mechanics" or hint == nil or hint == "other") then
            return "mechanics", "name"
        end
        if anyMatch(typeName, BUILD_NAMES) and (hint == "build_material" or hint == nil or hint == "other") then
            return "build_material", "name"
        end
        if hint then return hint, "displaycategory:" .. display end
        if category == "Drainable" then return "hygiene", "drainable" end
        return "other", "fallback"
    end)
    if not ok then
        BKLog.warn("classify failed for " .. tostring(item) .. ": " .. tostring(res))
        return "other", "error", false, "other"
    end
    -- the fine group: catalog first, else a guess from the type name within the class, else the class default;
    -- live states that change the class take their own group so companions line up (empties with empties)
    local group
    if res == "empties" or res == "trash" then
        group = res
    elseif forced then
        group = forced
    elseif entry then
        group = entry.g
    else
        local okT, tn = pcall(function() return item:getType() end)
        group = BKTaxonomy.guess(okT and tn or "", res)
    end
    return res, why, SURE_REASONS[why] == true, group
end

-- The fine group alone (BKTaxonomy key). Same cost as classify.
function BKItemClass.groupOf(item)
    local _, _, _, group = BKItemClass.classify(item)
    return group or "other"
end

function BKItemClass.groupLabel(group)
    return BKTaxonomy.label(group)
end

function BKItemClass.isFood(class)
    return class == "food_frozen" or class == "food_freezable" or class == "food_perishable"
        or class == "food_canned" or class == "food_dry" or class == "drink"
end

return BKItemClass
