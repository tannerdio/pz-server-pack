-- Base Keeper: the fine-grained purpose taxonomy (v0.12.0, Tanner 2026-11-06: "intelligently sort every item in the
-- game ... bleach and buckets and mops are related, they go there; hatchets, saws, nails, screws, hammers; lugnuts,
-- battery, fuel"). Every item has a coarse class (BKItemClass.CLASSES: what hard rules apply, e.g. cold storage,
-- bins) and a fine group (this file: what it is *for*). BKCatalog maps every vanilla item to its group; mod items are
-- guessed from their class and type name. Groups drive: companion scoring (same group +3, same family +1), per-group
-- container preferences (BKRules.score), fine loot-area / section categories (BKLoot.CATEGORIES), and the labels in
-- the loot browser and export.
BKTaxonomy = BKTaxonomy or {}

-- Families = menu sections and the weak companion tie.
BKTaxonomy.FAMILIES = {
    { key = "food", label = "Food & drink" },
    { key = "kitchen", label = "Kitchen" },
    { key = "workshop", label = "Workshop" },
    { key = "vehicle", label = "Vehicle & fuel" },
    { key = "home", label = "Home, cleaning & care" },
    { key = "medical", label = "Medical" },
    { key = "outdoors", label = "Outdoors & farm" },
    { key = "wardrobe", label = "Clothing" },
    { key = "armory", label = "Armory" },
    { key = "office", label = "Office & media" },
    { key = "misc", label = "Everything else" },
}

-- key, label, family, class (default coarse class; "food"/"drink" are decided live), types (container type ->
-- score, replaces the class score where higher), places (inferred place -> bonus, replaces the class place bonus).
BKTaxonomy.GROUPS = {
    -- food & drink ------------------------------------------------------------------------------------------
    { key = "food_produce", label = "Fruit & vegetables", family = "food", class = "food" },
    { key = "food_meat", label = "Meat & poultry", family = "food", class = "food" },
    { key = "food_fish", label = "Fish & seafood", family = "food", class = "food" },
    { key = "food_dairy", label = "Dairy & eggs", family = "food", class = "food" },
    { key = "food_baked", label = "Bread & baked goods", family = "food", class = "food" },
    { key = "food_meal", label = "Prepared meals", family = "food", class = "food" },
    { key = "food_canned", label = "Canned food", family = "food", class = "food" },
    { key = "food_dry", label = "Dry staples (rice, pasta, flour)", family = "food", class = "food" },
    { key = "food_spice", label = "Spices, sauces & condiments", family = "food", class = "food",
      types = { counter = 7, overhead = 7, cupboard = 7, sidetable = 3 } },
    { key = "food_snack", label = "Snacks & sweets", family = "food", class = "food" },
    { key = "food_herb", label = "Fresh herbs", family = "food", class = "food" },
    { key = "food_forage", label = "Foraged plants & sheaves", family = "food", class = "food",
      types = { crate = 5, shelves = 4, counter = 4, cupboard = 4 } },
    { key = "farm_feed", label = "Animal feed & pet food", family = "outdoors", class = "food",
      types = { crate = 7, metal_shelves = 6, garagestorage = 6, garage_storage = 6 }, places = { garage = 3, storage = 2 } },
    { key = "drink_water", label = "Water", family = "food", class = "drink",
      types = { counter = 6, cupboard = 6, overhead = 5, fridge = 6, crate = 4, metal_shelves = 4 } },
    { key = "drink_soft", label = "Soft drinks & juice", family = "food", class = "drink" },
    { key = "drink_alcohol", label = "Alcohol", family = "food", class = "drink",
      types = { shelves = 6, cupboard = 6, displaycase = 6, counter = 4, sidetable = 4, overhead = 4 } },
    { key = "drink_hot", label = "Coffee, tea & cocoa", family = "food", class = "food",
      types = { counter = 7, overhead = 7, cupboard = 7 } },
    -- kitchen ----------------------------------------------------------------------------------------------
    { key = "cook_ware", label = "Cookware & utensils", family = "kitchen", class = "cooking" },
    -- workshop ---------------------------------------------------------------------------------------------
    { key = "carpentry", label = "Carpentry (hammers, saws, nails, screws)", family = "workshop", class = "tool",
      types = { toolcabinet = 10, garagestorage = 8, garage_storage = 8, metal_shelves = 8, crate = 6, locker = 4, smallbox = 4 },
      places = { garage = 4, storage = 1 } },
    { key = "lumber", label = "Lumber (planks, logs, sticks)", family = "workshop", class = "build_material",
      types = { crate = 8, metal_shelves = 6, garagestorage = 6, garage_storage = 6, smallcrate = 5 }, places = { garage = 3, storage = 2 } },
    { key = "hardware", label = "Hardware, tape & rope", family = "workshop", class = "build_material",
      types = { toolcabinet = 8, metal_shelves = 7, smallbox = 6, crate = 6, garagestorage = 6, garage_storage = 6, officedrawers = 3 },
      places = { garage = 3, storage = 1 } },
    { key = "metalwork", label = "Metalwork & welding", family = "workshop", class = "tool",
      types = { toolcabinet = 8, metal_shelves = 8, garagestorage = 7, garage_storage = 7, crate = 6, locker = 4 }, places = { garage = 4 } },
    { key = "smithing", label = "Blacksmithing (anvils, ingots, ore)", family = "workshop", class = "tool",
      types = { metal_shelves = 8, crate = 7, garagestorage = 6, garage_storage = 6, toolcabinet = 5 }, places = { garage = 3, storage = 2 } },
    { key = "masonry", label = "Masonry & concrete", family = "workshop", class = "build_material",
      types = { crate = 8, metal_shelves = 6, garagestorage = 6, garage_storage = 6, smallcrate = 5 }, places = { garage = 3, storage = 2 } },
    { key = "pottery", label = "Pottery, clay & glass", family = "workshop", class = "build_material",
      types = { crate = 6, shelves = 5, metal_shelves = 5, smallcrate = 5 }, places = { garage = 2, storage = 2 } },
    { key = "painting", label = "Paint & decorating", family = "workshop", class = "build_material",
      types = { metal_shelves = 6, crate = 6, garagestorage = 6, garage_storage = 6, cupboard = 3, locker = 3 }, places = { garage = 3 } },
    { key = "electrical", label = "Electrical & electronics parts", family = "workshop", class = "electronics",
      types = { metal_shelves = 6, toolcabinet = 6, shelves = 5, desk = 5, smallbox = 5, cardboardbox = 4, officedrawers = 4 },
      places = { garage = 2, office = 2 } },
    { key = "stone", label = "Stone & flint", family = "workshop", class = "build_material",
      types = { crate = 6, metal_shelves = 4, smallcrate = 4 }, places = { garage = 2, storage = 2 } },
    { key = "tool_misc", label = "Other tools", family = "workshop", class = "tool" },
    -- vehicle & fuel ---------------------------------------------------------------------------------------
    { key = "mechanics", label = "Vehicle parts (tires, batteries, lug wrench)", family = "vehicle", class = "mechanics" },
    { key = "fuel", label = "Fuel (petrol, propane)", family = "vehicle", class = "fuel" },
    { key = "firewood", label = "Firewood & kindling", family = "vehicle", class = "fuel",
      types = { crate = 7, metal_shelves = 4, garagestorage = 4, garage_storage = 4 }, places = { garage = 2, storage = 2 } },
    -- home -------------------------------------------------------------------------------------------------
    { key = "cleaning", label = "Cleaning (bleach, mops, buckets)", family = "home", class = "hygiene",
      types = { cupboard = 6, overhead = 6, counter = 5, locker = 5, metal_shelves = 5, crate = 4, shelves = 4, medicine = 3 },
      places = { laundry = 5, bathroom = 3, kitchen = 2 } },
    { key = "hygiene", label = "Personal care (toothbrush, razor, makeup)", family = "home", class = "hygiene",
      types = { medicine = 7, sidetable = 5, dresser = 4, cupboard = 3, smallbox = 3 }, places = { bathroom = 4, bedroom = 2 } },
    { key = "sewing", label = "Sewing & tailoring", family = "home", class = "tool",
      types = { dresser = 6, smallbox = 6, wardrobe = 5, sidetable = 4, cardboardbox = 4, crate = 3, shelves = 3 },
      places = { bedroom = 2, laundry = 3 } },
    { key = "leather", label = "Hides & leather", family = "home", class = "build_material",
      types = { crate = 6, metal_shelves = 5, wardrobe = 4, cardboardbox = 3 }, places = { garage = 2, storage = 2 } },
    { key = "household", label = "Linens & household", family = "home", class = "other",
      types = { wardrobe = 5, dresser = 4, cardboardbox = 4, crate = 3, shelves = 3 }, places = { bedroom = 2, laundry = 2 } },
    -- medical ----------------------------------------------------------------------------------------------
    { key = "medical", label = "First aid & medicine", family = "medical", class = "medical" },
    -- outdoors & farm --------------------------------------------------------------------------------------
    { key = "gardening", label = "Farming & gardening (seeds, fertilizer, hoes)", family = "outdoors", class = "tool",
      types = { crate = 7, metal_shelves = 6, garagestorage = 6, garage_storage = 6, shelves = 4, toolcabinet = 4, smallbox = 4 },
      places = { garage = 3, storage = 2 } },
    { key = "farm_animal", label = "Livestock gear", family = "outdoors", class = "tool",
      types = { crate = 5, metal_shelves = 5, garagestorage = 5, garage_storage = 5 }, places = { garage = 2, storage = 2 } },
    { key = "fishing", label = "Fishing", family = "outdoors", class = "tool",
      types = { toolcabinet = 6, crate = 5, metal_shelves = 5, locker = 5, shelves = 4, smallbox = 4 }, places = { garage = 2 } },
    { key = "fish_bait", label = "Bait & critters", family = "outdoors", class = "food" },
    { key = "trapping", label = "Trapping", family = "outdoors", class = "tool",
      types = { crate = 6, metal_shelves = 5, locker = 5, garagestorage = 5, garage_storage = 5 }, places = { garage = 2 } },
    { key = "camping", label = "Camping & outdoors", family = "outdoors", class = "tool",
      types = { crate = 6, locker = 6, metal_shelves = 5, wardrobe = 4, garagestorage = 5, garage_storage = 5 }, places = { garage = 2, storage = 2 } },
    { key = "fire", label = "Lighters & fire starting", family = "outdoors", class = "tool",
      types = { cupboard = 5, smallbox = 5, counter = 4, sidetable = 4, toolcabinet = 4, metal_shelves = 3 }, places = { kitchen = 2 } },
    { key = "lighting", label = "Flashlights, lanterns & candles", family = "outdoors", class = "electronics",
      types = { shelves = 5, sidetable = 5, metal_shelves = 5, cupboard = 4, smallbox = 4, locker = 4 }, places = { garage = 1 } },
    -- wardrobe ---------------------------------------------------------------------------------------------
    { key = "cloth_outer", label = "Jackets & coats", family = "wardrobe", class = "clothing" },
    { key = "cloth_top", label = "Shirts, sweaters & dresses", family = "wardrobe", class = "clothing" },
    { key = "cloth_bottom", label = "Pants, shorts & skirts", family = "wardrobe", class = "clothing" },
    { key = "cloth_shoes", label = "Shoes & boots", family = "wardrobe", class = "clothing",
      types = { wardrobe = 8, shelves = 4, crate = 3 } },
    { key = "cloth_hat", label = "Hats, masks & scarves", family = "wardrobe", class = "clothing" },
    { key = "cloth_under", label = "Underwear & socks", family = "wardrobe", class = "clothing",
      types = { dresser = 10, wardrobe = 8 } },
    { key = "cloth_access", label = "Accessories, glasses & jewelry", family = "wardrobe", class = "clothing",
      types = { dresser = 8, sidetable = 5, smallbox = 5, displaycase = 5, wardrobe = 5 } },
    { key = "cloth_work", label = "Work clothes & uniforms", family = "wardrobe", class = "clothing",
      types = { locker = 8, wardrobe = 7, dresser = 5 }, places = { garage = 2, bedroom = 2 } },
    -- armory -----------------------------------------------------------------------------------------------
    { key = "weapon_melee", label = "Melee weapons", family = "armory", class = "weapon" },
    { key = "weapon_gun", label = "Firearms", family = "armory", class = "weapon" },
    { key = "weapon_part", label = "Gun parts & holsters", family = "armory", class = "weapon",
      types = { gunbox = 9, militarycrate = 8, militarylocker = 8, safe = 6, smallbox = 4, locker = 4 } },
    { key = "ammo", label = "Ammo & magazines", family = "armory", class = "ammo" },
    { key = "explosive", label = "Explosives & bombs", family = "armory", class = "weapon",
      types = { militarycrate = 9, safe = 7, gunbox = 6, metal_shelves = 4, locker = 4 } },
    { key = "armor", label = "Armor & protective gear", family = "armory", class = "clothing",
      types = { militarylocker = 9, locker = 8, wardrobe = 5, crate = 4, militarycrate = 4 }, places = { armory = 3, garage = 1 } },
    -- office & media ---------------------------------------------------------------------------------------
    { key = "lit_skill", label = "Skill books & recipe magazines", family = "office", class = "literature",
      types = { desk = 9, shelvesmag = 9, shelves = 7, filingcabinet = 6, officedrawers = 6 } },
    { key = "lit_read", label = "Novels, comics & magazines", family = "office", class = "literature",
      types = { shelvesmag = 8, shelves = 7, sidetable = 4, cardboardbox = 3 } },
    { key = "lit_map", label = "Maps", family = "office", class = "literature",
      types = { desk = 8, filingcabinet = 8, officedrawers = 7, shelves = 4 } },
    { key = "stationery", label = "Paper & stationery", family = "office", class = "literature",
      types = { desk = 8, officedrawers = 8, filingcabinet = 5, sidetable = 5, smallbox = 4 } },
    { key = "media", label = "Tapes, CDs, radios & TVs", family = "office", class = "electronics",
      types = { shelves = 6, desk = 5, sidetable = 5, cardboardbox = 3, displaycase = 4 }, places = { living = 3, office = 2 } },
    -- everything else --------------------------------------------------------------------------------------
    { key = "bag", label = "Bags & backpacks", family = "misc", class = "container" },
    { key = "box", label = "Boxes, cases & parcels", family = "misc", class = "container" },
    { key = "toys", label = "Toys, games & sports", family = "misc", class = "other",
      types = { shelves = 5, cardboardbox = 5, smallbox = 5, dresser = 3, crate = 3 }, places = { bedroom = 2, living = 2 } },
    { key = "instrument", label = "Musical instruments", family = "misc", class = "other",
      types = { displaycase = 6, shelves = 4, wardrobe = 3, crate = 3 }, places = { living = 2 } },
    { key = "memento", label = "Mementos & decorations", family = "misc", class = "junk" },
    { key = "valuables", label = "Money, jewels & valuables", family = "misc", class = "junk",
      types = { safe = 10, dresser = 5, smallbox = 5, desk = 4, sidetable = 3 } },
    { key = "tobacco", label = "Tobacco & smoking", family = "misc", class = "other",
      types = { sidetable = 5, cupboard = 4, smallbox = 4, shelves = 3, counter = 3 } },
    { key = "keys", label = "Keys & padlocks", family = "misc", class = "other" },
    { key = "furniture", label = "Furniture & fixtures (picked up)", family = "misc", class = "other",
      types = { crate = 4, metal_shelves = 4 }, places = { storage = 2, garage = 1 } },
    { key = "animal_parts", label = "Bones, skulls & feathers", family = "misc", class = "build_material",
      types = { crate = 5, metal_shelves = 4, smallcrate = 4, cardboardbox = 3 }, places = { storage = 2, garage = 1 } },
    { key = "empties", label = "Empty bottles", family = "misc", class = "empties" },
    { key = "depleted", label = "Needs refill", family = "misc", class = "depleted" },
    { key = "junk", label = "Junk & paperwork", family = "misc", class = "junk" },
    { key = "trash", label = "Trash", family = "misc", class = "trash" },
    { key = "ignore", label = "Not sortable", family = "misc", class = "other" },
    { key = "other", label = "Unsorted", family = "misc", class = "other" },
}

BKTaxonomy.BY_KEY = {}
for i, g in ipairs(BKTaxonomy.GROUPS) do
    g.index = i
    BKTaxonomy.BY_KEY[g.key] = g
end

BKTaxonomy.FAMILY_BY_KEY = {}
for i, f in ipairs(BKTaxonomy.FAMILIES) do
    f.index = i
    BKTaxonomy.FAMILY_BY_KEY[f.key] = f
end

-- group for a class the catalog does not know (mod items): what the old single-level sorter would have done
BKTaxonomy.DEFAULT_GROUP = {
    food_frozen = "food_meal", food_freezable = "food_meat", food_perishable = "food_produce", food_canned = "food_canned",
    food_dry = "food_dry", drink = "drink_soft", cooking = "cook_ware", tool = "tool_misc", mechanics = "mechanics",
    fuel = "fuel", build_material = "hardware", medical = "medical", hygiene = "hygiene", clothing = "cloth_top",
    weapon = "weapon_melee", ammo = "ammo", literature = "lit_read", electronics = "electrical", container = "bag",
    empties = "empties", depleted = "depleted", junk = "junk", trash = "trash", other = "other",
}

-- Type-name substrings (lower case) -> group, for items the catalog does not list (other mods). Checked in order;
-- the group's family must agree with the coarse class family to a reasonable degree, so these are specific words.
BKTaxonomy.GUESS = {
    { "bleach", "cleaning" }, { "detergent", "cleaning" }, { "mop", "cleaning" }, { "broom", "cleaning" }, { "sponge", "cleaning" },
    { "cleaning", "cleaning" }, { "bucket", "cleaning" }, { "trashbag", "cleaning" }, { "garbagebag", "cleaning" },
    { "toothbrush", "hygiene" }, { "toothpaste", "hygiene" }, { "razor", "hygiene" }, { "shampoo", "hygiene" },
    { "deodorant", "hygiene" }, { "makeup", "hygiene" }, { "lipstick", "hygiene" }, { "perfume", "hygiene" }, { "cologne", "hygiene" },
    { "bandage", "medical" }, { "pills", "medical" }, { "disinfect", "medical" }, { "antibiotic", "medical" }, { "suture", "medical" },
    { "needle", "sewing" }, { "thread", "sewing" }, { "sewing", "sewing" }, { "fabric", "sewing" }, { "yarn", "sewing" },
    { "leather", "leather" }, { "hide", "leather" },
    { "weld", "metalwork" }, { "blowtorch", "metalwork" }, { "sheetmetal", "metalwork" }, { "metalpipe", "metalwork" },
    { "metalbar", "metalwork" }, { "scrapmetal", "metalwork" }, { "wrench", "metalwork" }, { "pliers", "metalwork" },
    { "anvil", "smithing" }, { "ingot", "smithing" }, { "tongs", "smithing" }, { "bloom", "smithing" }, { "ore", "smithing" },
    { "hammer", "carpentry" }, { "saw", "carpentry" }, { "nails", "carpentry" }, { "screws", "carpentry" }, { "screwdriver", "carpentry" },
    { "axe", "carpentry" }, { "hatchet", "carpentry" }, { "chisel", "carpentry" }, { "drill", "carpentry" }, { "crowbar", "carpentry" },
    { "plank", "lumber" }, { "log", "lumber" }, { "branch", "lumber" }, { "stick", "lumber" },
    { "firewood", "firewood" }, { "kindling", "firewood" }, { "charcoal", "firewood" }, { "twigs", "firewood" },
    { "concrete", "masonry" }, { "mortar", "masonry" }, { "brick", "masonry" }, { "cement", "masonry" }, { "plaster", "masonry" },
    { "stone", "masonry" }, { "gravel", "masonry" }, { "clay", "pottery" },
    { "paint", "painting" }, { "wallpaper", "painting" },
    { "ducttape", "hardware" }, { "tape", "hardware" }, { "rope", "hardware" }, { "twine", "hardware" }, { "wire", "hardware" },
    { "glue", "hardware" }, { "hinge", "hardware" }, { "doorknob", "hardware" }, { "tarp", "hardware" },
    { "electronic", "electrical" }, { "lightbulb", "electrical" }, { "battery", "electrical" }, { "generator", "electrical" },
    { "amplifier", "electrical" }, { "circuit", "electrical" },
    { "tire", "mechanics" }, { "brake", "mechanics" }, { "muffler", "mechanics" }, { "suspension", "mechanics" },
    { "carbattery", "mechanics" }, { "engine", "mechanics" }, { "gastank", "mechanics" }, { "windshield", "mechanics" },
    { "lugwrench", "mechanics" }, { "jack", "mechanics" }, { "tirepump", "mechanics" }, { "headlight", "mechanics" },
    { "petrol", "fuel" }, { "gascan", "fuel" }, { "jerrycan", "fuel" }, { "propane", "fuel" }, { "kerosene", "fuel" },
    { "seed", "gardening" }, { "fertilizer", "gardening" }, { "compost", "gardening" }, { "trowel", "gardening" },
    { "shovel", "gardening" }, { "hoe", "gardening" }, { "rake", "gardening" }, { "wateringcan", "gardening" }, { "scythe", "gardening" },
    { "fishing", "fishing" }, { "lure", "fishing" }, { "bait", "fish_bait" }, { "trap", "trapping" },
    { "tent", "camping" }, { "sleepingbag", "camping" }, { "compass", "camping" }, { "canteen", "camping" },
    { "matches", "fire" }, { "lighter", "fire" }, { "flashlight", "lighting" }, { "torch", "lighting" }, { "lantern", "lighting" },
    { "candle", "lighting" },
    { "scope", "weapon_part" }, { "holster", "weapon_part" }, { "sling", "weapon_part" }, { "suppressor", "weapon_part" },
    { "magazine", "ammo" }, { "clip", "ammo" }, { "bullets", "ammo" }, { "rounds", "ammo" }, { "shells", "ammo" },
    { "rifle", "weapon_gun" }, { "pistol", "weapon_gun" }, { "shotgun", "weapon_gun" }, { "revolver", "weapon_gun" },
    { "carbine", "weapon_gun" }, { "smg", "weapon_gun" },
    { "bomb", "explosive" }, { "molotov", "explosive" }, { "grenade", "explosive" }, { "firecracker", "explosive" },
    { "helmet", "armor" }, { "vest_bullet", "armor" }, { "armour", "armor" }, { "armor", "armor" }, { "gasmask", "armor" },
    { "kneepad", "armor" }, { "elbowpad", "armor" }, { "shoulderpad", "armor" },
    { "jacket", "cloth_outer" }, { "coat", "cloth_outer" }, { "poncho", "cloth_outer" }, { "hoodie", "cloth_top" },
    { "shirt", "cloth_top" }, { "sweater", "cloth_top" }, { "jumper", "cloth_top" }, { "dress", "cloth_top" }, { "vest", "cloth_outer" },
    { "trousers", "cloth_bottom" }, { "pants", "cloth_bottom" }, { "shorts", "cloth_bottom" }, { "skirt", "cloth_bottom" }, { "jeans", "cloth_bottom" },
    { "shoes", "cloth_shoes" }, { "boots", "cloth_shoes" }, { "sneaker", "cloth_shoes" }, { "sandal", "cloth_shoes" },
    { "hat_", "cloth_hat" }, { "cap", "cloth_hat" }, { "beanie", "cloth_hat" }, { "scarf", "cloth_hat" }, { "mask", "cloth_hat" },
    { "socks", "cloth_under" }, { "underwear", "cloth_under" }, { "boxers", "cloth_under" }, { "bra_", "cloth_under" }, { "briefs", "cloth_under" },
    { "glasses", "cloth_access" }, { "gloves", "cloth_access" }, { "necklace", "cloth_access" }, { "ring", "cloth_access" },
    { "earring", "cloth_access" }, { "bracelet", "cloth_access" }, { "watch", "cloth_access" }, { "belt", "cloth_access" },
    { "apron", "cloth_work" }, { "boilersuit", "cloth_work" }, { "overall", "cloth_work" }, { "dungarees", "cloth_work" },
    { "book", "lit_skill" }, { "mag", "lit_skill" }, { "schematic", "lit_skill" }, { "recipe", "lit_skill" },
    { "paperback", "lit_read" }, { "comic", "lit_read" }, { "newspaper", "lit_read" }, { "map", "lit_map" },
    { "pen", "stationery" }, { "pencil", "stationery" }, { "notebook", "stationery" }, { "paper", "stationery" },
    { "vhs", "media" }, { "disc", "media" }, { "cd", "media" }, { "radio", "media" }, { "walkie", "media" }, { "tv", "media" },
    { "headphone", "media" }, { "camera", "media" },
    { "pot", "cook_ware" }, { "pan", "cook_ware" }, { "bowl", "cook_ware" }, { "plate", "cook_ware" }, { "knife", "cook_ware" },
    { "fork", "cook_ware" }, { "spoon", "cook_ware" }, { "mug", "cook_ware" }, { "cup", "cook_ware" }, { "jar", "cook_ware" },
    { "kettle", "cook_ware" }, { "canopener", "cook_ware" }, { "tinopener", "cook_ware" },
    { "whiskey", "drink_alcohol" }, { "wine", "drink_alcohol" }, { "beer", "drink_alcohol" }, { "vodka", "drink_alcohol" },
    { "rum", "drink_alcohol" }, { "gin", "drink_alcohol" }, { "tequila", "drink_alcohol" }, { "bourbon", "drink_alcohol" },
    { "juice", "drink_soft" }, { "pop", "drink_soft" }, { "soda", "drink_soft" }, { "cola", "drink_soft" },
    { "coffee", "drink_hot" }, { "tea", "drink_hot" }, { "cocoa", "drink_hot" },
    { "canned", "food_canned" }, { "tinned", "food_canned" }, { "can_", "food_canned" },
    { "candy", "food_snack" }, { "chocolate", "food_snack" }, { "crisps", "food_snack" }, { "chips", "food_snack" }, { "cookie", "food_snack" },
    { "bread", "food_baked" }, { "cake", "food_baked" }, { "pie", "food_baked" }, { "muffin", "food_baked" }, { "bagel", "food_baked" },
    { "cheese", "food_dairy" }, { "egg", "food_dairy" }, { "milk", "food_dairy" }, { "butter", "food_spice" }, { "yoghurt", "food_dairy" },
    { "fish", "food_fish" }, { "salmon", "food_fish" }, { "shrimp", "food_fish" }, { "lobster", "food_fish" },
    { "meat", "food_meat" }, { "steak", "food_meat" }, { "chicken", "food_meat" }, { "pork", "food_meat" }, { "beef", "food_meat" },
    { "bacon", "food_meat" }, { "sausage", "food_meat" }, { "ham", "food_meat" }, { "turkey", "food_meat" }, { "venison", "food_meat" },
    { "salt", "food_spice" }, { "pepper", "food_spice" }, { "sauce", "food_spice" }, { "sugar", "food_spice" }, { "oil", "food_spice" },
    { "vinegar", "food_spice" }, { "ketchup", "food_spice" }, { "mustard", "food_spice" }, { "honey", "food_spice" }, { "jam", "food_spice" },
    { "rice", "food_dry" }, { "pasta", "food_dry" }, { "flour", "food_dry" }, { "cereal", "food_dry" }, { "oats", "food_dry" }, { "beans", "food_dry" },
    { "dogfood", "farm_feed" }, { "catfood", "farm_feed" }, { "feed", "farm_feed" },
    { "toy", "toys" }, { "dice", "toys" }, { "ball", "toys" }, { "doll", "toys" }, { "cards", "toys" },
    { "guitar", "instrument" }, { "violin", "instrument" }, { "drum", "instrument" }, { "flute", "instrument" },
    { "cigarette", "tobacco" }, { "cigar", "tobacco" }, { "tobacco", "tobacco" },
    { "money", "valuables" }, { "gold", "valuables" }, { "silver", "valuables" }, { "diamond", "valuables" }, { "gem", "valuables" },
    { "key", "keys" }, { "mov_", "furniture" }, { "skull", "animal_parts" }, { "bone", "animal_parts" }, { "feather", "animal_parts" },
}

function BKTaxonomy.get(key)
    return key and BKTaxonomy.BY_KEY[key] or nil
end

function BKTaxonomy.label(key)
    local g = BKTaxonomy.get(key)
    return g and g.label or tostring(key or "?")
end

function BKTaxonomy.familyOf(key)
    local g = BKTaxonomy.get(key)
    return g and g.family or "misc"
end

function BKTaxonomy.familyLabel(key)
    local f = BKTaxonomy.FAMILY_BY_KEY[key]
    return f and f.label or tostring(key or "?")
end

-- Fine group for an item the catalog does not know: a type-name word whose group's class agrees with the coarse
-- class (so "pot" on a weapon does not make it cookware), else the class default.
function BKTaxonomy.guess(typeName, class)
    local lower = string.lower(tostring(typeName or ""))
    for _, pair in ipairs(BKTaxonomy.GUESS) do
        if string.find(lower, pair[1], 1, true) then
            local g = BKTaxonomy.get(pair[2])
            if g and (g.class == class or g.class == "food" and BKItemClass and BKItemClass.isFood and BKItemClass.isFood(class)
                    or g.class == "drink" and class == "drink" or class == "other" or class == "junk") then
                return pair[2]
            end
        end
    end
    return BKTaxonomy.DEFAULT_GROUP[class] or "other"
end

-- Class-level keys a fine group answers to in loot areas / sections: its own "g:<key>" and the item's coarse class.
function BKTaxonomy.groupKey(group)
    return "g:" .. tostring(group)
end

return BKTaxonomy
