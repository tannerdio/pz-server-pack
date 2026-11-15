-- Base Keeper: place inference. Decides what each container "is for" from (1) the room definition name when the
-- map provides one and (2) otherwise the fixtures near it (stove, fridge, bed, sink, workbench, vehicle...).
-- Output: every container entry gets .place (kitchen|garage|bathroom|bedroom|office|laundry|armory|storage)
-- and .pantry = true when it is kitchen storage near a stove/fridge.
require "BaseKeeper/BKLog"

BKPlaces = BKPlaces or {}

BKPlaces.RADIUS = 4 -- tiles (Chebyshev) a fixture influences a container

-- room def name substrings -> place
BKPlaces.ROOM_WORDS = {
    { "kitchen", "kitchen" }, { "dining", "kitchen" }, { "cafeteria", "kitchen" }, { "restaurant", "kitchen" },
    { "cafe", "kitchen" }, { "grocer", "kitchen" }, { "pantry", "kitchen" }, { "barn", "garage" },
    { "bathroom", "bathroom" }, { "bath", "bathroom" }, { "toilet", "bathroom" }, { "restroom", "bathroom" },
    { "medical", "bathroom" }, { "pharmacy", "bathroom" }, { "clinic", "bathroom" }, { "hospital", "bathroom" },
    { "bedroom", "bedroom" }, { "dorm", "bedroom" }, { "closet", "bedroom" }, { "motel", "bedroom" },
    { "garage", "garage" }, { "mechanic", "garage" }, { "workshop", "garage" }, { "shed", "garage" },
    { "toolstore", "garage" }, { "hardware", "garage" }, { "carpentry", "garage" }, { "metal", "garage" },
    { "office", "office" }, { "library", "office" }, { "study", "office" }, { "classroom", "office" },
    { "laundry", "laundry" }, { "gunstore", "armory" }, { "armory", "armory" }, { "police", "armory" },
    { "storage", "storage" }, { "warehouse", "storage" }, { "stock", "storage" }, { "attic", "storage" },
    { "basement", "storage" }, { "livingroom", "living" }, { "lounge", "living" },
}

-- fixture kind -> place votes
BKPlaces.FIXTURE_VOTES = {
    stove = { kitchen = 4 }, fridge = { kitchen = 3 }, freezer = { kitchen = 3 }, counter = { kitchen = 1 },
    bed = { bedroom = 4 }, wardrobe = { bedroom = 2 }, water = { bathroom = 2, kitchen = 1 },
    medicine = { bathroom = 3 }, bench = { garage = 3 }, toolcabinet = { garage = 3 }, metal_shelves = { garage = 2 },
    garage = { garage = 3 }, vehicle = { garage = 3 }, desk = { office = 3 }, laundry = { laundry = 3 },
    armory = { armory = 3 }, locker = { storage = 1, garage = 1 }, generator = { garage = 2 },
}
BKPlaces.GENERATOR_RADIUS = 4 -- containers this close to a generator are where fuel goes
BKPlaces.NEAR_RADIUS = 4      -- v0.9.0 flags: nearWater (rain collector/sink), nearBench, nearDoor, nearStove

-- a container's own type votes for its place too (a fridge is kitchen even with nothing around it)
BKPlaces.TYPE_VOTES = {
    fridge = { kitchen = 3 }, freezer = { kitchen = 3 }, icecream = { kitchen = 3 }, stove = { kitchen = 3 },
    microwave = { kitchen = 3 }, dishescabinet = { kitchen = 2 }, counter = { kitchen = 1 }, overhead = { kitchen = 1 },
    toolcabinet = { garage = 3 }, metal_shelves = { garage = 1 }, garagestorage = { garage = 3 },
    garage_storage = { garage = 3 }, medicine = { bathroom = 3 }, wardrobe = { bedroom = 2 }, dresser = { bedroom = 2 },
    clothingrack = { bedroom = 2 }, desk = { office = 2 }, filingcabinet = { office = 2 }, officedrawers = { office = 2 },
    militarycrate = { armory = 3 }, militarylocker = { armory = 3 }, gunbox = { armory = 3 },
    clothingwasher = { laundry = 3 }, clothingdryer = { laundry = 3 },
}

local function roomPlace(room)
    if not room then return nil end
    for _, pair in ipairs(BKPlaces.ROOM_WORDS) do
        if string.find(room, pair[1], 1, true) then return pair[2] end
    end
    return "storage"
end

local function addVotes(votes, src, weight)
    if not src then return end
    for place, v in pairs(src) do votes[place] = (votes[place] or 0) + v * (weight or 1) end
end

local function best(votes)
    local bestPlace, bestScore = "storage", 0
    for place, score in pairs(votes) do
        if score > bestScore then bestPlace, bestScore = place, score end
    end
    return bestPlace, bestScore
end

local function near(a, b, r)
    return a.z == b.z and math.abs(a.x - b.x) <= r and math.abs(a.y - b.y) <= r
end

-- Annotates scan.containers in place. Returns a summary table place -> count for logging.
function BKPlaces.infer(scan)
    local summary = {}
    for _, c in ipairs(scan.containers) do
        local votes = {}
        local fromRoom = roomPlace(c.room)
        if fromRoom and fromRoom ~= "storage" then votes[fromRoom] = (votes[fromRoom] or 0) + 5 end
        addVotes(votes, BKPlaces.TYPE_VOTES[c.ctype], 1)
        local hasStoveOrFridge = false
        c.nearGenerator = false
        c.nearWater, c.nearBench, c.nearDoor, c.nearStove = false, false, false, false
        for _, f in ipairs(scan.fixtures) do
            if near(c, f, BKPlaces.NEAR_RADIUS) then
                if f.kind == "rainwater" or f.kind == "water" then c.nearWater = true end
                if f.kind == "bench" then c.nearBench = true end
                if f.kind == "door" then c.nearDoor = true end
                if f.kind == "stove" and not (f.x == c.x and f.y == c.y) then c.nearStove = true end
            end
            if near(c, f, BKPlaces.RADIUS) and not (f.x == c.x and f.y == c.y) then
                local dist = math.max(math.abs(c.x - f.x), math.abs(c.y - f.y))
                addVotes(votes, BKPlaces.FIXTURE_VOTES[f.kind], dist <= 2 and 1 or 0.5)
                if (f.kind == "stove" or f.kind == "fridge" or f.kind == "freezer") and dist <= 3 then
                    hasStoveOrFridge = true
                end
                if f.kind == "generator" and dist <= BKPlaces.GENERATOR_RADIUS then c.nearGenerator = true end
            end
        end
        local place, score = best(votes)
        if score == 0 then place = fromRoom or "storage" end
        c.place = place
        c.placeScore = score
        c.pantry = (place == "kitchen") and hasStoveOrFridge
            and (c.ctype == "counter" or c.ctype == "overhead" or c.ctype == "shelves" or c.ctype == "cupboard"
                or c.ctype == "dishescabinet" or c.ctype == "crate" or c.ctype == "metal_shelves")
        summary[place] = (summary[place] or 0) + 1
    end
    return summary
end

return BKPlaces
