-- Base Keeper: base loot browser (v0.11.0, Tanner 2026-11-06: "give me a list of loot from the whole base in game that
-- i can grab from"). One window listing every item in the base (every zone + tagged loot areas no zone covers; bins,
-- personal areas and locked containers left out), grouped by name, with a search box and a category filter. Grab 1 /
-- Grab all queue the vanilla walk + transfer actions (decided with Tanner: walk + take, no teleporting), nearest copy
-- first. Rows show where the copies are ("3 counter kitchen, 1 floor").
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISButton"
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/Engine/BKItemClass"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/UI/BKContextMenu"

BKLootWindow = ISCollapsableWindow:derive("BKLootWindow")

BKLootWindow.instance = nil
BKLootWindow.WIDTH = 620
BKLootWindow.HEIGHT = 480
BKLootWindow.PAD = 8
BKLootWindow.NOT_STOCK = { bin = true, dumpster = true, composter = true }
BKLootWindow.DEBOUNCE_MS = 1500 -- container updates while the window is open trigger one rescan after this quiet time

local FONT = UIFont.Small
local FONT_HGT = getTextManager():getFontHeight(FONT)
local ROW_HGT = FONT_HGT + 6
local BTN_HGT = FONT_HGT + 8

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function m(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return nil end
    local ok2, r = pcall(fn, obj, ...)
    if ok2 then return r end
    return nil
end

-- class -> broad category label (BKLoot.CATEGORIES); the row tag prefers the fine group label (v0.12.0)
local CLASS_LABEL = {}
for _, cat in ipairs(BKLoot.CATEGORIES) do
    for _, cls in ipairs(cat.classes or {}) do CLASS_LABEL[cls] = cat.label end
end

local function rowLabel(row)
    if row.group and BKTaxonomy.get(row.group) and row.group ~= "other" then return BKTaxonomy.label(row.group) end
    return CLASS_LABEL[row.class] or row.class
end

-- the row matches a category key: its class is in the category's classes or its group in its groups
local function rowMatches(row, key)
    local cat = BKLoot.category(key)
    if cat == nil then return true end
    for _, cls in ipairs(cat.classes or {}) do if cls == row.class then return true end end
    for _, g in ipairs(cat.groups or {}) do if g == row.group then return true end end
    return false
end

-- Every rectangle that makes up the base: zones + tagged, non-personal loot areas no zone covers (same rule as
-- BKZoneScan.scanBase and the wishlist count).
local function baseRects()
    local zones = BKZones.list()
    local out = {}
    for _, z in ipairs(zones) do table.insert(out, z) end
    for _, area in ipairs(BKLoot.list()) do
        if BKLoot.hasCategories(area) and not BKLoot.isPersonal(area) then
            local covered = false
            for _, z in ipairs(zones) do
                if BKZones.overlaps(z, area.x1, area.y1, area.x2, area.y2, area.z) then covered = true end
            end
            if not covered then
                table.insert(out, { id = "area" .. tostring(area.id), x1 = area.x1, y1 = area.y1, x2 = area.x2,
                    y2 = area.y2, z = area.z })
            end
        end
    end
    return out
end

local function whereLabel(c)
    if c == nil then return "floor" end
    if c.room and c.room ~= "" then return c.ctype .. " " .. c.room end
    return c.ctype
end

-- Walks the base. Returns rows = { {key, name, fullType, class, entries = { {item, src, worldObj, square, x, y, z,
-- where}, ... }}, ... } and a summary.
function BKLootWindow.collect()
    local byKey, rows = {}, {}
    local partial, count = false, 0
    local function add(item, src, worldObj, square, x, y, z, where)
        local fullType = m(item, "getFullType") or "?"
        local name = m(item, "getDisplayName") or fullType
        local key = fullType .. "|" .. name
        local row = byKey[key]
        if row == nil then
            local class, _, _, group = BKItemClass.classify(item)
            row = { key = key, name = name, fullType = fullType, class = class, group = group, entries = {} }
            byKey[key] = row
            table.insert(rows, row)
        end
        table.insert(row.entries, { item = item, src = src, worldObj = worldObj, square = square, x = x, y = y, z = z,
            where = where })
        count = count + 1
    end
    local function bagContents(bag, square, x, y, z, where)
        local inv = safe(function()
            if bag.getInventory and bag:getCategory() == "Container" then return bag:getInventory() end
            return nil
        end)
        local items = inv and safe(function() return inv:getItems() end)
        if not items then return end
        for i = 0, items:size() - 1 do
            local inner = items:get(i)
            if inner then add(inner, inv, nil, square, x, y, z, where .. ", in " .. (m(bag, "getDisplayName") or "bag")) end
        end
    end
    local seenContainer = {}
    for _, rect in ipairs(baseRects()) do
        local ok, err = pcall(function()
            local scan = BKZoneScan.scan(rect)
            if (scan.missingSquares or 0) > 0 then partial = true end
            for _, c in ipairs(scan.containers) do
                local id = c.x .. "," .. c.y .. "," .. c.z .. "," .. c.ctype .. "," .. tostring(c.index)
                if not seenContainer[id] and not c.personal and not c.locked and not BKLootWindow.NOT_STOCK[c.ctype] then
                    seenContainer[id] = true
                    local items = safe(function() return c.container:getItems() end)
                    if items then
                        local where = whereLabel(c)
                        for i = 0, items:size() - 1 do
                            local item = items:get(i)
                            if item then
                                add(item, c.container, nil, c.square, c.x, c.y, c.z, where)
                                bagContents(item, c.square, c.x, c.y, c.z, where)
                            end
                        end
                    end
                end
            end
            for _, f in ipairs(scan.floorItems) do
                if not f.personal then
                    add(f.item, nil, f.worldObj, f.square, f.x, f.y, f.z, "floor")
                    bagContents(f.item, f.square, f.x, f.y, f.z, "floor")
                end
            end
        end)
        if not ok then
            partial = true
            BKLog.warn("loot browser scan failed for " .. tostring(rect.id) .. ": " .. tostring(err))
        end
    end
    table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return rows, { items = count, types = #rows, partial = partial }
end

-- Rows -> "3 counter kitchen, 1 floor" (most copies first, at most three places)
local function placesText(row)
    local counts, order = {}, {}
    for _, e in ipairs(row.entries) do
        if counts[e.where] == nil then counts[e.where] = 0; table.insert(order, e.where) end
        counts[e.where] = counts[e.where] + 1
    end
    table.sort(order, function(a, b) return counts[a] > counts[b] end)
    local parts = {}
    for i, w in ipairs(order) do
        if i > 3 then table.insert(parts, "+" .. tostring(#order - 3) .. " more"); break end
        table.insert(parts, tostring(counts[w]) .. " " .. w)
    end
    return table.concat(parts, ", ")
end

-- Grab --------------------------------------------------------------------------------------------------------------

local function stillThere(e)
    if e.worldObj then
        return safe(function() return e.worldObj:getSquare() ~= nil and e.worldObj:getItem() == e.item end) == true
    end
    return safe(function() return e.item:getContainer() == e.src end) == true
end

-- Queues vanilla walk + transfer actions for up to n copies, nearest first, one walk per square.
function BKLootWindow.grab(player, row, n)
    if player == nil or row == nil then return 0 end
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local entries = {}
    for _, e in ipairs(row.entries) do
        if stillThere(e) then table.insert(entries, e) end
    end
    local function dist(e) return math.abs(e.x - px) + math.abs(e.y - py) + math.abs(e.z - pz) * 6 end
    table.sort(entries, function(a, b)
        local da, db = dist(a), dist(b)
        if da ~= db then return da < db end
        return a.x * 100000 + a.y < b.x * 100000 + b.y
    end)
    ISTimedActionQueue.clear(player)
    local inv = player:getInventory()
    local queued, lastSq, unreachable = 0, nil, 0
    for _, e in ipairs(entries) do
        if queued >= n then break end
        local ok = true
        if e.square ~= lastSq then
            local adj = AdjacentFreeTileFinder.Find(e.square, player)
            if adj == nil then
                ok = false
                unreachable = unreachable + 1
            else
                if adj ~= player:getCurrentSquare() or lastSq ~= nil then
                    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, adj))
                end
                lastSq = e.square
            end
        end
        if ok then
            if e.worldObj then
                ISTimedActionQueue.add(ISGrabItemAction:new(player, e.worldObj,
                    ISWorldObjectContextMenu.grabItemTime(player, e.worldObj)))
            else
                ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, e.item, e.src, inv))
            end
            queued = queued + 1
        end
    end
    BKLog.info(string.format("loot browser: grab %s x%d queued (%d available, %d unreachable)", row.name, queued,
        #entries, unreachable))
    if queued == 0 and HaloTextHelper then
        pcall(HaloTextHelper.addBadText, player, unreachable > 0 and "Can't reach " .. row.name or row.name .. " is gone")
    end
    return queued
end

-- Window ------------------------------------------------------------------------------------------------------------

function BKLootWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local pad = BKLootWindow.PAD
    local y = self:titleBarHeight() + pad
    self.filterBox = ISTextEntryBox:new("", pad, y, 260, BTN_HGT)
    self.filterBox:initialise()
    self.filterBox:instantiate()
    self.filterBox.font = UIFont.Small
    if self.filterBox.setPlaceholderText then self.filterBox:setPlaceholderText("Search (name or Base.Type)") end
    self.filterBox.onTextChangeFunction = BKLootWindow.onFilterChanged
    self.filterBox.target = self
    self:addChild(self.filterBox)

    self.catCombo = ISComboBox:new(pad + 268, y, 190, BTN_HGT, self, BKLootWindow.onFilterChanged)
    self.catCombo:initialise()
    self.catCombo:addOptionWithData("All categories", nil)
    for _, fam in ipairs(BKTaxonomy.FAMILIES) do
        for _, cat in ipairs(BKLoot.categoriesOf(fam.key)) do
            if not cat.personal and cat.key ~= "trash" then
                self.catCombo:addOptionWithData((cat.fine and "   " or "") .. cat.label, cat.key)
            end
        end
    end
    self.catCombo.selected = 1
    self:addChild(self.catCombo)

    self.refreshBtn = ISButton:new(self.width - pad - 80, y, 80, BTN_HGT, "Refresh", self, BKLootWindow.onRefresh)
    self.refreshBtn:initialise()
    self:addChild(self.refreshBtn)

    y = y + BTN_HGT + pad
    local listH = self.height - y - BTN_HGT - pad * 3 - FONT_HGT
    self.list = ISScrollingListBox:new(pad, y, self.width - pad * 2, listH)
    self.list:initialise()
    self.list:instantiate()
    self.list:setFont(FONT, 3)
    self.list.itemheight = ROW_HGT
    self.list.drawBorder = true
    self.list.doDrawItem = BKLootWindow.doDrawRow
    self.list:setOnMouseDoubleClick(self, BKLootWindow.onDoubleClick)
    self:addChild(self.list)

    local by = y + listH + pad
    self.grabOneBtn = ISButton:new(pad, by, 90, BTN_HGT, "Grab 1", self, BKLootWindow.onGrabOne)
    self.grabOneBtn:initialise()
    self:addChild(self.grabOneBtn)
    self.grabAllBtn = ISButton:new(pad + 98, by, 90, BTN_HGT, "Grab all", self, BKLootWindow.onGrabAll)
    self.grabAllBtn:initialise()
    self:addChild(self.grabAllBtn)
    self.statusY = by + BTN_HGT + 2
end

function BKLootWindow.doDrawRow(list, y, item, alt)
    local row = item.item
    if (y + list:getYScroll() + ROW_HGT < 0) or (y + list:getYScroll() >= list.height) then return y + ROW_HGT end
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), ROW_HGT - 1, 0.3, 0.3, 0.75, 0.85)
    elseif alt then
        list:drawRect(0, y, list:getWidth(), ROW_HGT - 1, 0.08, 1, 1, 1)
    end
    local ty = y + 3
    list:drawText(tostring(#row.entries) .. "x", 6, ty, 0.6, 0.85, 0.9, 1, FONT)
    list:drawText(row.name, 50, ty, 0.95, 0.95, 0.95, 1, FONT)
    -- v0.17.1 (Tanner): no category column; the category filter above still narrows the list
    list:drawText(row.places, 280, ty, 0.75, 0.75, 0.75, 1, FONT)
    return y + ROW_HGT
end

function BKLootWindow:rescan()
    local rows, info = BKLootWindow.collect()
    for _, r in ipairs(rows) do r.places = placesText(r) end
    self.rows, self.info = rows, info
    self.lastScanMs = getTimestampMs()
    self.dirtyAt = nil
    self:applyFilter()
end

function BKLootWindow:applyFilter()
    local text = string.lower(self.filterBox and self.filterBox:getText() or "")
    local catKey = nil
    if self.catCombo and self.catCombo.selected and self.catCombo.selected > 1 then
        catKey = self.catCombo:getOptionData(self.catCombo.selected)
    end
    local keepKey = nil
    local sel = self.list.items[self.list.selected]
    if sel then keepKey = sel.item.key end
    local scroll = self.list:getYScroll()
    self.list:clear()
    local shown, shownItems = 0, 0
    for _, row in ipairs(self.rows or {}) do
        local okText = text == "" or string.find(string.lower(row.name), text, 1, true)
            or string.find(string.lower(row.fullType), text, 1, true)
        local okCat = catKey == nil or rowMatches(row, catKey)
        if okText and okCat then
            local li = self.list:addItem(row.name, row)
            li.height = ROW_HGT
            shown = shown + 1
            shownItems = shownItems + #row.entries
            if row.key == keepKey then self.list.selected = #self.list.items end
        end
    end
    if keepKey == nil or self.list.selected > #self.list.items then self.list.selected = math.min(1, #self.list.items) end
    self.list:setYScroll(scroll)
    self.shown, self.shownItems = shown, shownItems
end

function BKLootWindow.onFilterChanged(self)
    if self and self.applyFilter then self:applyFilter() end
end

function BKLootWindow.onRefresh(self) self:rescan() end

function BKLootWindow:selectedRow()
    local li = self.list.items[self.list.selected]
    return li and li.item or nil
end

function BKLootWindow:grabSelected(n)
    local row = self:selectedRow()
    if row == nil then return end
    BKLootWindow.grab(getSpecificPlayer(self.playerNum or 0), row, n)
end

function BKLootWindow.onGrabOne(self) self:grabSelected(1) end
function BKLootWindow.onGrabAll(self) self:grabSelected(100000) end
function BKLootWindow.onDoubleClick(self, row) if row then BKLootWindow.grab(getSpecificPlayer(self.playerNum or 0), row, 1) end end

function BKLootWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.dirtyAt and getTimestampMs() - self.dirtyAt >= BKLootWindow.DEBOUNCE_MS then self:rescan() end
end

function BKLootWindow:render()
    ISCollapsableWindow.render(self)
    if self.isCollapsed or self.info == nil then return end
    local text = string.format("%d of %d types, %d items shown (%d in base)%s", self.shown or 0, self.info.types,
        self.shownItems or 0, self.info.items, self.info.partial and "  - part of the base is not loaded" or "")
    self:drawText(text, BKLootWindow.PAD, self.statusY, 0.6, 0.6, 0.6, 1, FONT)
end

function BKLootWindow:close()
    BKLootWindow.pos = { x = self:getX(), y = self:getY() }
    self:setVisible(false)
    self:removeFromUIManager()
    if BKLootWindow.instance == self then BKLootWindow.instance = nil end
end

function BKLootWindow.isOpen() return BKLootWindow.instance ~= nil end

function BKLootWindow.open(playerNum)
    if BKLootWindow.instance then return BKLootWindow.instance end
    local pos = BKLootWindow.pos or { x = getPlayerScreenLeft(playerNum or 0) + 80, y = getPlayerScreenTop(playerNum or 0) + 80 }
    local o = BKLootWindow:new(pos.x, pos.y, BKLootWindow.WIDTH, BKLootWindow.HEIGHT)
    o.playerNum = playerNum or 0
    o:initialise()
    o:setTitle("Base loot")
    o:setResizable(false)
    o:addToUIManager()
    BKLootWindow.instance = o
    o:rescan()
    return o
end

function BKLootWindow.toggle(player)
    if BKLootWindow.instance then
        BKLootWindow.instance:close()
    else
        BKLootWindow.open(player and player:getPlayerNum() or 0)
    end
end

-- keep the list current while it is open (the keeper and the player both move things)
local function onContainerUpdate()
    local w = BKLootWindow.instance
    -- the first update starts the timer; later ones do not push it back (the keeper moves things every minute)
    if w and w.dirtyAt == nil then w.dirtyAt = getTimestampMs() end
end
Events.OnContainerUpdate.Add(onContainerUpdate)

table.insert(BKContextMenu.globalActions, {
    label = function() return BKLootWindow.isOpen() and "Hide base loot" or "Base loot (browse + grab)" end,
    fn = BKLootWindow.toggle,
})

return BKLootWindow
