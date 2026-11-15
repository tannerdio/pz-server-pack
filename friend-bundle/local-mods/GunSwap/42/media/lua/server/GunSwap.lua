-- Gun Swap. Server side (and solo); does nothing on a multiplayer client.
--
-- Escape From Zomboid Firearms (EFZ) already replaces base-game guns and ammo, but only in rooms
-- nobody has seen yet, and it does not know the Vanilla Firearms Expansion (VFE) items at all.
-- This walks every chunk once as it loads, plus every vehicle and every freshly filled container,
-- and replaces unwanted guns, magazines, attachments and ammo with EFZ items of the same kind,
-- using EFZ's own loot draw. Player inventories are never walked.

if isClient() then return end
if not getActivatedMods():contains("EscapeFromZomboidFirearms") then
    print("[GunSwap] Escape From Zomboid Firearms is not active; nothing to do.")
    return
end

local okLoot, Loot = pcall(require, "TW/Loot")
local okItems, LI = pcall(require, "TW/LootItems")
pcall(require, "TW_LootFill")
if not okLoot or not okItems or type(Loot) ~= "table" or type(LI) ~= "table" then
    print("[GunSwap] could not load the EFZ loot modules; nothing to do.")
    return
end

GunSwap = GunSwap or {}
local G = GunSwap
G.VERSION = 1
G.stats = { chunks = 0, vehicles = 0, replaced = 0, kept = 0, unwrapped = 0 }

-- VFE item (and Improvised Silencers part) -> the base-game item whose EFZ replacement it gets.
-- Base-game names that VFE merely overrides (Shotgun, Pistol, AssaultRifle, ...) are already in
-- EFZ's own list and need no entry here.
local ANCHOR = {}
local function map(anchor, names)
    for _, name in ipairs(names) do ANCHOR["Base." .. name] = anchor end
end
map("Shotgun", { "Shotgun2", "Shotgun2Bayonet", "ShotgunSemi", "ShotgunSemi2", "ShotgunSawnoffNoStock",
    "DoubleBarrelShotgunSawnoffNoStock", "Spas12", "Spas12Folded", "ShotgunSilent",
    "AssaultRifleMasterkeyShotgun", "M2400_Shotgun" })
map("AssaultRifle", { "AK47", "AK47Unfolded", "AK47Folded", "MAK90", "SKS", "SKSSpiker", "SKSSpikerBayonet",
    "1022", "Mini14", "Mini14Unfolded", "Mini14Folded", "FAL", "FALClassic", "CAR15", "CAR15Folded", "CAR15D",
    "CAR15DFolded", "AssaultRifleM1", "AssaultRifleBayonet", "AssaultRifleMasterkey", "M60MMG", "M60MMG_Bipod",
    "CampCarbine", "LeverRifle", "LeverRifle2", "MP5", "MP5SD", "MP5Unfolded", "MP5Folded", "MAC10Unfolded",
    "MAC10Folded", "UziUnfolded", "UziFolded" })
map("HuntingRifle", { "SniperRifle", "M2400_Rifle" })
map("Pistol", { "Tec9", "MK23SOCOM", "Glock", "Glock18", "P229", "CZ75", "MK2", "MK2SD" })
map("556Clip", { "762Clip", "223Clip20", "22ClipRifle", "308Clip", "FALClip", "M60Belt", "9mmClip30",
    "9mmClip32", "45Clip32" })
map("9mmClip", { "22ClipPistol", "45Clip12", "9mmClip20", "9mmClip13", "9mmClip16", "9mmClip17" })
map("556Bullets", { "762Bullets", "223Bullets" })
map("556Box", { "762Box", "223Box", "556BattlePack" })
map("556Carton", { "762Carton", "223Carton" })
map("Bullets9mm", { "22Bullets" })
map("Bullets9mmBox", { "22Box" })
map("Bullets9mmCarton", { "22Carton" })
map("308Bullets", { "308BulletsLinked" })
map("Laser", { "LaserOn" })
map("RecoilPad", { "Sling", "Sling2", "Bipod", "ShellHolder", "IronSight", "FiberglassStock", "LightenedStock",
    "ShellStraps", "M60BrassCatcher", "Coupled556", "Coupled762", "Silencer", "MetalPipeSilencer",
    "TorchSilencer", "WaterBottleSilencer", "PotatoSilencer" })

-- VFE gun cases and ammo cans disappear with their contents when VFE is removed, so they are
-- emptied into whatever holds them and taken away.
local UNWRAP = {}
for i = 1, 11 do UNWRAP["Base.VFERifleCase" .. i] = true end
for i = 1, 3 do
    UNWRAP["Base.VFEShotgunCase" .. i] = true
    UNWRAP["Base.VFEPistolCase" .. i] = true
end
UNWRAP["Base.VFEAmmoCanNarrow"] = true
UNWRAP["Base.VFEAmmoCanNarrow_Toolkit"] = true
UNWRAP["Base.VFEAmmoCanWide"] = true

local function anchorOf(fullType)
    local anchor = ANCHOR[fullType]
    if anchor then return anchor end
    if Loot.vanillaSet(fullType) then return fullType end
    return nil
end
G.anchorOf = anchorOf

-- EFZ items for one unwanted item. choices: per-container memory, so a pile of loose rounds
-- becomes one kind of round and not thirty different ones.
local function replacements(item, anchor, ctx, o, rng, choices)
    local isWeapon = instanceof(item, "HandWeapon")
    local key = item:getFullType()
    local choice = (not isWeapon) and choices and choices[key] or nil
    if not choice then
        choice = Loot.replacement(anchor, ctx, o, rng, true)
        if not choice then return nil end
        if choices and not isWeapon then choices[key] = choice end
    end
    local items = LI.create(choice)
    if isWeapon then
        local weapon = items[1]
        if weapon and instanceof(weapon, "HandWeapon") then
            LI.condition(item, weapon)
            local max = item:getMaxAmmo() or 0
            local loaded = (max > 0 and item:getCurrentAmmoCount() > 0) and math.min(1, item:getCurrentAmmoCount() / max) or 0
            weapon:getModData().TWLootEngine = { mags = 0, boxes = 0, loaded = loaded }
            if TWLootFillAPI and TWLootFillAPI.prepareWeapon then
                TWLootFillAPI.prepareWeapon(weapon, nil, { ctx = ctx, noKit = true }, o, rng)
            end
        end
    end
    return items
end

local function addTo(container, item)
    container:AddItem(item)
    if isServer() then pcall(sendAddItemToContainer, container, item) end
end

local function removeFrom(container, item)
    if isServer() then pcall(sendRemoveItemFromContainer, container, item) end
    container:Remove(item)
end

-- One container and the bags in it. Returns how many items were replaced.
function G.container(container, ctx, o, rng, depth)
    depth = depth or 0
    if not container or depth > 3 then return 0 end
    local items = container:getItems()
    local list = {}
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    local choices, n = {}, 0
    for _, item in ipairs(list) do
        local fullType = item:getFullType()
        if instanceof(item, "InventoryContainer") then
            local inner = item:getInventory()
            n = n + G.container(inner, ctx, o, rng, depth + 1)
            if UNWRAP[fullType] and inner then
                local innerItems, moved = inner:getItems(), {}
                for i = 0, innerItems:size() - 1 do moved[#moved + 1] = innerItems:get(i) end
                for _, m in ipairs(moved) do
                    inner:Remove(m)
                    addTo(container, m)
                end
                removeFrom(container, item)
                G.stats.unwrapped = G.stats.unwrapped + 1
            end
        else
            local anchor = anchorOf(fullType)
            if anchor then
                local new = replacements(item, anchor, ctx, o, rng, choices)
                if new and #new > 0 then
                    removeFrom(container, item)
                    for _, r in ipairs(new) do addTo(container, r) end
                    n = n + 1
                else
                    G.stats.kept = G.stats.kept + 1
                end
            end
        end
    end
    return n
end

local function dropOn(sq, item, rng)
    sq:AddWorldInventoryItem(item, 0.2 + rng() * 0.6, 0.2 + rng() * 0.6, 0)
end

local function takeOff(sq, worldObject)
    sq:transmitRemoveItemFromSquare(worldObject)
    worldObject:removeFromWorld()
    worldObject:removeFromSquare()
end

-- One square: furniture and other object containers, corpses, items on the floor.
function G.square(sq, ctx, o, rng)
    local n = 0
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and obj.getContainerCount then
            for c = 0, obj:getContainerCount() - 1 do
                n = n + G.container(obj:getContainerByIndex(c), ctx, o, rng, 0)
            end
        end
    end
    local bodies = sq:getDeadBodys()
    if bodies then
        for i = 0, bodies:size() - 1 do
            local body = bodies:get(i)
            if body and body.getContainer then n = n + G.container(body:getContainer(), ctx, o, rng, 0) end
        end
    end
    local world = sq:getWorldObjects()
    if world and world:size() > 0 then
        local list = {}
        for i = 0, world:size() - 1 do list[#list + 1] = world:get(i) end
        for _, wo in ipairs(list) do
            local item = wo:getItem()
            if item then
                local fullType = item:getFullType()
                if instanceof(item, "InventoryContainer") then
                    local inner = item:getInventory()
                    n = n + G.container(inner, ctx, o, rng, 1)
                    if UNWRAP[fullType] and inner then
                        local innerItems, moved = inner:getItems(), {}
                        for k = 0, innerItems:size() - 1 do moved[#moved + 1] = innerItems:get(k) end
                        for _, m in ipairs(moved) do
                            inner:Remove(m)
                            dropOn(sq, m, rng)
                        end
                        takeOff(sq, wo)
                        G.stats.unwrapped = G.stats.unwrapped + 1
                    end
                else
                    local anchor = anchorOf(fullType)
                    if anchor then
                        local new = replacements(item, anchor, ctx, o, rng, nil)
                        if new and #new > 0 then
                            takeOff(sq, wo)
                            for _, r in ipairs(new) do dropOn(sq, r, rng) end
                            n = n + 1
                        else
                            G.stats.kept = G.stats.kept + 1
                        end
                    end
                end
            end
        end
    end
    return n
end

local function placeOfSquare(sq, cache)
    local room = sq:getRoom()
    if not room then return "civil" end
    local name = tostring(room:getName())
    local ctx = cache[name]
    if not ctx then
        ctx = Loot.placeOf("rooms/" .. name) or "civil"
        cache[name] = ctx
    end
    return ctx
end

-- Chunks ------------------------------------------------------------------------------------
local CHUNK, LEVELS = 8, 9
local DELAY_MS = 4000
local SQUARES_PER_TICK = 144
local queue, head, tail, pending = {}, 1, 0, {}
local lastCx, lastCy

local function done()
    return ModData.getOrCreate("GunSwapWorld")
end

-- Returns true when the chunk is finished, false when the budget ran out first.
local function chunkPart(job, budget)
    if not job.next then
        job.next, job.o, job.cache, job.n = 0, Loot.options(), {}, 0
    end
    local cell, rng = getCell(), Loot.rng
    local total = CHUNK * CHUNK * LEVELS
    local i = job.next
    while i < total and budget > 0 do
        local x = job.cx * CHUNK + math.floor(i / (CHUNK * LEVELS))
        local y = job.cy * CHUNK + math.floor(i / LEVELS) % CHUNK
        local z = i % LEVELS - 1
        local sq = cell:getGridSquare(x, y, z)
        if sq then job.n = job.n + G.square(sq, placeOfSquare(sq, job.cache), job.o, rng) end
        i = i + 1
        budget = budget - 1
    end
    job.next = i
    return i >= total, budget
end

local function pump(budget)
    local now = getTimestampMs()
    local marks
    while head <= tail and budget > 0 and queue[head].at <= now do
        local job = queue[head]
        local ok, finished, left = pcall(chunkPart, job, budget)
        if not ok then
            print("[GunSwap] chunk " .. job.key .. " failed: " .. tostring(finished))
            finished, left = true, budget
        end
        budget = left or 0
        if finished then
            marks = marks or done()
            marks[job.key] = G.VERSION
            G.stats.chunks = G.stats.chunks + 1
            if (job.n or 0) > 0 then
                G.stats.replaced = G.stats.replaced + job.n
                print("[GunSwap] chunk " .. job.key .. ": replaced " .. job.n .. " item(s)")
            end
            queue[head] = nil
            head = head + 1
            if head > tail then head, tail = 1, 0 end
        end
    end
end

local function onLoadGridsquare(sq)
    if not sq then return end
    local cx, cy = math.floor(sq:getX() / CHUNK), math.floor(sq:getY() / CHUNK)
    if cx == lastCx and cy == lastCy then return end
    lastCx, lastCy = cx, cy
    local key = cx .. "," .. cy
    if pending[key] then return end
    pending[key] = true
    if done()[key] == G.VERSION then return end
    tail = tail + 1
    queue[tail] = { key = key, cx = cx, cy = cy, at = getTimestampMs() + DELAY_MS }
end

-- Vehicles: trunks, glove boxes and seats. Marked on the vehicle itself, since vehicles move.
local function sweepVehicles()
    local set = getCell() and getCell():getVehicles()
    if not set then return end
    -- getVehicles() is a Set, which Lua cannot index: copy it into a list first.
    local vehicles = ArrayList.new()
    vehicles:addAll(set)
    local o, rng
    for i = 0, vehicles:size() - 1 do
        local vehicle = vehicles:get(i)
        local md = vehicle and vehicle:getModData()
        if md and md.GunSwap ~= G.VERSION then
            md.GunSwap = G.VERSION
            o, rng = o or Loot.options(), rng or Loot.rng
            local n = 0
            for p = 0, vehicle:getPartCount() - 1 do
                local part = vehicle:getPartByIndex(p)
                local container = part and part:getItemContainer()
                if container then
                    local ok, count = pcall(G.container, container, "civil", o, rng, 0)
                    if ok then n = n + count else print("[GunSwap] vehicle part failed: " .. tostring(count)) end
                end
            end
            G.stats.vehicles = G.stats.vehicles + 1
            if n > 0 then
                G.stats.replaced = G.stats.replaced + n
                if vehicle.transmitModData then pcall(vehicle.transmitModData, vehicle) end
                print("[GunSwap] vehicle " .. tostring(vehicle:getScriptName()) .. ": replaced " .. n .. " item(s)")
            end
        end
    end
end

-- Fresh loot: EFZ handles base-game items when a container fills; this catches the VFE ones.
local function onFillContainer(roomName, containerType, container)
    -- Some fills hand over the loot table entry instead of the container: skip those.
    if not container or not instanceof(container, "ItemContainer") then return end
    local ctx = Loot.placeOf("rooms/" .. tostring(roomName)) or "civil"
    local ok, n = pcall(G.container, container, ctx, Loot.options(), Loot.rng, 0)
    if not ok then
        print("[GunSwap] fill failed: " .. tostring(n))
    elseif n > 0 then
        G.stats.replaced = G.stats.replaced + n
    end
end

-- The queue runs a little every tick. If ticks do not reach Lua on this server, the once-a-minute
-- event carries it instead.
local lastTickMs = 0
local function onTick()
    lastTickMs = getTimestampMs()
    if head <= tail then pump(SQUARES_PER_TICK) end
end

local minutes = 0
local function everyMinute()
    minutes = minutes + 1
    if getTimestampMs() - lastTickMs > 5000 and head <= tail then pump(2000) end
    if minutes % 2 == 0 then
        local ok, err = pcall(sweepVehicles)
        if not ok then print("[GunSwap] vehicle sweep failed: " .. tostring(err)) end
    end
    if minutes % 60 == 0 then
        local s = G.stats
        print(string.format("[GunSwap] so far: %d chunks, %d vehicles, %d replaced, %d cases emptied, %d left alone, %d chunks waiting",
            s.chunks, s.vehicles, s.replaced, s.unwrapped, s.kept, tail - head + 1))
    end
end

Events.LoadGridsquare.Add(onLoadGridsquare)
Events.OnFillContainer.Add(onFillContainer)
Events.OnTick.Add(onTick)
Events.EveryOneMinute.Add(everyMinute)

print("[GunSwap] ready (table version " .. G.VERSION .. ")")
