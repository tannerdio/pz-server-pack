-- Co-op Fast Forward, server half.
-- A player asks for a speed level; the server sets its own time multiplier and tells every
-- client to match. Same thing the admin-only /setTimeSpeed command does, minus the admin part.
-- Level 0 is pause: the clock runs at a thousandth of normal speed (a true zero risks divisions
-- by zero inside the game).

require "TimedActions/ISBaseTimedAction"

local MULT = { [0] = 0.001, 1, 5, 20, 40 }
local level = 1

-- How fast work gets done at the current level: nothing while paused.
local function workRate()
    if level == 0 then return 0 end
    return MULT[level] or 1
end

local function setLevel(newLevel, by)
    level = newLevel
    getGameTime():setMultiplier(MULT[level])
    sendServerCommand("CoopFF", "set", { level = level, by = by })
end

local function onClientCommand(module, command, player, args)
    if module ~= "CoopFF" or not isServer() then return end
    if command == "set" then
        local wanted = args and tonumber(args.level)
        if not wanted or not MULT[wanted] then return end
        if wanted == level then return end
        setLevel(wanted, player and player:getUsername() or nil)
    elseif command == "sync" then
        -- First player into an empty server: never start paused or fast.
        local players = getOnlinePlayers()
        if level ~= 1 and (not players or players:size() <= 1) then
            level = 1
            getGameTime():setMultiplier(1)
        end
        sendServerCommand(player, "CoopFF", "set", { level = level })
    end
end

-- Timed actions. In multiplayer the server ends every action after a fixed stretch of real time
-- (duration * 20 ms) and fires its repeating steps (insert a bullet, read a page) on real-time
-- timers, while the player's progress bar runs on the time multiplier. So each action gets one
-- 50 ms server timer that counts work done at the current speed, moves the action's end time to
-- match and fires the action's own steps on that same scaled clock.

local TICK_EVENT = "CoopFFTick"
local TICK_MS = 50
local SLICE_MS = 25
local MAX_SLICES = 800

local baseEmulate = emulateAnimEvent
local baseEmulateOnce = emulateAnimEventOnce

-- The action whose start or step handler is running right now; emulateAnimEvent calls made
-- inside it belong to it.
local current = nil

local function fireEvents(action, t, step)
    local events = t.events
    local fn = t.original
    if not fn or #events == 0 or step <= 0 then return end
    local left = step
    local slices = 0
    while left > 0 and slices < MAX_SLICES do
        slices = slices + 1
        local slice = left
        if slice > SLICE_MS then slice = SLICE_MS end
        left = left - slice
        for i = 1, #events do
            local e = events[i]
            if e and not e.dead then
                e.acc = e.acc + slice
                if e.acc >= e.period then
                    e.acc = e.acc - e.period
                    if e.once then e.dead = true end
                    current = action
                    fn(action, e.event, e.param)
                end
            end
        end
    end
end

local function tickAction(action)
    local t = action.coopFF
    local net = action.netAction
    if not t or not net or t.finished then return end
    local now = getTimestampMs()
    local rate = workRate()
    local step = (now - t.last) * rate
    t.last = now
    if rate ~= 1 then t.scaled = true end
    fireEvents(action, t, step)
    if not t.total or t.finished then return end
    t.done = t.done + step
    if not t.scaled then return end
    if t.done >= t.total then
        t.finished = true
        net:forceComplete()
    elseif t.done > 0 then
        -- Same start, new length: progress reads done/total and the end lands when done hits total.
        net:setDuration(math.floor((now - t.start) * t.total / t.done))
    else
        net:setDuration(math.floor(now - t.start + t.total))
    end
end

local function watchAction(action, duration)
    local now = getTimestampMs()
    local total = nil
    if duration > 0 then total = duration * 20 end
    current = action
    local t = action.coopFF
    if t then
        -- Asked for its duration again (restart): start counting from here.
        t.total, t.start, t.last, t.done, t.finished = total, now, now, 0, false
        return
    end
    action.coopFF = {
        total = total, start = now, last = now, done = 0, scaled = false, finished = false,
        events = {}, original = action.animEvent,
    }
    action.animEvent = function(self, event, parameter)
        if event == TICK_EVENT then
            tickAction(self)
            return
        end
        local fn = self.coopFF and self.coopFF.original
        if fn then
            current = self
            return fn(self, event, parameter)
        end
    end
    baseEmulate(action.netAction, TICK_MS, TICK_EVENT, nil)
end

-- Take over a repeating step the action registers for itself. False = leave it to the game.
local function capture(net, ms, event, param, once)
    local action = current
    if not action or action.netAction ~= net then return false end
    local t = action.coopFF
    local period = tonumber(ms)
    if not t or not period or event == TICK_EVENT then return false end
    if period < 1 then period = 1 end
    for i = 1, #t.events do
        local e = t.events[i]
        if e.event == event and e.param == param and e.once == once and e.period == period then
            e.acc, e.dead = 0, false
            return true
        end
    end
    t.events[#t.events + 1] = { period = period, event = event, param = param, once = once, acc = 0 }
    return true
end

if baseEmulate and baseEmulateOnce then
    function emulateAnimEvent(net, ms, event, param)
        if isServer() and capture(net, ms, event, param, false) then return end
        return baseEmulate(net, ms, event, param)
    end

    function emulateAnimEventOnce(net, ms, event, param)
        if isServer() and capture(net, ms, event, param, true) then return end
        return baseEmulateOnce(net, ms, event, param)
    end
end

-- The server asks every action for its length through adjustMaxTime, right before it starts it.
local baseAdjustMaxTime = ISBaseTimedAction.adjustMaxTime
function ISBaseTimedAction:adjustMaxTime(maxTime)
    local result = baseAdjustMaxTime(self, maxTime)
    if isServer() and self.netAction and baseEmulate then
        local duration = tonumber(result)
        if duration then watchAction(self, duration) end
    end
    return result
end

-- Cooking. The server warms food and counts its cooking minutes on real time, so an oven ignores
-- fast forward. Once a game minute, while fast forwarding, food in hot containers near a player
-- gets the warming it missed, and its cooking time is topped up to one step per game minute.

local COOK_RADIUS = 10
local COOK_RESCAN_MS = 2000
local cook = { containers = {}, scanAt = 0, lastMs = nil, seen = {} }

local function scanHotContainers()
    local found = {}
    local players = getOnlinePlayers()
    local cell = getCell()
    if not players or not cell then
        cook.containers = found
        return
    end
    local visited = {}
    for p = 0, players:size() - 1 do
        local player = players:get(p)
        local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
        for z = pz - 1, pz + 1 do
            for x = px - COOK_RADIUS, px + COOK_RADIUS do
                for y = py - COOK_RADIUS, py + COOK_RADIUS do
                    local key = x .. "," .. y .. "," .. z
                    if not visited[key] then
                        visited[key] = true
                        local sq = cell:getGridSquare(x, y, z)
                        if sq then
                            local objects = sq:getObjects()
                            for i = 0, objects:size() - 1 do
                                local obj = objects:get(i)
                                for c = 0, obj:getContainerCount() - 1 do
                                    local container = obj:getContainerByIndex(c)
                                    if container and container:getTemperature() > 1.01 then
                                        found[#found + 1] = container
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    cook.containers = found
end

local function cookPass()
    local now = getTimestampMs()
    local last = cook.lastMs
    cook.lastMs = now
    if level <= 1 or not last then
        cook.seen = {}
        return
    end
    local dt = now - last
    if dt > 6000 then dt = 6000 end
    if now - cook.scanAt > COOK_RESCAN_MS then
        cook.scanAt = now
        scanHotContainers()
    end
    local gameTime = getGameTime()
    local minuteNow = gameTime:getWorldAgeHours() * 60
    -- Warming the game already did covers 1x; this is the rest.
    local missed = gameTime:getMultiplierFromTimeDelta(dt / 1000) / 1.6 * (MULT[level] - 1)
    local seen = {}
    for c = 1, #cook.containers do
        local container = cook.containers[c]
        local temp = container:getTemperature()
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if instanceof(item, "Food") then
                local heat = item:getHeat()
                if temp > heat then
                    local top = math.min(3, temp)
                    local warmed = math.min(top, heat + temp / 1000 * missed)
                    if warmed > heat then
                        item:setHeat(warmed)
                        heat = warmed
                    end
                end
                if item:isCookable() and not item:isFrozen() and heat > 1.6 then
                    local id = item:getID()
                    local before = cook.seen[id]
                    local cooked = item:getCookingTime()
                    if before then
                        local perMinute = heat / 1.5
                        if temp <= 1.6 then perMinute = perMinute * 0.05 end
                        local want = before.cooked + (minuteNow - before.minute) * perMinute
                        if cooked < want - 0.05 then
                            item:setCookingTime(want)
                            cooked = want
                        end
                    end
                    seen[id] = { cooked = cooked, minute = minuteNow }
                end
            end
        end
    end
    cook.seen = seen
end

local function everyMinute()
    if not isServer() then return end
    -- Nobody online: back to normal speed so the world never runs ahead by itself.
    if level ~= 1 then
        local players = getOnlinePlayers()
        if not players or players:size() == 0 then
            level = 1
            getGameTime():setMultiplier(1)
        end
    end
    cookPass()
end

Events.OnClientCommand.Add(onClientCommand)
Events.EveryOneMinute.Add(everyMinute)
