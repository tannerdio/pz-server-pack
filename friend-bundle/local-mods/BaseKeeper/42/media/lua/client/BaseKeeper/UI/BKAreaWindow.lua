-- Base Keeper: loot area editor (v0.16.0, Tanner 2026-11-13: "the selection menus to set loot areas suck... i should be
-- able to select the whole upper level category and then edit out smaller pieces... i cant multi select... consider
-- every floor in the base zone"). One window instead of the nested right-click menus:
--   left  = every loot area, grouped by floor (upstairs, ground, basement), click one to edit it
--   right = a checklist of every category under its family. A family's box takes the whole family in one click;
--           unticking a row under it edits that piece out (BKLoot area.excl). Clicks never close anything, so any
--           number of rows can be ticked in one go. A search box narrows the list, counts show what the base holds.
-- Every click is applied at once through BKLoot.requestSetCats (the keeper replans on BaseKeeper_AreasChanged).
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "ISUI/ISModalDialog"
require "BaseKeeper/BKLog"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/Engine/BKTaxonomy"
require "BaseKeeper/Engine/BKZoneScan"
require "BaseKeeper/UI/BKAddZoneUI"
require "BaseKeeper/UI/BKOverlay"
require "BaseKeeper/UI/BKContextMenu"
require "BaseKeeper/UI/BKLootWindow"

BKAreaWindow = ISCollapsableWindow:derive("BKAreaWindow")

BKAreaWindow.instance = nil
BKAreaWindow.WIDTH = 840
BKAreaWindow.HEIGHT = 580
BKAreaWindow.LEFT_W = 300
BKAreaWindow.PAD = 8

local FONT = UIFont.Small
local FONT_HGT = getTextManager():getFontHeight(FONT)
local ROW_HGT = FONT_HGT + 8
local BTN_HGT = FONT_HGT + 8
local BOX = FONT_HGT - 2      -- tick box side
local INDENT = 18

local function copySet(t)
    local o = {}
    for k, v in pairs(t or {}) do if v == true then o[k] = true end end
    return o
end

local function floorLabel(z)
    if z == 0 then return "Ground floor" end
    if z > 0 then return "Floor +" .. tostring(z) end
    return "Basement " .. tostring(z)
end

-- cuts text to maxW pixels, ending in "..."
local function fit(text, maxW)
    local tm = getTextManager()
    if tm:MeasureStringX(FONT, text) <= maxW then return text end
    local n = string.len(text)
    while n > 1 and tm:MeasureStringX(FONT, string.sub(text, 1, n) .. "...") > maxW do n = n - 1 end
    return string.sub(text, 1, n) .. "..."
end

-- Rows of one family in display order: each broad row, the fine rows only it covers indented under it, then the
-- fine rows that stand alone (or that two broad rows share, like the food groups).
local ORDER = {}
local function orderedRows(family)
    if ORDER[family] then return ORDER[family] end
    local out, placed = {}, {}
    local cats = BKLoot.categoriesOf(family)
    for _, cat in ipairs(cats) do
        if not cat.fine and not cat.personal then
            table.insert(out, { cat = cat, indent = 1 })
            for _, childKey in ipairs(BKLoot.CHILDREN[cat.key] or {}) do
                local child = BKLoot.category(childKey)
                if child and child.family == family and not placed[childKey] and #(BKLoot.PARENTS[childKey] or {}) == 1 then
                    placed[childKey] = true
                    table.insert(out, { cat = child, indent = 2 })
                end
            end
        end
    end
    for _, cat in ipairs(cats) do
        if cat.fine and not placed[cat.key] then table.insert(out, { cat = cat, indent = 1 }) end
    end
    ORDER[family] = out
    return out
end

-- How many items of each category the base holds now (same walk as the loot browser). key -> count.
local function baseCounts()
    local counts = {}
    local ok, err = pcall(function()
        local rows = BKLootWindow.collect()
        local byClass, byGroup = {}, {}
        for _, row in ipairs(rows) do
            local n = #row.entries
            if row.class then byClass[row.class] = (byClass[row.class] or 0) + n end
            if row.group then byGroup[row.group] = (byGroup[row.group] or 0) + n end
        end
        for _, cat in ipairs(BKLoot.CATEGORIES) do
            local n = 0
            for _, cls in ipairs(cat.classes or {}) do n = n + (byClass[cls] or 0) end
            for _, g in ipairs(cat.groups or {}) do n = n + (byGroup[g] or 0) end
            counts[cat.key] = n
        end
    end)
    if not ok then BKLog.warn("loot area editor: base count failed: " .. tostring(err)) end
    return counts
end

-- "4 containers: 3 crate, 1 metal_shelves" for the area's own tiles
local function areaContainers(area)
    local ok, text = pcall(function()
        local scan = BKZoneScan.scan({ id = "area" .. tostring(area.id), x1 = area.x1, y1 = area.y1, x2 = area.x2,
            y2 = area.y2, z = area.z })
        local w, h = area.x2 - area.x1, area.y2 - area.y1
        if (scan.missingSquares or 0) >= w * h then return "not loaded (too far away)" end
        local n, byType, order = 0, {}, {}
        for _, c in ipairs(scan.containers) do
            if not c.noDest then
                n = n + 1
                if byType[c.ctype] == nil then byType[c.ctype] = 0; table.insert(order, c.ctype) end
                byType[c.ctype] = byType[c.ctype] + 1
            end
        end
        if n == 0 then return "no storage containers inside: nothing can be sorted here" end
        table.sort(order, function(a, b) return byType[a] > byType[b] end)
        local parts = {}
        for i, t in ipairs(order) do
            if i > 4 then table.insert(parts, "..."); break end
            table.insert(parts, tostring(byType[t]) .. " " .. t)
        end
        return string.format("%d container%s: %s", n, n == 1 and "" or "s", table.concat(parts, ", "))
    end)
    return ok and text or "?"
end

-- Selection -----------------------------------------------------------------------------------------------------

function BKAreaWindow:area()
    if self.areaId == nil then return nil end
    return BKLoot.get(self.areaId)
end

function BKAreaWindow:select(id)
    self.areaId = id
    local area = self:area()
    self.expanded = {}
    self.info = nil
    if area then
        -- open the families that already have something ticked, so the current state is visible at once
        for _, fam in ipairs(BKTaxonomy.FAMILIES) do
            local on, total = BKLoot.familyState(area, fam.key)
            if on > 0 and on < total then self.expanded[fam.key] = true end
        end
        self.info = areaContainers(area)
    end
    self.tree:setYScroll(0)
    self:rebuildTree()
end

-- runs fn on a copy of the area's selection and sends the result
function BKAreaWindow:apply(fn)
    local area = self:area()
    if area == nil then return end
    local sel = { cats = copySet(area.cats), excl = copySet(area.excl) }
    fn(sel)
    BKLoot.requestSetCats(getSpecificPlayer(self.playerNum or 0), area.id, sel.cats, sel.excl)
    self.dirty = true
end

-- Lists ---------------------------------------------------------------------------------------------------------

function BKAreaWindow:rebuildAreas()
    local list = self.areaList
    local scroll = list:getYScroll()
    list:clear()
    local areas = BKLoot.list()
    table.sort(areas, function(a, b)
        if a.z ~= b.z then return a.z > b.z end
        return a.id < b.id
    end)
    local perFloor = {}
    for _, a in ipairs(areas) do perFloor[a.z] = (perFloor[a.z] or 0) + 1 end
    local lastZ = nil
    for _, a in ipairs(areas) do
        if a.z ~= lastZ then
            lastZ = a.z
            list:addItem("floor", { kind = "floor", z = a.z, n = perFloor[a.z] })
        end
        list:addItem("area", { kind = "area", area = a, labels = BKLoot.labels(a) })
    end
    list.selected = -1
    list:setYScroll(scroll)
    self.areaCount = #areas
    if self.areaId and BKLoot.get(self.areaId) == nil then self:select(nil) end
end

function BKAreaWindow:rebuildTree()
    local list = self.tree
    local scroll = list:getYScroll()
    list:clear()
    list.selected = -1
    local area = self:area()
    if area == nil then return end
    local filter = string.lower(self.filterBox and self.filterBox:getText() or "")
    if filter == "" then
        list:addItem("personal", { kind = "personal" })
        list:addItem("overflow", { kind = "overflow" })
    end
    for _, fam in ipairs(BKTaxonomy.FAMILIES) do
        local rows = orderedRows(fam.key)
        local famMatch = filter ~= "" and string.find(string.lower(fam.label), filter, 1, true) ~= nil
        local shown = {}
        for _, r in ipairs(rows) do
            if filter == "" or famMatch or string.find(string.lower(r.cat.label), filter, 1, true) then
                table.insert(shown, r)
            end
        end
        if #shown > 0 then
            list:addItem("family", { kind = "family", fam = fam })
            if filter ~= "" or self.expanded[fam.key] then
                for _, r in ipairs(shown) do list:addItem("cat", { kind = "cat", cat = r.cat, indent = r.indent }) end
            end
        end
    end
    list:setYScroll(scroll)
end

-- Drawing -------------------------------------------------------------------------------------------------------

-- state: "on" | "some" | "off"
local function drawBox(list, x, y, state)
    local by = y + (ROW_HGT - BOX) / 2
    list:drawRect(x, by, BOX, BOX, 0.6, 0, 0, 0)
    if state == "on" then
        list:drawRect(x + 2, by + 2, BOX - 4, BOX - 4, 1, 0.3, 0.85, 0.9)
    elseif state == "some" then
        list:drawRect(x + 2, by + BOX / 2 - 2, BOX - 4, 4, 1, 0.95, 0.6, 0.15)
    end
    list:drawRectBorder(x, by, BOX, BOX, 1, 0.7, 0.7, 0.7)
end

function BKAreaWindow.drawAreaRow(list, y, item, alt)
    local d = item.item
    local win = list.window
    if (y + list:getYScroll() + ROW_HGT < 0) or (y + list:getYScroll() >= list.height) then return y + ROW_HGT end
    local ty = y + 4
    local w = list:getWidth()
    if d.kind == "floor" then
        list:drawRect(0, y, w, ROW_HGT - 1, 0.35, 0.25, 0.25, 0.3)
        local here = win.playerZ == d.z and "  (you are here)" or ""
        list:drawText(string.format("%s: %d area%s%s", floorLabel(d.z), d.n, d.n == 1 and "" or "s", here), 6, ty,
            0.85, 0.85, 0.9, 1, FONT)
        return y + ROW_HGT
    end
    local a = d.area
    if win.areaId == a.id then
        list:drawRect(0, y, w, ROW_HGT - 1, 0.35, 0.3, 0.75, 0.85)
    elseif list.mouseoverselected == item.index then
        list:drawRect(0, y, w, ROW_HGT - 1, 0.12, 1, 1, 1)
    end
    list:drawText("#" .. tostring(a.id), 8, ty, 0.95, 0.7, 0.3, 1, FONT)
    list:drawText(string.format("%dx%d", a.x2 - a.x1, a.y2 - a.y1), 44, ty, 0.6, 0.6, 0.6, 1, FONT)
    local empty = not BKLoot.hasCategories(a)
    local r, g, b = 0.92, 0.92, 0.92
    if empty then r, g, b = 0.9, 0.45, 0.4 elseif BKLoot.isPersonal(a) then r, g, b = 0.7, 0.7, 0.7 end
    list:drawText(fit(d.labels, w - 84 - 16), 84, ty, r, g, b, 1, FONT)
    return y + ROW_HGT
end

function BKAreaWindow.drawTreeRow(list, y, item, alt)
    local d = item.item
    local win = list.window
    if (y + list:getYScroll() + ROW_HGT < 0) or (y + list:getYScroll() >= list.height) then return y + ROW_HGT end
    local area = win:area()
    if area == nil then return y + ROW_HGT end
    local ty = y + 4
    local w = list:getWidth()
    if list.mouseoverselected == item.index then list:drawRect(0, y, w, ROW_HGT - 1, 0.1, 1, 1, 1) end
    if d.kind == "personal" then
        drawBox(list, 8, y, BKLoot.isPersonal(area) and "on" or "off")
        list:drawText("Personal (hands off): the keeper never stores here or takes from here", 8 + BOX + 8, ty,
            0.8, 0.8, 0.8, 1, FONT)
        return y + ROW_HGT
    end
    if d.kind == "overflow" then
        drawBox(list, 8, y, BKLoot.isOverflow(area) and "on" or "off")
        list:drawText("Overflow: takes anything that has no room where it belongs", 8 + BOX + 8, ty,
            0.8, 0.8, 0.8, 1, FONT)
        return y + ROW_HGT
    end
    if d.kind == "family" then
        local on, total = BKLoot.familyState(area, d.fam.key)
        list:drawRect(0, y, w, ROW_HGT - 1, 0.3, 0.2, 0.2, 0.25)
        local open = win.expanded[d.fam.key] or (win.filterBox and win.filterBox:getText() ~= "")
        list:drawText(open and "-" or "+", 8, ty, 0.8, 0.8, 0.8, 1, FONT)
        drawBox(list, 8 + INDENT, y, (on == 0 and "off") or (on == total and "on") or "some")
        list:drawText(d.fam.label, 8 + INDENT + BOX + 8, ty, 1, 1, 1, 1, FONT)
        local tag = (on == total and "all") or (on == 0 and "none") or string.format("%d of %d", on, total)
        list:drawText(tag, w - 16 - getTextManager():MeasureStringX(FONT, tag) - 8, ty, 0.65, 0.65, 0.65, 1, FONT)
        return y + ROW_HGT
    end
    local cat = d.cat
    local x = 8 + INDENT + d.indent * INDENT
    local on = BKLoot.isOn(area, cat.key)
    local out = area.excl ~= nil and area.excl[cat.key] == true
    drawBox(list, x, y, on and "on" or "off")
    local label = cat.label
    if out then label = label .. "   (left out)" end
    local r, g, b = 0.92, 0.92, 0.92
    if out then r, g, b = 0.9, 0.5, 0.45 elseif not on then r, g, b = 0.7, 0.7, 0.7 end
    list:drawText(label, x + BOX + 8, ty, r, g, b, 1, FONT)
    local n = win.counts and win.counts[cat.key] or nil
    if n and n > 0 then
        local tag = tostring(n) .. " in base"
        list:drawText(tag, w - 16 - getTextManager():MeasureStringX(FONT, tag) - 8, ty, 0.5, 0.65, 0.7, 1, FONT)
    end
    return y + ROW_HGT
end

-- Clicks --------------------------------------------------------------------------------------------------------

function BKAreaWindow.onAreaMouseDown(list, x, y)
    local row = list:rowAt(x, y)
    local item = list.items[row]
    if item == nil or item.item.kind ~= "area" then return end
    getSoundManager():playUISound("UISelectListItem")
    list.window:select(item.item.area.id)
end

function BKAreaWindow.onTreeMouseDown(list, x, y)
    local win = list.window
    local row = list:rowAt(x, y)
    local item = list.items[row]
    local area = win:area()
    if item == nil or area == nil then return end
    local d = item.item
    getSoundManager():playUISound("UISelectListItem")
    if d.kind == "personal" then
        local on = not BKLoot.isPersonal(area)
        win:apply(function(sel) BKLoot.toggle(sel, BKLoot.PERSONAL, on) end)
    elseif d.kind == "overflow" then
        local on = not BKLoot.isOverflow(area)
        win:apply(function(sel) BKLoot.toggle(sel, BKLoot.OVERFLOW, on) end)
    elseif d.kind == "family" then
        local bx = 8 + INDENT
        if x >= bx - 4 and x <= bx + BOX + 4 then
            -- the box: everything on, or everything off when it already is
            local on, total = BKLoot.familyState(area, d.fam.key)
            local turnOn = on < total
            win:apply(function(sel) BKLoot.toggleFamily(sel, d.fam.key, turnOn) end)
            if turnOn then win.expanded[d.fam.key] = true end
        else
            win.expanded[d.fam.key] = not win.expanded[d.fam.key]
            win:rebuildTree()
        end
    else
        local on = not BKLoot.isOn(area, d.cat.key)
        win:apply(function(sel) BKLoot.toggle(sel, d.cat.key, on) end)
    end
end

function BKAreaWindow.onFilterChanged(self)
    if self and self.rebuildTree then self:rebuildTree() end
end

function BKAreaWindow.onExpandAll(self)
    local any = false
    for _ in pairs(self.expanded) do any = true end
    self.expanded = {}
    if not any then
        for _, fam in ipairs(BKTaxonomy.FAMILIES) do self.expanded[fam.key] = true end
    end
    self:rebuildTree()
end

function BKAreaWindow.onClear(self)
    self:apply(function(sel) sel.cats, sel.excl = {}, {} end)
end

-- Marks a new area with the drag panel, then opens the editor on it. Also used by the right-click menu.
function BKAreaWindow.markNew(player)
    if player == nil then return end
    local playerNum = player:getPlayerNum()
    BKAddZoneUI.open(playerNum, {
        title = "Base Keeper Loot Area",
        confirmText = "Mark this loot area? Its category list opens next.",
        minSize = BKLoot.MIN_SIDE,
        maxSize = BKLoot.MAX_SIDE,
        color = BKOverlay.areaColor,
        onAdd = function(p, x1, y1, x2, y2, z)
            local area, reason = BKLoot.requestAdd(p, x1, y1, x2, y2, z)
            if area then
                local win = BKAreaWindow.open(playerNum, area.id)
                win.dirty = true
            elseif reason and HaloTextHelper then
                pcall(HaloTextHelper.addBadText, p, "Loot area not added: " .. tostring(reason))
            end
        end,
    })
end

function BKAreaWindow.onNew(self)
    BKAreaWindow.markNew(getSpecificPlayer(self.playerNum or 0))
end

function BKAreaWindow.onRemove(self)
    local area = self:area()
    if area == nil then return end
    local player = getSpecificPlayer(self.playerNum or 0)
    local id = area.id
    local modal = ISModalDialog:new(0, 0, 300, 120, "Remove loot area " .. tostring(id) .. "?", true, nil,
        function(_, button) if button.internal == "YES" then BKLoot.requestRemove(player, id) end end,
        self.playerNum or 0)
    modal:initialise()
    modal:addToUIManager()
end

-- Window --------------------------------------------------------------------------------------------------------

function BKAreaWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local pad = BKAreaWindow.PAD
    local top = self:titleBarHeight() + pad
    local leftW = BKAreaWindow.LEFT_W
    local bottom = self.height - pad

    -- left: areas
    self.leftTitleY = top
    local ly = top + FONT_HGT + 4
    local lh = bottom - BTN_HGT - pad - ly
    self.areaList = ISScrollingListBox:new(pad, ly, leftW, lh)
    self.areaList:initialise()
    self.areaList:instantiate()
    self.areaList:setFont(FONT, 4)
    self.areaList.itemheight = ROW_HGT
    self.areaList.drawBorder = true
    self.areaList.window = self
    self.areaList.doDrawItem = BKAreaWindow.drawAreaRow
    self.areaList.onMouseDown = BKAreaWindow.onAreaMouseDown
    self:addChild(self.areaList)

    local by = bottom - BTN_HGT
    self.newBtn = ISButton:new(pad, by, 150, BTN_HGT, "New area (drag)", self, BKAreaWindow.onNew)
    self.newBtn:initialise()
    self:addChild(self.newBtn)
    self.removeBtn = ISButton:new(pad + 158, by, 100, BTN_HGT, "Remove area", self, BKAreaWindow.onRemove)
    self.removeBtn:initialise()
    self:addChild(self.removeBtn)

    -- right: the selected area's categories
    local rx = pad + leftW + pad
    local rw = self.width - rx - pad
    self.rightX, self.rightW = rx, rw
    self.infoY = top
    local fy = top + FONT_HGT * 2 + 8
    self.filterBox = ISTextEntryBox:new("", rx, fy, 220, BTN_HGT)
    self.filterBox:initialise()
    self.filterBox:instantiate()
    self.filterBox.font = FONT
    if self.filterBox.setPlaceholderText then self.filterBox:setPlaceholderText("Find a category") end
    self.filterBox.onTextChangeFunction = BKAreaWindow.onFilterChanged
    self.filterBox.target = self
    self:addChild(self.filterBox)

    self.expandBtn = ISButton:new(rx + 228, fy, 130, BTN_HGT, "Open / close all", self, BKAreaWindow.onExpandAll)
    self.expandBtn:initialise()
    self:addChild(self.expandBtn)
    self.clearBtn = ISButton:new(rx + rw - 90, fy, 90, BTN_HGT, "Untick all", self, BKAreaWindow.onClear)
    self.clearBtn:initialise()
    self:addChild(self.clearBtn)

    local tyTop = fy + BTN_HGT + pad
    self.hintY = bottom - FONT_HGT
    self.tree = ISScrollingListBox:new(rx, tyTop, rw, self.hintY - 4 - tyTop)
    self.tree:initialise()
    self.tree:instantiate()
    self.tree:setFont(FONT, 4)
    self.tree.itemheight = ROW_HGT
    self.tree.drawBorder = true
    self.tree.window = self
    self.tree.doDrawItem = BKAreaWindow.drawTreeRow
    self.tree.onMouseDown = BKAreaWindow.onTreeMouseDown
    self:addChild(self.tree)
end

function BKAreaWindow:prerender()
    ISCollapsableWindow.prerender(self)
    local player = getSpecificPlayer(self.playerNum or 0)
    self.playerZ = player and math.floor(player:getZ()) or 0
    if self.dirty then
        self.dirty = false
        self:rebuildAreas()
        self:rebuildTree()
    end
end

function BKAreaWindow:render()
    ISCollapsableWindow.render(self)
    if self.isCollapsed then return end
    local pad = BKAreaWindow.PAD
    self:drawText(string.format("Loot areas, every floor (%d)", self.areaCount or 0), pad, self.leftTitleY,
        0.85, 0.85, 0.85, 1, FONT)
    local area = self:area()
    local has = area ~= nil
    self.removeBtn:setEnable(has)
    self.clearBtn:setEnable(has)
    self.expandBtn:setEnable(has)
    if not has then
        local msg = (self.areaCount or 0) == 0
            and "No loot areas yet. Press New area, then drag a rectangle over the containers."
            or "Pick an area on the left to choose what goes there."
        self:drawText(msg, self.rightX, self.infoY, 0.8, 0.8, 0.8, 1, FONT)
        return
    end
    local head = string.format("Area #%d  -  %s  -  %dx%d tiles  -  %s", area.id, floorLabel(area.z),
        area.x2 - area.x1, area.y2 - area.y1, self.info or "")
    self:drawText(fit(head, self.rightW), self.rightX, self.infoY, 0.95, 0.7, 0.3, 1, FONT)
    self:drawText(fit("Takes: " .. BKLoot.labels(area), self.rightW), self.rightX, self.infoY + FONT_HGT + 2,
        0.9, 0.9, 0.9, 1, FONT)
    self:drawText("Click a family's box to take all of it, then untick the pieces you don't want. Click its name to open it.",
        self.rightX, self.hintY, 0.55, 0.55, 0.55, 1, FONT)
end

function BKAreaWindow:close()
    BKAreaWindow.pos = { x = self:getX(), y = self:getY() }
    self:setVisible(false)
    self:removeFromUIManager()
    if BKAreaWindow.instance == self then BKAreaWindow.instance = nil end
end

function BKAreaWindow.isOpen() return BKAreaWindow.instance ~= nil end

-- Opens the editor (or brings the open one forward) and selects areaId when given.
function BKAreaWindow.open(playerNum, areaId)
    local o = BKAreaWindow.instance
    if o == nil then
        local pos = BKAreaWindow.pos or { x = getPlayerScreenLeft(playerNum or 0) + 60, y = getPlayerScreenTop(playerNum or 0) + 60 }
        o = BKAreaWindow:new(pos.x, pos.y, BKAreaWindow.WIDTH, BKAreaWindow.HEIGHT)
        o.playerNum = playerNum or 0
        o.expanded = {}
        o:initialise()
        o:setTitle("Base Keeper loot areas")
        o:setResizable(false)
        o:addToUIManager()
        BKAreaWindow.instance = o
        o.counts = baseCounts()
        o:rebuildAreas()
    end
    if areaId ~= nil then
        o:rebuildAreas()
        o:select(areaId)
    elseif o.areaId == nil then
        -- nothing asked for: start on the area the player stands in, if any
        local player = getSpecificPlayer(playerNum or 0)
        local here = player and BKLoot.at(player:getX(), player:getY(), player:getZ()) or nil
        if here then o:select(here.id) end
    end
    return o
end

function BKAreaWindow.toggle(player)
    if BKAreaWindow.instance then
        BKAreaWindow.instance:close()
    else
        BKAreaWindow.open(player and player:getPlayerNum() or 0)
    end
end

-- the area highlighted on the ground while the window is open (read by BKOverlay)
function BKAreaWindow.selectedArea()
    local w = BKAreaWindow.instance
    return w and w:area() or nil
end

-- any area change (this window, the right-click menu, a layout apply) refreshes both lists on the next frame
Events.BaseKeeper_AreasChanged.Add(function()
    if BKAreaWindow.instance then BKAreaWindow.instance.dirty = true end
end)

table.insert(BKContextMenu.globalActions, {
    label = function() return BKAreaWindow.isOpen() and "Hide loot areas" or "Loot areas (edit, every floor)" end,
    fn = BKAreaWindow.toggle,
})

return BKAreaWindow
