-- Base Keeper: the sorter. One batch per game minute per zone, no NPC. The floor inside the zone is the inbox.
-- Keeps a per-zone job queue from BKPlanner and a "moved recently" memory so items never ping-pong.
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/Engine/BKPlanner"

if isClient() then return end

BKKeeper = BKKeeper or {}
BKKeeper.plans = {}            -- zoneId -> { jobs = {...}, atMs = n, cursor = i }
BKKeeper.moved = {}            -- itemId -> world hours when the keeper last moved it
BKKeeper.BATCH_MAX = 4         -- items per game minute
BKKeeper.REPLAN_MS = 30000     -- real ms between plans when the queue runs dry
BKKeeper.IDLE_REPLAN_MS = 12000
BKKeeper.NO_CHURN_HOURS = 24   -- leave a moved item alone for a game day

local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

local function worldHours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and tonumber(h) or 0
end

local function itemId(item)
    local ok, id = pcall(function() return item:getID() end)
    return ok and id or nil
end

-- v0.19.0 multiplayer: on a server every container change is sent to the clients with the same calls vanilla's
-- server-side actions use (shared/TimedActions: container:Remove + sendRemoveItemFromContainer, AddItem +
-- sendAddItemToContainer). Single player has one Lua state and needs neither.
local function netRemove(container, item)
    if isServer() and sendRemoveItemFromContainer and container then pcall(sendRemoveItemFromContainer, container, item) end
end

local function netAdd(container, item)
    if isServer() and sendAddItemToContainer and container then pcall(sendAddItemToContainer, container, item) end
end

BKKeeper.backoff = {}          -- itemId -> world hours until the keeper may try this item again
BKKeeper.refused = {}          -- destination key -> { itemId -> world hours until that destination may be tried for the item }
BKKeeper.lastLeft = {}         -- zoneId -> last "N left (...)" summary logged, so idle replans do not spam
BKKeeper.NO_ROOM_BACKOFF_HOURS = 1    -- destination was full at move time: that destination is off for this item
BKKeeper.DUP_ID_BACKOFF_HOURS = 24    -- destination already holds this item id (engine refuses it)

-- Reason string when the item must be left alone, false otherwise (BKPlanner.skipPredicate).
function BKKeeper.recentlyMoved(item)
    local id = itemId(item)
    if not id then return false end
    local until_ = BKKeeper.backoff[id]
    if until_ ~= nil and worldHours() < until_ then return "backoff" end
    local at = BKKeeper.moved[id]
    if at == nil or (worldHours() - at) >= BKKeeper.NO_CHURN_HOURS then return false end
    -- the keeper only ever puts things into containers (piles are exempt from this memory), so an item that is
    -- back on the floor was taken out by the player and is inbox again
    local okW, wobj = pcall(function() return item:getWorldItem() end)
    if okW and wobj ~= nil then return false end
    return "recently moved"
end

local function backOff(item, hours)
    local id = itemId(item)
    if id then BKKeeper.backoff[id] = worldHours() + hours end
end

local function destKey(c)
    return string.format("%s@%s,%s,%s#%s", tostring(c.ctype), tostring(c.x), tostring(c.y), tostring(c.z), tostring(c.index))
end

-- A destination that refused an item at move time is skipped for that item in the next plans, so the planner
-- picks the next best container or a pile instead of retrying the same full box forever.
local function refuse(c, item, hours)
    local id = itemId(item)
    if not id then return end
    local key = destKey(c)
    BKKeeper.refused[key] = BKKeeper.refused[key] or {}
    BKKeeper.refused[key][id] = worldHours() + hours
end

function BKKeeper.refusedRecently(c, item)
    local t = BKKeeper.refused[destKey(c)]
    if t == nil then return false end
    local id = itemId(item)
    local until_ = id and t[id]
    return until_ ~= nil and worldHours() < until_
end

BKPlanner.skipPredicate = BKKeeper.recentlyMoved
BKPlanner.refusedPredicate = BKKeeper.refusedRecently

-- Planning -------------------------------------------------------------------------------------------------

local function jobStillValid(job)
    local ok, valid = pcall(function()
        if job.item == nil or job.dst == nil then return false end
        if job.pile then
            if job.dst.square == nil then return false end
        elseif job.dst.container == nil then
            return false
        end
        if job.srcKind == "floor" then
            -- floor items usually have no container at all; src is only checked when both sides know one
            if job.item:getWorldItem() == nil then return false end
            local holder = job.item:getContainer()
            if holder ~= nil and job.src ~= nil and holder ~= job.src then return false end
        else
            if job.src == nil or job.item:getContainer() ~= job.src then return false end
        end
        return true
    end)
    return ok and valid == true
end

-- v0.18.0 "Sort now" (Tanner 2026-11-13, option 3: containers stay untouched except when he asks). A pass per zone:
-- while BKKeeper.resort[zone.id] exists every plan runs the container tidy-ups (loot zone migration and eviction,
-- section pulls, fridge surplus to freezer, cold storage eviction, bin rescue), the zone moves RESORT_BATCHES
-- batches a game minute instead of one, and replans as soon as its queue is empty. The pass ends by itself on the
-- first fully loaded plan that finds no container move left (or after RESORT_MAX_PLANS plans). Not saved: a reload
-- ends it.
BKKeeper.resort = {}
BKKeeper.RESORT_BATCHES = 8
BKKeeper.RESORT_REPLAN_MS = 2000
BKKeeper.RESORT_MAX_PLANS = 200

-- Multiplayer: the pass lives on the server, so every client is told where it stands (the panel's button label and
-- the "finished" halo of the player who asked). state = "run" | "done".
local function sendPass(zoneId, state, pass, why)
    if not isServer() or not sendServerCommand then return end
    pcall(sendServerCommand, "BaseKeeper", "sortState",
        { id = zoneId, state = state, moved = pass and pass.moved or 0, why = why })
end

function BKKeeper.sortNow(zone)
    local running = BKKeeper.resort[zone.id]
    if running then
        -- a second click (multiplayer: the client button cannot see the pass) must not reset the count or the plan
        BKLog.info("sort now: zone " .. tostring(zone.id) .. " is already running, click ignored")
        sendPass(zone.id, "run", running)
        return
    end
    BKKeeper.resort[zone.id] = { moved = 0, plans = 0 }
    BKKeeper.invalidate(zone.id)
    BKLog.info("sort now: zone " .. tostring(zone.id) .. " started (containers are re-sorted once)")
    sendPass(zone.id, "run", BKKeeper.resort[zone.id])
end

function BKKeeper.sorting(zone)
    return zone ~= nil and BKKeeper.resort[zone.id] or nil
end

local function endResort(zone, pass, why)
    BKKeeper.resort[zone.id] = nil
    local text = string.format("Sort now finished: %d item(s) moved out of containers", pass.moved)
    BKLog.info(string.format("sort now: zone %s done (%s), %d item(s) moved out of containers", tostring(zone.id), why, pass.moved))
    sendPass(zone.id, "done", pass, why)
    if not isServer() and HaloTextHelper and getSpecificPlayer then
        local p = getSpecificPlayer(0)
        if p then pcall(HaloTextHelper.addText, p, text) end
    end
end

function BKKeeper.replan(zone, why)
    local pass = BKKeeper.resort[zone.id]
    local ok, result = pcall(BKPlanner.plan, zone, pass and { tidy = true } or nil)
    if pass then
        pass.plans = pass.plans + 1
        if not ok then
            endResort(zone, pass, "plan failed")
        elseif pass.plans >= BKKeeper.RESORT_MAX_PLANS then
            endResort(zone, pass, "plan limit")
        elseif (result.tidyJobs or 0) == 0 and #result.jobs == 0 and (result.scan.missingSquares or 0) == 0 then
            -- #jobs == 0 too: floor and bag jobs of the last plan are finished inside the pass, so "Sort now" with
            -- auto sort off does not end with its own floor jobs still queued (they would never run)
            endResort(zone, pass, "nothing left to move")
        end
    end
    if not ok then
        BKLog.warn("plan failed for zone " .. tostring(zone.id) .. ": " .. tostring(result))
        BKKeeper.plans[zone.id] = { jobs = {}, atMs = nowMs(), cursor = 1 }
        return BKKeeper.plans[zone.id]
    end
    BKKeeper.plans[zone.id] = { jobs = result.jobs, atMs = nowMs(), cursor = 1 }
    if pass and BKKeeper.resort[zone.id] then why = tostring(why) .. ", sort now" end
    local left = BKPlanner.leftSummary(result)
    local leftChanged = left ~= (BKKeeper.lastLeft[zone.id] or "")
    BKKeeper.lastLeft[zone.id] = left
    if #result.jobs > 0 or leftChanged or BKLog.debug then
        BKLog.info(string.format("zone %s replanned (%s): %d jobs%s", tostring(zone.id), tostring(why), #result.jobs,
            left ~= "" and (", " .. left) or ""))
    end
    if BKLog.debug then
        for i, j in ipairs(result.jobs) do BKLog.dbg("  job " .. i .. ": " .. BKPlanner.describeJob(j)) end
    end
    if leftChanged or BKLog.debug then
        -- what stays behind and why, whenever that changes (capped so a cluttered zone does not flood the console)
        for i, l in ipairs(result.left or {}) do
            if i > 15 then BKLog.info(string.format("  left: ... and %d more", #result.left - 15)); break end
            BKLog.info("  left: " .. BKPlanner.describeLeft(l))
        end
    end
    return BKKeeper.plans[zone.id]
end

local function popValid(plan)
    while plan.cursor <= #plan.jobs do
        local job = plan.jobs[plan.cursor]
        plan.cursor = plan.cursor + 1
        if jobStillValid(job) then return job end
    end
    return nil
end

function BKKeeper.nextJob(zone)
    local plan = BKKeeper.plans[zone.id]
    if plan == nil then plan = BKKeeper.replan(zone, "first") end
    local job = popValid(plan)
    if job then return job end
    local wait = (#plan.jobs == 0) and BKKeeper.IDLE_REPLAN_MS or BKKeeper.REPLAN_MS
    if BKKeeper.resort[zone.id] then wait = BKKeeper.RESORT_REPLAN_MS end
    if nowMs() - plan.atMs >= wait then
        plan = BKKeeper.replan(zone, "queue empty")
        return popValid(plan)
    end
    return nil
end

local function sameDest(a, b)
    if a.pile or b.pile then return a.pile == b.pile and a.dst.square == b.dst.square end
    return a.dst.container == b.dst.container
end

-- Up to max jobs sharing src and dst with the given job.
function BKKeeper.batchWith(zone, job, max)
    local out = { job }
    local plan = BKKeeper.plans[zone.id]
    if plan == nil then return out end
    local i = plan.cursor
    while i <= #plan.jobs and #out < max do
        local other = plan.jobs[i]
        if other.src == job.src and sameDest(other, job) and jobStillValid(other) then
            table.insert(out, other)
            table.remove(plan.jobs, i)
        else
            i = i + 1
        end
    end
    return out
end

function BKKeeper.invalidate(zoneId)
    BKKeeper.plans[zoneId] = nil
end

-- Moving ---------------------------------------------------------------------------------------------------

local function refreshSprite(entry)
    if entry and entry.obj and ItemPicker and ItemPicker.updateOverlaySprite then
        pcall(ItemPicker.updateOverlaySprite, entry.obj)
    end
end

-- Same sequence as vanilla ISGrabItemAction:transferItem (single player), so no ghost world object is left behind.
local function liftFromFloor(item, holder)
    local wobj = item:getWorldItem()
    if wobj == nil then return false end
    local sq = wobj:getSquare()
    if holder then pcall(function() holder:DoRemoveItem(item) end) end
    if sq then pcall(function() sq:transmitRemoveItemFromSquare(wobj) end) end
    pcall(function() wobj:removeFromWorld() end)
    pcall(function() wobj:removeFromSquare() end)
    pcall(function() wobj:setSquare(nil) end)
    item:setWorldItem(nil)
    return true
end

-- Put an item back where the job took it from, when the destination refused it after the lift.
local function restore(job, item)
    pcall(function()
        if job.srcKind == "floor" then
            local sq = getCell():getGridSquare(job.srcX, job.srcY, job.srcZ)
            if sq then sq:AddWorldInventoryItem(item, 0.5, 0.5, 0) end
        elseif job.src then
            job.src:AddItem(item)
            netAdd(job.src, item)
        end
    end)
end

-- The engine refuses AddItem when the container already holds an item with the same id ("container already has id").
local function destHasId(dest, item)
    local ok, has = pcall(function() return dest:containsID(item:getID()) end)
    return ok and has == true
end

-- Container space: the planner's own test against the live container, so plan and move never disagree.
local function hasRoom(dest, item)
    return BKPlanner.fitsLive(dest, item)
end

function BKKeeper.moveItem(job)
    local ok, res = pcall(function()
        local item, dest = job.item, job.dst.container
        local holder = item:getContainer()
        if job.pile then
            -- floor -> floor: a pile on a free tile next to the container the item wants (which is full)
            local sq = job.dst.square
            if sq == nil then return false end
            if job.srcKind == "bag" then
                if holder ~= job.src then return false end
                job.src:Remove(item)
                netRemove(job.src, item)
            elseif not liftFromFloor(item, holder) then
                return false
            end
            local ox = ZombRandFloat and ZombRandFloat(0.15, 0.85) or 0.5
            local oy = ZombRandFloat and ZombRandFloat(0.15, 0.85) or 0.5
            sq:AddWorldInventoryItem(item, ox, oy, 0)
            -- not added to the no-churn memory on purpose: it should move into the container as soon as room frees
            return item:getWorldItem() ~= nil
        end
        if not hasRoom(dest, item) then
            local okW, free, w = pcall(function()
                return dest:getCapacity() - dest:getCapacityWeight(), item:getActualWeight()
            end)
            BKLog.info(string.format("skip: no room (free %s, item %s), this destination is off for the item for %dh: %s",
                okW and string.format("%.2f", free) or "?", okW and string.format("%.2f", w) or "?",
                BKKeeper.NO_ROOM_BACKOFF_HOURS, BKPlanner.describeJob(job)))
            refuse(job.dst, item, BKKeeper.NO_ROOM_BACKOFF_HOURS)
            return false
        end
        if destHasId(dest, item) then
            BKLog.info(string.format("skip: destination already holds an item with this id, retry in %dh: %s",
                BKKeeper.DUP_ID_BACKOFF_HOURS, BKPlanner.describeJob(job)))
            backOff(item, BKKeeper.DUP_ID_BACKOFF_HOURS)
            return false
        end
        if job.srcKind == "floor" then
            if not liftFromFloor(item, holder) then return false end
        else
            if holder ~= job.src then return false end
            job.src:Remove(item)
            netRemove(job.src, item)
            refreshSprite(job.srcEntry)
        end
        dest:AddItem(item)
        if item:getContainer() ~= dest then
            restore(job, item)
            BKLog.warn("destination refused the item, put back: " .. BKPlanner.describeJob(job))
            return false
        end
        netAdd(dest, item)
        pcall(function() dest:setHasBeenLooted(true) end)
        refreshSprite(job.dst)
        local id = itemId(item)
        if id then BKKeeper.moved[id] = worldHours() end
        return true
    end)
    if not ok then BKLog.warn("move failed: " .. tostring(res)); return false end
    return res == true
end

-- One-time return (v0.8.5, Tanner 2026-11-05: "1 time sort the items back to their zones it already sorted").
-- Rebuilt from console.txt (every zone 5/6 -> zone 1 move of the 2026-11-05 evening session) + the day-53 export.
-- Each row: full type, count, tiles to look on (containers there, then floor items there), floor tile to drop on
-- (the tile the item was lifted from). Items are interchangeable copies, so any matching copy counts. Runs once per
-- save (ModData BaseKeeperOnce.returnV085) as soon as every tile is loaded; the zone the item lands in then sorts it
-- within itself.
BKKeeper.RETURN_V085 = {
    { "Base.PetrolCan", 1, { { 8792, 11607 } }, { 8791, 11611 } },
    { "Base.PetrolCan", 2, { { 8793, 11607 } }, { 8798, 11611 } },
    { "Base.ChickenFeather", 4, { { 8788, 11600 } }, { 8796, 11615 } },
    { "Base.ChickenFeather", 4, { { 8788, 11600 } }, { 8796, 11617 } },
    { "Base.Dung_Chicken", 2, { { 8788, 11600 } }, { 8797, 11618 } },
    { "Base.WateredCan", 1, { { 8797, 11601 } }, { 8788, 11612 } },
    { "Bicycle.Bicycle_Crate", 1, { { 8797, 11609 } }, { 8801, 11616 } },
    { "Base.Mop", 1, { { 8794, 11601 } }, { 8794, 11617 } },
    { "Base.Spork", 1, { { 8788, 11598 } }, { 8807, 11612 } },
    { "Base.UnusableWood", 4, { { 8794, 11608 } }, { 8798, 11614 } },
    { "Base.UnusableWood", 4, { { 8794, 11608 } }, { 8801, 11616 } },
    { "Base.WoodenCrudeBenchVisePartsMold", 1, { { 8794, 11608 } }, { 8801, 11616 } },
    { "Base.HandShovel", 1, { { 8795, 11609 } }, { 8788, 11612 } },
    { "Base.Shovel2", 1, { { 8798, 11606 }, { 8799, 11605 } }, { 8788, 11612 } },
    { "Base.ClayTool_Carved", 5, { { 8799, 11604 }, { 8799, 11606 }, { 8798, 11604 }, { 8798, 11606 },
        { 8795, 11609 }, { 8799, 11605 } }, { 8807, 11599 } },
}

local function fullType(item)
    local ok, t = pcall(function() return item:getFullType() end)
    return ok and t or nil
end

-- Up to n copies of ftype on the tile: { {item, container, obj} | {item, floor = true} }
local function findOnTile(sq, ftype, n, out)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local count = (obj.getContainerCount and obj:getContainerCount()) or 0
        if count == 0 and obj.getContainer and obj:getContainer() then count = 1 end
        for ci = 0, count - 1 do
            local cont = (count == 1 and obj:getContainer()) or obj:getContainerByIndex(ci)
            local items = cont and cont:getItems()
            for k = 0, (items and items:size() or 0) - 1 do
                if #out >= n then return end
                local it = items:get(k)
                if fullType(it) == ftype then table.insert(out, { item = it, container = cont, obj = obj }) end
            end
        end
    end
    local wobs = sq:getWorldObjects()
    for i = 0, wobs:size() - 1 do
        if #out >= n then return end
        local it = wobs:get(i):getItem()
        if it and fullType(it) == ftype then table.insert(out, { item = it, floor = true }) end
    end
end

function BKKeeper.returnOnce()
    local md = ModData.getOrCreate("BaseKeeperOnce")
    if md.returnV085 then return end
    local cell = getCell()
    -- wait until every tile involved is loaded, so nothing is skipped for being out of range
    for _, row in ipairs(BKKeeper.RETURN_V085) do
        for _, t in ipairs(row[3]) do if cell:getGridSquare(t[1], t[2], 0) == nil then return end end
        if cell:getGridSquare(row[4][1], row[4][2], 0) == nil then return end
    end
    md.returnV085 = true -- set first: whatever happens below, it never runs twice
    local total, wanted = 0, 0
    for _, row in ipairs(BKKeeper.RETURN_V085) do
        local ftype, n, from, to = row[1], row[2], row[3], row[4]
        wanted = wanted + n
        local found = {}
        for _, t in ipairs(from) do
            if #found >= n then break end
            pcall(findOnTile, cell:getGridSquare(t[1], t[2], 0), ftype, n, found)
        end
        local dest = cell:getGridSquare(to[1], to[2], 0)
        local moved = 0
        for _, f in ipairs(found) do
            local ok = pcall(function()
                if f.floor then
                    if not liftFromFloor(f.item, f.item:getContainer()) then error("lift") end
                else
                    f.container:Remove(f.item)
                    refreshSprite({ obj = f.obj })
                end
                local ox = ZombRandFloat and ZombRandFloat(0.15, 0.85) or 0.5
                local oy = ZombRandFloat and ZombRandFloat(0.15, 0.85) or 0.5
                dest:AddWorldInventoryItem(f.item, ox, oy, 0)
            end)
            if ok then moved = moved + 1 else BKLog.warn("return: could not move " .. ftype) end
        end
        total = total + moved
        BKLog.info(string.format("return: %d/%d %s -> floor @%d,%d", moved, n, ftype, to[1], to[2]))
    end
    BKLog.info(string.format("return done: %d of %d items back in the zone they came from", total, wanted))
    BKKeeper.plans = {}
end

local function tickZone(zone)
    local rounds = BKKeeper.resort[zone.id] and BKKeeper.RESORT_BATCHES or 1
    for _ = 1, rounds do
        local job = BKKeeper.nextJob(zone)
        if job == nil then return end
        local batch = BKKeeper.batchWith(zone, job, BKKeeper.BATCH_MAX)
        local moved = 0
        for _, j in ipairs(batch) do if BKKeeper.moveItem(j) then moved = moved + 1 end end
        local pass = BKKeeper.resort[zone.id]
        if pass and job.srcEntry ~= nil then pass.moved = pass.moved + moved end
        BKLog.info(string.format("zone %s: moved %d/%d -> %s(%s) @%d,%d  [%s]", tostring(zone.id), moved, #batch,
            job.dst.ctype, job.dst.place or "?", job.dst.x, job.dst.y, BKPlanner.describeJob(job)))
    end
end

-- v0.17.0 auto sort switch (Base Keeper panel). Off = the sorter moves nothing; cooking, laundry, status and the
-- other features are separate and keep their own switches. Stored per save in ModData "BaseKeeperKeeper".
function BKKeeper.isEnabled()
    return ModData.getOrCreate("BaseKeeperKeeper").off ~= true
end

function BKKeeper.setEnabled(on)
    ModData.getOrCreate("BaseKeeperKeeper").off = (not on) or nil
    BKKeeper.plans = {}
    BKLog.info("auto sort " .. (on and "on" or "off"))
    if isServer() then ModData.transmit("BaseKeeperKeeper") end
end

-- multiplayer: the panel on a client asks the server (any player may, like zones and loot areas)
local function onClientCommand(module, command, player, args)
    if module ~= "BaseKeeper" or type(args) ~= "table" then return end
    if command == "setAutoSort" then
        BKKeeper.setEnabled(args.on == true)
    elseif command == "sortNow" then
        local zone = tonumber(args.id) and BKZones.get(tonumber(args.id)) or nil
        if zone then BKKeeper.sortNow(zone) end
    end
end
if isServer() then Events.OnClientCommand.Add(onClientCommand) end

local function tick()
    local okR, errR = pcall(BKKeeper.returnOnce)
    if not okR then BKLog.warn("return failed: " .. tostring(errR)) end
    local on = BKKeeper.isEnabled()
    for _, zone in ipairs(BKZones.list()) do
        -- a "Sort now" pass runs even while auto sort is off
        if on or BKKeeper.resort[zone.id] then
            local ok, err = pcall(tickZone, zone)
            if not ok then BKLog.warn("tick failed for zone " .. tostring(zone.id) .. ": " .. tostring(err)) end
            if BKKeeper.resort[zone.id] then sendPass(zone.id, "run", BKKeeper.resort[zone.id]) end
        end
    end
end

local function trimMoved()
    local now = worldHours()
    for id, at in pairs(BKKeeper.moved) do
        if now - at > BKKeeper.NO_CHURN_HOURS then BKKeeper.moved[id] = nil end
    end
    for id, until_ in pairs(BKKeeper.backoff) do
        if now >= until_ then BKKeeper.backoff[id] = nil end
    end
    for key, t in pairs(BKKeeper.refused) do
        for id, until_ in pairs(t) do
            if now >= until_ then t[id] = nil end
        end
        local empty = true
        for _ in pairs(t) do empty = false; break end
        if empty then BKKeeper.refused[key] = nil end
    end
end

Events.EveryOneMinute.Add(tick)
Events.EveryHours.Add(trimMoved)
Events.BaseKeeper_ZoneAdded.Add(function(zone) BKKeeper.invalidate(zone.id) end)
Events.BaseKeeper_ZoneRemoved.Add(function(zone) BKKeeper.invalidate(zone.id) end)
-- a loot area does not know which zone covers it, so any area change replans every zone
Events.BaseKeeper_AreasChanged.Add(function() BKKeeper.plans = {} end)

return BKKeeper
