-- Co-op Fast Forward, client half.
-- Speed keys (the same binds as solo) and a copy of the solo speed buttons ask the server for a
-- speed; the server's answer is applied here. Does nothing outside multiplayer.
-- Levels: 0 pause, 1 normal, 2 = 5x, 3 = 20x, 4 = 40x.

CoopFF = CoopFF or {}
CoopFF.MULT = { [0] = 0.001, 1, 5, 20, 40 }
CoopFF.LABEL = { [0] = "paused", "1x", "5x", "20x", "40x" }
CoopFF.level = 1
CoopFF.beforePause = 1
CoopFF.synced = false
CoopFF.tick = 0
CoopFF.lastDrop = 0

-- The solo speed control icons, in solo order.
local BUTTONS = {
    { level = 0, icon = "Pause", w = 20, tip = "Pause" },
    { level = 1, icon = "Play", w = 16, tip = "Normal speed" },
    { level = 2, icon = "FFwd1", w = 26, tip = "Fast forward x1" },
    { level = 3, icon = "FFwd2", w = 36, tip = "Fast forward x2" },
    { level = 4, icon = "Wait", w = 22, tip = "Fast forward x3" },
}
local ICON_H, GAP, PAD = 22, 6, 3

local Panel = ISPanel:derive("CoopFFPanel")

function Panel:new(x, y)
    local w = PAD * 2 - GAP
    for _, def in ipairs(BUTTONS) do w = w + def.w + GAP end
    local o = ISPanel:new(x, y, w, ICON_H + PAD * 2)
    setmetatable(o, self)
    self.__index = self
    o.moveWithMouse = true
    o.background = false
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.buttons = {}
    return o
end

function Panel:createChildren()
    ISPanel.createChildren(self)
    local x = PAD
    for _, def in ipairs(BUTTONS) do
        local b = ISButton:new(x, PAD, def.w, ICON_H, "", self, Panel.onClick)
        b.coopLevel = def.level
        b.texOff = getTexture("media/ui/speedControls/" .. def.icon .. "_Off.png")
        b.texOn = getTexture("media/ui/speedControls/" .. def.icon .. "_On.png")
        b.displayBackground = false
        b.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        b:initialise()
        b:instantiate()
        b:setImage(b.texOff)
        b:setTooltip(def.tip)
        self:addChild(b)
        self.buttons[#self.buttons + 1] = b
        x = x + def.w + GAP
    end
    self:refresh()
end

function Panel:onClick(button)
    CoopFF.request(button.coopLevel)
end

function Panel:refresh()
    for _, b in ipairs(self.buttons) do
        if b.coopLevel == CoopFF.level then
            b:setImage(b.texOn or b.texOff)
        else
            b:setImage(b.texOff)
        end
    end
end

-- Solo rule: fast forward stops when a zombie you can see is within 4 tiles on your floor
-- (7 tiles once more than four are in view).
local function zombieClose(player)
    if player:isGhostMode() then return false end
    local visible = player:getStats():getNumVisibleZombies()
    if visible <= 0 then return false end
    local range = 4
    if visible > 4 then range = 7 end
    local spotted = player:getSpottedList()
    if not spotted then return false end
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    for i = 0, spotted:size() - 1 do
        local other = spotted:get(i)
        if instanceof(other, "IsoZombie") and math.floor(other:getZ()) == pz then
            local dx, dy = other:getX() - px, other:getY() - py
            if dx * dx + dy * dy < range * range then return true end
        end
    end
    return false
end

function CoopFF.request(level)
    if not isClient() or not CoopFF.MULT[level] then return end
    local player = getPlayer()
    if not player then return end
    if level > 1 and zombieClose(player) then
        player:setHaloNote("Zombies nearby")
        return
    end
    sendClientCommand(player, "CoopFF", "set", { level = level })
end

function CoopFF.togglePause()
    if CoopFF.level == 0 then
        CoopFF.request(CoopFF.beforePause or 1)
    else
        CoopFF.request(0)
    end
end

local function apply(level, by)
    if not CoopFF.MULT[level] then return end
    local changed = level ~= CoopFF.level
    if changed and level == 0 then CoopFF.beforePause = CoopFF.level end
    CoopFF.level = level
    getGameTime():setMultiplier(CoopFF.MULT[level])
    if CoopFF.panel then CoopFF.panel:refresh() end
    local player = getPlayer()
    if changed and player then
        if level == 0 then
            player:setHaloNote((by and (by .. ": ") or "") .. "paused")
        elseif by then
            player:setHaloNote(by .. ": speed " .. CoopFF.LABEL[level])
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= "CoopFF" or command ~= "set" or not args then return end
    apply(tonumber(args.level) or 1, args.by)
end

local function onKeyPressed(key)
    if not isClient() then return end
    if not MainScreen.instance or not MainScreen.instance.inGame or MainScreen.instance:getIsVisible() then return end
    local core = getCore()
    -- Escape is the default pause bind and also opens the menu; opening the menu must not pause
    -- the game for everyone, so pause only answers to a bind other than Escape (or the button).
    if key ~= Keyboard.KEY_ESCAPE and core:isKey(KeybindId.PAUSE, key) then
        CoopFF.togglePause()
    elseif core:isKey(KeybindId.NORMAL_SPEED, key) then
        CoopFF.request(1)
    elseif core:isKey(KeybindId.FAST_FORWARD_X1, key) then
        CoopFF.request(2)
    elseif core:isKey(KeybindId.FAST_FORWARD_X2, key) then
        CoopFF.request(3)
    elseif core:isKey(KeybindId.FAST_FORWARD_X3, key) then
        CoopFF.request(4)
    end
end

-- Ask for normal speed, at most twice a second.
local function drop()
    local now = getTimestampMs()
    if now - CoopFF.lastDrop < 500 then return end
    CoopFF.lastDrop = now
    CoopFF.request(1)
end

local function onTick()
    if not isClient() then return end
    CoopFF.tick = CoopFF.tick + 1
    local player = getPlayer()
    if not player then return end
    if not CoopFF.synced then
        if CoopFF.tick % 30 == 0 then
            CoopFF.synced = true
            sendClientCommand(player, "CoopFF", "sync", {})
        end
        return
    end
    if CoopFF.level <= 1 then return end
    -- Solo drops out of fast forward when you move yourself or a zombie gets close; the game
    -- skips both checks in multiplayer, so they are done here and passed on to everyone.
    if player:isJustMoved() and not player:hasPath() and not player:isCurrentActionPathfinding() then
        drop()
    elseif zombieClose(player) then
        drop()
    elseif CoopFF.tick % 30 == 0 and getGameTime():getTrueMultiplier() < 1.5 then
        drop()
    end
end

local function placePanel(panel)
    local x = getCore():getScreenWidth() - panel:getWidth() - 20
    local y = 130
    local clock = UIManager.getClock()
    if clock then
        x = clock:getX() + clock:getWidth() - panel:getWidth()
        y = clock:getY() + clock:getHeight() + 6
    end
    panel:setX(x)
    panel:setY(y)
end

local function onGameStart()
    if not isClient() then return end
    CoopFF.level = 1
    CoopFF.beforePause = 1
    CoopFF.synced = false
    if not CoopFF.panel then
        local panel = Panel:new(0, 0)
        panel:initialise()
        panel:instantiate()
        placePanel(panel)
        panel:addToUIManager()
        CoopFF.panel = panel
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnTick.Add(onTick)
Events.OnGameStart.Add(onGameStart)
