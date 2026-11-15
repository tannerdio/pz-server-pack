-- Base Keeper: item class x container -> score. Higher is better; <= 0 means "do not put it there".
-- Two layers: the container type (a fridge is for perishables wherever it stands) and the inferred place
-- (a crate in the garage is for tools, the same crate in the kitchen is for dry food).
require "BaseKeeper/BKLog"

BKRules = BKRules or {}

-- base score by container type
BKRules.TYPE = {
    fridge = { food_perishable = 10, drink = 6, food_freezable = 4, food_frozen = 1, food_canned = 3, food_dry = 3 },
    freezer = { food_frozen = 10, food_freezable = 9, food_perishable = 3 },
    icecream = { food_frozen = 10, food_freezable = 8 },
    counter = { food_dry = 6, food_canned = 6, cooking = 7, drink = 4 },
    overhead = { food_dry = 6, food_canned = 6, cooking = 6, drink = 4 },
    cupboard = { food_dry = 6, food_canned = 6, cooking = 5, drink = 4 },
    dishescabinet = { cooking = 8, food_dry = 3, food_canned = 3 },
    shelves = { food_dry = 3, food_canned = 3, literature = 5, electronics = 4, other = 3, junk = 2 },
    shelvesmag = { literature = 8 },
    metal_shelves = { mechanics = 8, build_material = 7, tool = 6, fuel = 6, electronics = 4, other = 2, depleted = 5,
        empties = 2 },
    toolcabinet = { tool = 10, mechanics = 6, build_material = 3 },
    garagestorage = { tool = 6, mechanics = 6, build_material = 6, fuel = 7, weapon = 4, ammo = 4, depleted = 5 },
    garage_storage = { tool = 6, mechanics = 6, build_material = 6, fuel = 7, weapon = 4, ammo = 4, depleted = 5 },
    locker = { clothing = 5, weapon = 5, ammo = 5, tool = 4, other = 3 },
    crate = { build_material = 7, tool = 4, mechanics = 4, container = 4, junk = 4, other = 3, fuel = 3, empties = 3,
        depleted = 3 },
    smallcrate = { build_material = 5, tool = 3, other = 3, junk = 3 },
    cardboardbox = { other = 3, junk = 5, electronics = 3, literature = 3, clothing = 2, empties = 3 },
    smallbox = { other = 3, junk = 5, electronics = 3, literature = 3 },
    medicine = { medical = 10, hygiene = 7 },
    wardrobe = { clothing = 10, container = 3 },
    dresser = { clothing = 9 },
    clothingrack = { clothing = 9 },
    sidetable = { literature = 4, electronics = 3, other = 2 },
    desk = { literature = 8, electronics = 5, other = 2 },
    filingcabinet = { literature = 8, other = 2 },
    officedrawers = { literature = 6, electronics = 4, other = 2 },
    displaycase = { other = 2, weapon = 3, electronics = 3 },
    -- junk is not trash (v0.9.0: money and mementos never go in a bin)
    bin = { trash = 10 },
    dumpster = { trash = 9 },
    composter = { trash = 8 }, -- rotten food only (BKPlanner.allowed); below the bin so a bin with room still wins
    militarycrate = { weapon = 9, ammo = 9 },
    militarylocker = { weapon = 9, ammo = 9, clothing = 4 },
    gunbox = { weapon = 9, ammo = 9 },
    safe = { ammo = 5, weapon = 5, other = 2 },
    wardrobe_player = { clothing = 9 },
}

-- bonus by inferred place, applied to any destination container in that place
BKRules.PLACE = {
    kitchen = { food_dry = 3, food_canned = 3, cooking = 3, drink = 2, food_perishable = 1 },
    garage = { tool = 3, mechanics = 3, fuel = 3, build_material = 3, weapon = 1, depleted = 2 },
    bathroom = { medical = 3, hygiene = 3 },
    bedroom = { clothing = 3 },
    office = { literature = 3, electronics = 2 },
    armory = { weapon = 3, ammo = 3 },
    laundry = { clothing = 2, hygiene = 2 },
    storage = { other = 2, junk = 2, container = 2, build_material = 1 },
    living = { literature = 2, electronics = 2 },
}

BKRules.PANTRY_BONUS = { food_dry = 3, food_canned = 3, cooking = 1 }
BKRules.GENERATOR_BONUS = 5 -- fuel in any container near the generator

-- generic containers get the place bonus in full; specialised ones (fridge, medicine...) only a little
BKRules.GENERIC_TYPES = {
    crate = true, smallcrate = true, cardboardbox = true, smallbox = true, shelves = true, metal_shelves = true,
    locker = true, counter = true, overhead = true, cupboard = true, sidetable = true, garagestorage = true,
    garage_storage = true, displaycase = true, other = true,
}

-- A container type we know how to score (so we may also pull misplaced items out of it).
function BKRules.isSortable(ctype)
    return BKRules.TYPE[ctype] ~= nil or BKRules.GENERIC_TYPES[ctype] == true
end

-- v0.12.0: the fine group (BKTaxonomy) can raise the container-type score and replace the place bonus, so bleach
-- prefers the laundry cupboard over a kitchen counter although both are "hygiene" containers.
function BKRules.groupScore(group, c)
    local g = BKTaxonomy and group and BKTaxonomy.get(group) or nil
    if g == nil then return 0, nil end
    local base = g.types and g.types[c.ctype] or 0
    local placeBonus = g.places and g.places[c.place or "storage"] or nil
    return base, placeBonus
end

-- Floor is the baseline: anything on the floor scores 0, so any positive destination wins.
function BKRules.score(class, c, group)
    if c == nil or c.noDest or c.locked then return 0 end
    local base = (BKRules.TYPE[c.ctype] or {})[class] or 0
    local gBase, gPlace = BKRules.groupScore(group, c)
    if gBase > base then base = gBase end
    if base <= 0 and BKRules.GENERIC_TYPES[c.ctype] == nil then return 0 end
    local placeBonus = gPlace or ((BKRules.PLACE[c.place or "storage"] or {})[class] or 0)
    if not BKRules.GENERIC_TYPES[c.ctype] then placeBonus = placeBonus * 0.5 end
    local pantry = (c.pantry and BKRules.PANTRY_BONUS[class]) or 0
    local generator = (class == "fuel" and c.nearGenerator) and BKRules.GENERATOR_BONUS or 0
    if class == "fuel" and c.nearGenerator and base <= 0 then base = 3 end -- even a plain crate by the generator
    local score = base + placeBonus + pantry + generator
    -- an unpowered fridge is a cupboard, an unpowered freezer is worse than a fridge
    if (c.ctype == "fridge" or c.ctype == "freezer" or c.ctype == "icecream") and not c.powered then
        if class == "food_frozen" or class == "food_freezable" or class == "food_perishable" then score = score * 0.4 end
    end
    return score
end

return BKRules
