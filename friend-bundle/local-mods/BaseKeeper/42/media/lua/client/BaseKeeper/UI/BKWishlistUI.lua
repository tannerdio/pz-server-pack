-- Base Keeper: wishlist UI. Three small hooks on the vanilla inventory UI, nothing of its own:
--   * every container / inventory list row whose item is wanted and short (BKWishlist.status: have < want) gets a
--     small cyan + at the right end of the row, drawn after the vanilla row renderer (ISInventoryPane.renderdetails);
--   * the item tooltip (ISToolTipInv.render) grows by one line, "Wishlist: have 2 of 10 (Trapping)";
--   * right-click on an item: "Base Keeper wishlist" submenu with Want 1/2/5/10/20/50 and Remove. Literature is
--     tracked by the rule (unread / unwatched) and shows that instead of a count.
-- Status lookups are cached per item id for a second and dropped whenever BKWishlist.version changes.
require "ISUI/ISInventoryPane"
require "ISUI/ISToolTipInv"
require "ISUI/ISInventoryPaneContextMenu"
require "BaseKeeper/BKWishlist"

BKWishlistUI = BKWishlistUI or {}

BKWishlistUI.MARK = { r = 0.30, g = 0.85, b = 0.91, a = 1.0 } -- cyan, like the zone overlay
BKWishlistUI.MARK_SIZE = 8       -- px, arm length of the +
BKWishlistUI.MARK_RIGHT = 22     -- px from the pane's right edge to the + centre (clears the scrollbar)
BKWishlistUI.TEXT_SHORT = { r = 0.55, g = 0.9, b = 0.95 }
BKWishlistUI.TEXT_OK = { r = 0.6, g = 0.6, b = 0.6 }
BKWishlistUI.CACHE_MS = 1000
BKWishlistUI.WANTS = { 1, 2, 5, 10, 20, 50 }

local cache = {}       -- item id -> { ms, status }
local cacheVersion = -1

local function nowMs()
    local ok, v = pcall(getTimestampMs)
    return ok and tonumber(v) or 0
end

-- nil when not on the wishlist, else { have, want, label, group, lit }
function BKWishlistUI.statusFor(item, player)
    if item == nil then return nil end
    if cacheVersion ~= BKWishlist.version then cache = {}; cacheVersion = BKWishlist.version end
    local okId, id = pcall(function() return item:getID() end)
    if not okId or id == nil then return nil end
    local ms = nowMs()
    local e = cache[id]
    if e and ms - e.ms < BKWishlistUI.CACHE_MS then return e.status end
    local ok, st = pcall(BKWishlist.status, item, player)
    if not ok then st = nil end
    cache[id] = { ms = ms, status = st }
    return st
end

local function short(st)
    return st ~= nil and st.have < st.want
end

-- Row mark -----------------------------------------------------------------------------------------------------

-- A + made of two rects with a dark 1 px backing so it reads on selected (bright) rows too.
local function drawPlus(pane, cx, cy)
    local M, n = BKWishlistUI.MARK, BKWishlistUI.MARK_SIZE
    local h = math.floor(n / 2)
    pane:drawRect(cx - h - 1, cy - 2, n + 2, 4, 0.6, 0, 0, 0)
    pane:drawRect(cx - 2, cy - h - 1, 4, n + 2, 0.6, 0, 0, 0)
    pane:drawRect(cx - h, cy - 1, n, 2, M.a, M.r, M.g, M.b)
    pane:drawRect(cx - 1, cy - h, 2, n, M.a, M.r, M.g, M.b)
end

-- Walks the stacks exactly like the vanilla renderer (same y stepping, same collapse and stack-size breaks) and
-- marks the visible rows whose item is short with a +. Called after the vanilla pass, so the mark sits on top.
function BKWishlistUI.markRows(pane)
    if pane.itemslist == nil or pane.itemHgt == nil then return end
    local player = getSpecificPlayer(pane.player)
    if player == nil then return end
    local yScroll = pane:getYScroll()
    local height = pane:getHeight()
    local cx = pane:getWidth() - BKWishlistUI.MARK_RIGHT
    local maxInStack = (ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER or 20) + 1
    local y = 0
    for _, v in ipairs(pane.itemslist) do
        local count = 1
        for _, item in ipairs(v.items) do
            local top = y * pane.itemHgt + yScroll
            if top + pane.itemHgt >= 0 and top <= height then
                if short(BKWishlistUI.statusFor(item, player)) then
                    drawPlus(pane, cx, y * pane.itemHgt + pane.headerHgt + math.floor(pane.itemHgt / 2))
                end
            end
            y = y + 1
            if count == 1 and pane.collapsed ~= nil and v.name ~= nil and pane.collapsed[v.name] then break end
            if count == maxInStack then break end
            count = count + 1
        end
    end
end

-- v0.10.6: CleanUI replaces ISUI/ISInventoryPane.lua and swaps the global ISInventoryPane class at runtime
-- (CleanUI_Clean_ / CleanUI_Vanilla_ISInventoryPane), so a wrap made once at file load could be overwritten and
-- no + ever showed. The wrap is (re)applied to every pane class present, at load, game boot and game start.
local wrapped = {} -- wrapper functions we installed, so a class is never wrapped twice
local function wrapPaneClass(cls)
    if type(cls) ~= "table" or type(cls.renderdetails) ~= "function" or wrapped[cls.renderdetails] then return end
    local original = cls.renderdetails
    local function wrapper(self, doDragged)
        original(self, doDragged)
        if doDragged then return end
        local ok, err = pcall(BKWishlistUI.markRows, self)
        if not ok and BKLog then BKLog.dbg("wishlist mark failed: " .. tostring(err)) end
    end
    wrapped[wrapper] = true
    cls.renderdetails = wrapper
end

function BKWishlistUI.installRowMarks()
    wrapPaneClass(ISInventoryPane)
    wrapPaneClass(rawget(_G, "CleanUI_Clean_ISInventoryPane"))
    wrapPaneClass(rawget(_G, "CleanUI_Vanilla_ISInventoryPane"))
end

BKWishlistUI.installRowMarks()
Events.OnGameBoot.Add(BKWishlistUI.installRowMarks)
Events.OnGameStart.Add(function()
    BKWishlistUI.installRowMarks()
    local n = 0
    for _ in pairs(wrapped) do n = n + 1 end
    if BKLog then
        BKLog.info(string.format("wishlist row marks on %d pane class(es)%s", n,
            rawget(_G, "CleanUI_Clean_ISInventoryPane") and " (CleanUI present)" or ""))
    end
end)

-- Tooltip ------------------------------------------------------------------------------------------------------

local FONT = UIFont.Small

function BKWishlistUI.tooltipLine(tip)
    local st = BKWishlistUI.statusFor(tip.item, getSpecificPlayer(0))
    if st == nil then return end
    local text
    if st.lit then
        text = string.format("Wishlist: %s, %d unread at base (%s)", st.have < st.want and "unread, take it" or "copy already at base", st.have, tostring(st.group))
    else
        text = string.format("Wishlist: have %d of %d (%s)", st.have, st.want, tostring(st.group))
    end
    local tm = getTextManager()
    local lineH = tm:getFontHeight(FONT) + 4
    local w = math.max(tip.width, tm:MeasureStringX(FONT, text) + 12)
    local y = tip.height
    local bg, bd = tip.backgroundColor, tip.borderColor
    tip:setWidth(w)
    tip:setHeight(y + lineH)
    tip:drawRect(0, y, w, lineH, bg.a, bg.r, bg.g, bg.b)
    tip:drawRectBorder(0, y, w, lineH, bd.a, bd.r, bd.g, bd.b)
    local c = short(st) and BKWishlistUI.TEXT_SHORT or BKWishlistUI.TEXT_OK
    tip:drawText(text, 6, y + 2, c.r, c.g, c.b, 1, FONT)
end

local vanillaTooltipRender = ISToolTipInv.render
function ISToolTipInv:render()
    vanillaTooltipRender(self)
    if self.item == nil then return end
    if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end -- vanilla drew nothing
    pcall(BKWishlistUI.tooltipLine, self)
end

-- Right-click --------------------------------------------------------------------------------------------------

local function firstItem(items)
    local first = items and items[1] or nil
    if first == nil then return nil end
    if instanceof(first, "InventoryItem") then return first end
    if type(first) == "table" and first.items then return first.items[1] end
    return nil
end

local function onWant(fullType, n)
    BKWishlist.setWant(fullType, n)
end

local function onRemove(fullType)
    BKWishlist.remove(fullType)
end

function BKWishlistUI.fillContextMenu(playerNum, context, items)
    local item = firstItem(items)
    if item == nil then return end
    local player = getSpecificPlayer(playerNum)
    local okType, fullType = pcall(function() return item:getFullType() end)
    if not okType or fullType == nil then return end
    local okSt, st = pcall(BKWishlist.status, item, player)
    if not okSt then st = nil end
    local root = context:addOption("Base Keeper wishlist", nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)
    if st then
        local info = sub:addOption(string.format("%s: have %d, want %d", st.label, st.have, st.want), nil, nil)
        info.notAvailable = true
    end
    if st and st.lit then
        local rule = sub:addOption("Tracked by rule: unread skill book, recipe magazine or skill tape", nil, nil)
        rule.notAvailable = true
        return
    end
    local wantOpt = sub:addOption("Want", nil, nil)
    local wsub = ISContextMenu:getNew(sub)
    sub:addSubMenu(wantOpt, wsub)
    for _, n in ipairs(BKWishlistUI.WANTS) do
        local o = wsub:addOption(tostring(n), fullType, onWant, n)
        if st and st.want == n then wsub:setOptionChecked(o, true) end
    end
    if st then sub:addOption("Remove from wishlist", fullType, onRemove) end
end

Events.OnFillInventoryObjectContextMenu.Add(BKWishlistUI.fillContextMenu)

return BKWishlistUI
