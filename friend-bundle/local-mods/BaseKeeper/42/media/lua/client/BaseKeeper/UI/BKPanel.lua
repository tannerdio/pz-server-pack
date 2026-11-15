-- Base Keeper: the panel (v0.17.0, Tanner 2026-11-13: "the whole basekeeper menu, too much bloat. make it a
-- basekeeper button that opens up a simple square UI with my options. Keep them simple: browse loot, manage base
-- zones, manage loot zones, tools: prep meal, auto sort on/off, etc.").
--   BKHud   = a small "Base Keeper" button on the screen. Click = open / close the panel, drag = move it (the
--             position is kept per save in ModData "BaseKeeperUI").
--   BKPanel = one small window with a column of plain buttons on three pages:
--             main  : Browse loot, Loot zones, Base zones >, Prep a meal, Auto sort on/off, Sort now, Base status,
--                     Tools >
--             zones : New base zone, Remove zone N ..., Show zones on ground
--             tools : the less used actions other files registered, then Advanced (the old full menu)
-- Zone actions use the zone the player stands in, else the nearest one. The right-click menu is a single
-- "Base Keeper" entry that opens this panel and remembers the clicked square for Loot zones and Advanced.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISModalDialog"
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/UI/BKAddZoneUI"
require "BaseKeeper/UI/BKOverlay"
require "BaseKeeper/UI/BKContextMenu"

BKPanel = ISCollapsableWindow:derive("BKPanel")

BKPanel.instance = nil
BKPanel.WIDTH = 270
BKPanel.PAD = 10
BKPanel.GAP = 6
-- Tools page: actions other files registered in BKContextMenu.zoneActions / globalActions, found by the start of
-- their label, in this order. One that is not registered (a file missing, a multiplayer client) is left out.
BKPanel.TOOLS = { "Pack run loadout", "Do laundry now", "Laundry:", "Med kit auto", "Meal prep:", "Export base inventory" }

local FONT = UIFont.Small
local FONT_HGT = getTextManager():getFontHeight(FONT)
local BTN_HGT = FONT_HGT + 12

local function labelOf(action)
    if type(action.label) == "function" then
        local ok, text = pcall(action.label)
        return ok and tostring(text) or "?"
    end
    return tostring(action.label)
end

-- a registered action whose label starts with prefix: returns action, needsZone
local function findAction(prefix)
    for _, a in ipairs(BKContextMenu.zoneActions) do
        if string.find(labelOf(a), prefix, 1, true) == 1 then return a, true end
    end
    for _, a in ipairs(BKContextMenu.globalActions) do
        if string.find(labelOf(a), prefix, 1, true) == 1 then return a, false end
    end
    return nil
end

function BKPanel:player()
    return getSpecificPlayer(self.playerNum or 0)
end

-- the zone the player stands in, else the nearest one (any distance), else nil
function BKPanel:zone()
    local p = self:player()
    if p == nil then return nil end
    local here = BKZones.at(p:getX(), p:getY(), p:getZ())
    if here then return here end
    local best, bestD = nil, nil
    for _, z in ipairs(BKZones.list()) do
        local cx, cy = BKZones.center(z)
        local d = math.abs(cx - p:getX()) + math.abs(cy - p:getY())
        if bestD == nil or d < bestD then best, bestD = z, d end
    end
    return best
end

local function halo(player, text)
    if HaloTextHelper and player then pcall(HaloTextHelper.addText, player, text) end
end

-- Multiplayer client: the "Sort now" pass lives on the server, which reports it with server command "sortState"
-- (BKKeeper.sendPass). zoneId -> { moved, atMs, mine }. An entry the server stopped updating (restart, lost message)
-- is dropped after REMOTE_STALE_MS so the button never stays stuck.
BKPanel.remoteSort = {}
BKPanel.REMOTE_STALE_MS = 120000

local function remotePass(zone)
    if zone == nil then return nil end
    local p = BKPanel.remoteSort[zone.id]
    if p and getTimestampMs() - p.atMs > BKPanel.REMOTE_STALE_MS then
        BKPanel.remoteSort[zone.id] = nil
        return nil
    end
    return p
end

local function confirm(player, text, onYes)
    local modal = ISModalDialog:new(0, 0, 300, 120, text, true, nil,
        function(_, button) if button.internal == "YES" then onYes() end end, player:getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
end

-- Pages -----------------------------------------------------------------------------------------------------------
-- A row = { label = string | function(panel), fn = function(panel), enabled = function(panel) (optional) }.

local function registered(prefix, shortLabel)
    local action, needsZone = findAction(prefix)
    if action == nil then return nil end
    return {
        label = shortLabel or function() return labelOf(action) end,
        enabled = needsZone and function(panel) return panel:zone() ~= nil end or nil,
        fn = function(panel)
            local player = panel:player()
            if needsZone then
                local zone = panel:zone()
                if zone then action.fn(player, zone) end
            else
                action.fn(player)
            end
        end,
    }
end

local function toPage(page)
    return function(panel) panel:show(page) end
end

function BKPanel:mainRows()
    local rows = {}
    table.insert(rows, { label = "Browse loot", fn = function(panel)
        if BKLootWindow then BKLootWindow.toggle(panel:player()) end
    end })
    table.insert(rows, { label = "Loot zones", fn = function(panel)
        if not BKAreaWindow then return end
        -- opened from a right-click on a loot area: go straight to that area
        local sq = panel.sq
        local area = sq and BKLoot.at(sq:getX(), sq:getY(), sq:getZ()) or nil
        BKAreaWindow.open(panel.playerNum or 0, area and area.id or nil)
    end })
    table.insert(rows, { label = "Base zones  >", fn = toPage("zones") })
    local prep = registered("Prep a meal", "Prep a meal")
    if prep then table.insert(rows, prep) end
    -- v0.19.0: in multiplayer the sorter lives on the server (BKKeeper is nil here), so the two sorter buttons send
    -- a client command; the switch state comes back through ModData "BaseKeeperKeeper".
    local remote = isClient()
    if remote or (BKKeeper and BKKeeper.isEnabled) then
        local function sortOn() return ModData.getOrCreate("BaseKeeperKeeper").off ~= true end
        table.insert(rows, {
            label = function() return sortOn() and "Auto sort: ON" or "Auto sort: OFF" end,
            fn = function(panel)
                local on = not sortOn()
                if remote then
                    ModData.getOrCreate("BaseKeeperKeeper").off = (not on) or nil -- shown at once, the server confirms
                    sendClientCommand(panel:player(), "BaseKeeper", "setAutoSort", { on = on })
                else
                    BKKeeper.setEnabled(on)
                end
                halo(panel:player(), on and "Base Keeper: auto sort on" or "Base Keeper: auto sort off")
            end,
        })
        table.insert(rows, {
            label = function(panel)
                local pass
                if remote then pass = remotePass(panel:zone()) else pass = BKKeeper.sorting(panel:zone()) end
                return pass and string.format("Sorting...  (%d moved)", pass.moved) or "Sort now"
            end,
            enabled = function(panel)
                local zone = panel:zone()
                if zone == nil then return false end
                if remote then return remotePass(zone) == nil end
                return BKKeeper.sorting(zone) == nil
            end,
            fn = function(panel)
                local zone = panel:zone()
                if zone == nil then return end
                if remote then
                    if remotePass(zone) then return end
                    -- shown at once; the server's "sortState" messages take over from here
                    BKPanel.remoteSort[zone.id] = { moved = 0, atMs = getTimestampMs(), mine = true }
                    sendClientCommand(panel:player(), "BaseKeeper", "sortNow", { id = zone.id })
                else
                    BKKeeper.sortNow(zone)
                end
                halo(panel:player(), "Base Keeper: sorting zone " .. tostring(zone.id) .. " now, containers included")
            end,
        })
    end
    local status = registered("Base status", "Base status") or registered("Hide base status", "Base status")
    if status then table.insert(rows, status) end
    table.insert(rows, { label = "Tools  >", fn = toPage("tools") })
    return rows
end

function BKPanel:zoneRows()
    local rows = {}
    table.insert(rows, { label = "New base zone (drag)", fn = function(panel)
        BKAddZoneUI.open(panel.playerNum or 0)
    end })
    for _, zone in ipairs(BKZones.list()) do
        local id = zone.id
        table.insert(rows, {
            label = function(panel)
                local z = BKZones.get(id)
                if z == nil then return "Zone " .. tostring(id) .. " removed" end
                local cur = panel:zone()
                return string.format("Remove zone %d (%dx%d)%s", id, BKZones.width(z), BKZones.height(z),
                    (cur and cur.id == id) and "  - nearest" or "")
            end,
            enabled = function() return BKZones.get(id) ~= nil end,
            fn = function(panel)
                local player = panel:player()
                confirm(player, "Remove Base Keeper zone " .. tostring(id) .. "? Loot zones inside it stay.",
                    function() BKZones.requestRemove(player, id) end)
            end,
        })
    end
    table.insert(rows, {
        label = function() return BKOverlay.enabled and "Show zones on ground: ON" or "Show zones on ground: OFF" end,
        fn = function() BKOverlay.toggle() end,
    })
    table.insert(rows, { label = "<  Back", fn = toPage("main") })
    return rows
end

function BKPanel:toolRows()
    local rows = {}
    for _, prefix in ipairs(BKPanel.TOOLS) do
        local row = registered(prefix)
        if row then table.insert(rows, row) end
    end
    table.insert(rows, { label = "Advanced (full menu)", fn = function(panel)
        -- the old right-click list: logs, layout, sections. Built for the right-clicked square when there is one.
        local player = panel:player()
        local sq = panel.sq or (player and player:getCurrentSquare()) or nil
        local context = ISContextMenu.get(panel.playerNum or 0, getMouseX(), getMouseY())
        BKContextMenu.fillFull(context, player, sq)
    end })
    table.insert(rows, { label = "<  Back", fn = toPage("main") })
    return rows
end

-- Window ----------------------------------------------------------------------------------------------------------

function BKPanel.onRow(self, button)
    local row = button.bkRow
    if row == nil or row.fn == nil then return end
    local ok, err = pcall(row.fn, self)
    if not ok then BKLog.warn("panel action failed: " .. tostring(err)) end
end

function BKPanel:show(page)
    self.page = page or "main"
    for _, b in ipairs(self.buttons or {}) do self:removeChild(b) end
    self.buttons = {}
    local rows = (self.page == "zones" and self:zoneRows()) or (self.page == "tools" and self:toolRows()) or self:mainRows()
    local pad = BKPanel.PAD
    local y = self:titleBarHeight() + pad + FONT_HGT + pad
    for _, row in ipairs(rows) do
        local b = ISButton:new(pad, y, self.width - pad * 2, BTN_HGT, "", self, BKPanel.onRow)
        b:initialise()
        b.bkRow = row
        self:addChild(b)
        table.insert(self.buttons, b)
        y = y + BTN_HGT + BKPanel.GAP
    end
    self:setHeight(y - BKPanel.GAP + pad)
    self:refreshRows()
end

-- labels and enabled states follow the game (toggles, zones added or removed) without rebuilding the buttons
function BKPanel:refreshRows()
    for _, b in ipairs(self.buttons or {}) do
        local row = b.bkRow
        local text = row.label
        if type(text) == "function" then
            local ok, t = pcall(text, self)
            text = ok and tostring(t) or "?"
        end
        if b.title ~= text then b:setTitle(text) end
        local on = true
        if row.enabled then
            local ok, v = pcall(row.enabled, self)
            on = ok and v == true
        end
        b:setEnable(on)
    end
end

function BKPanel:prerender()
    ISCollapsableWindow.prerender(self)
    if self.rebuild then
        self.rebuild = false
        self:show(self.page)
    else
        self:refreshRows()
    end
end

function BKPanel:render()
    ISCollapsableWindow.render(self)
    if self.isCollapsed then return end
    local zone = self:zone()
    local text
    if self.page == "zones" then
        text = "Base zones (each covers every floor)"
    elseif self.page == "tools" then
        text = "Tools"
    elseif zone then
        text = string.format("Zone %d  -  %dx%d  -  floors %s", zone.id, BKZones.width(zone), BKZones.height(zone),
            BKZones.floorsText(zone))
    else
        text = "No base zone yet: Base zones > New"
    end
    self:drawText(text, BKPanel.PAD, self:titleBarHeight() + BKPanel.PAD, 0.3, 0.85, 0.9, 1, FONT)
end

function BKPanel:close()
    BKPanel.pos = { x = self:getX(), y = self:getY() }
    self:setVisible(false)
    self:removeFromUIManager()
    if BKPanel.instance == self then BKPanel.instance = nil end
end

-- sq (optional) = the square that was right-clicked; nil when opened from the screen button.
function BKPanel.open(playerNum, sq)
    local o = BKPanel.instance
    if o == nil then
        local pos = BKPanel.pos
        if pos == nil then
            local hud = BKHud and BKHud.instance or nil
            pos = { x = getMouseX() + 16, y = getMouseY() - 40 }
            if hud and sq == nil then pos = { x = hud:getX(), y = hud:getY() - 330 } end
        end
        local core = getCore()
        pos.x = math.max(0, math.min(pos.x, core:getScreenWidth() - BKPanel.WIDTH))
        pos.y = math.max(0, math.min(pos.y, core:getScreenHeight() - 340))
        o = BKPanel:new(pos.x, pos.y, BKPanel.WIDTH, 300)
        o.playerNum = playerNum or 0
        o:initialise()
        o:setTitle("Base Keeper")
        o:setResizable(false)
        o:addToUIManager()
        BKPanel.instance = o
    end
    o.sq = sq
    o:show("main")
    o:bringToTop()
    return o
end

function BKPanel.toggle(playerNum)
    if BKPanel.instance then BKPanel.instance:close() else BKPanel.open(playerNum or 0, nil) end
end

-- multiplayer client: the auto sort switch is the server's; ask for it at load and take every update
if isClient() then
    Events.OnInitGlobalModData.Add(function()
        if ModData.request then ModData.request("BaseKeeperKeeper") end
    end)
    Events.OnReceiveGlobalModData.Add(function(key, data)
        if key == "BaseKeeperKeeper" and type(data) == "table" and ModData.add then ModData.add(key, data) end
    end)
    -- "Sort now" progress and end, sent to every client; only the player who pressed the button gets the halo
    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= "BaseKeeper" or command ~= "sortState" or type(args) ~= "table" then return end
        local id = tonumber(args.id)
        if id == nil then return end
        local old = BKPanel.remoteSort[id]
        local moved = tonumber(args.moved) or 0
        if args.state == "done" then
            BKPanel.remoteSort[id] = nil
            if old and old.mine then
                halo(getSpecificPlayer(0), string.format("Sort now finished: %d item(s) moved out of containers", moved))
            end
        else
            BKPanel.remoteSort[id] = { moved = moved, atMs = getTimestampMs(), mine = old ~= nil and old.mine == true }
        end
    end)
end

Events.BaseKeeper_ZoneAdded.Add(function() if BKPanel.instance then BKPanel.instance.rebuild = true end end)
Events.BaseKeeper_ZoneRemoved.Add(function() if BKPanel.instance then BKPanel.instance.rebuild = true end end)

-- Screen button ---------------------------------------------------------------------------------------------------

BKHud = ISPanel:derive("BKHud")
BKHud.instance = nil
BKHud.TEXT = "Base Keeper"
BKHud.DRAG_PX = 4

local function hudStore()
    return ModData.getOrCreate("BaseKeeperUI")
end

function BKHud:onMouseDown(x, y)
    self.down = true
    self.dragging = false
    self.downX, self.downY = getMouseX(), getMouseY()
    return true
end

function BKHud:drag(dx, dy)
    if not self.down then return end
    if not self.dragging and math.abs(getMouseX() - self.downX) + math.abs(getMouseY() - self.downY) > BKHud.DRAG_PX then
        self.dragging = true
    end
    if self.dragging then
        local core = getCore()
        self:setX(math.max(0, math.min(self:getX() + dx, core:getScreenWidth() - self.width)))
        self:setY(math.max(0, math.min(self:getY() + dy, core:getScreenHeight() - self.height)))
    end
end

function BKHud:onMouseMove(dx, dy) self:drag(dx, dy) end
function BKHud:onMouseMoveOutside(dx, dy) self:drag(dx, dy) end

function BKHud:release(click)
    if not self.down then return end
    self.down = false
    if self.dragging then
        local d = hudStore()
        d.x, d.y = self:getX(), self:getY()
    elseif click then
        BKPanel.toggle(0)
    end
    self.dragging = false
end

function BKHud:onMouseUp(x, y) self:release(true) end
function BKHud:onMouseUpOutside(x, y) self:release(false) end

function BKHud:prerender()
    local over = self:isMouseOver()
    self:drawRect(0, 0, self.width, self.height, over and 0.85 or 0.6, 0.05, 0.08, 0.1)
    self:drawRectBorder(0, 0, self.width, self.height, 1, 0.3, 0.85, 0.9)
    local open = BKPanel.instance ~= nil
    self:drawText(BKHud.TEXT, 8, (self.height - FONT_HGT) / 2, open and 0.3 or 0.9, open and 0.85 or 0.9, 0.9, 1, FONT)
end

function BKHud:render() end

function BKHud.ensure()
    if BKHud.instance and BKHud.instance.javaObject then return BKHud.instance end
    BKHud.instance = nil
    local w = getTextManager():MeasureStringX(FONT, BKHud.TEXT) + 16
    local h = FONT_HGT + 10
    local core = getCore()
    local d = hudStore()
    -- default: bottom left, clear of the vanilla left-hand icons; drag it wherever it suits
    local x = tonumber(d.x) or (getPlayerScreenLeft(0) + 10)
    local y = tonumber(d.y) or (core:getScreenHeight() - h - 120)
    x = math.max(0, math.min(x, core:getScreenWidth() - w))
    y = math.max(0, math.min(y, core:getScreenHeight() - h))
    local o = BKHud:new(x, y, w, h)
    o:initialise()
    o:addToUIManager()
    BKHud.instance = o
    return o
end

Events.OnGameStart.Add(BKHud.ensure)

return BKPanel
