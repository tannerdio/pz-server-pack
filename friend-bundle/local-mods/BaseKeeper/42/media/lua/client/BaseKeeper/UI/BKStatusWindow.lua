-- Base Keeper: the status window. A small vanilla ISCollapsableWindow (title bar, pin, close) listing BKStatus
-- alerts and the wishlist, nothing else: no buttons, no scrolling, it grows to fit its lines. Opened and closed
-- from the Base Keeper right-click menu ("Base status"); position is kept for the session.
require "ISUI/ISCollapsableWindow"
require "BaseKeeper/BKStatus"
require "BaseKeeper/BKWishlist"
require "BaseKeeper/UI/BKContextMenu"

BKStatusWindow = ISCollapsableWindow:derive("BKStatusWindow")

BKStatusWindow.instance = nil
BKStatusWindow.WIDTH = 300
BKStatusWindow.PAD = 8
BKStatusWindow.COLORS = {
    head = { r = 0.6, g = 0.6, b = 0.6 },
    bad = { r = 1.0, g = 0.45, b = 0.4 },
    quiet = { r = 0.95, g = 0.8, b = 0.5 },
    want = { r = 0.9, g = 0.9, b = 0.9 },
    ok = { r = 0.5, g = 0.9, b = 0.55 },
}

local FONT = UIFont.Small
local FONT_HGT = getTextManager():getFontHeight(FONT)

-- Lines are rebuilt only when BKStatus publishes a new version.
function BKStatusWindow:buildLines()
    local cur = BKStatus.current
    local C = BKStatusWindow.COLORS
    local lines = {}
    local function add(text, color) table.insert(lines, { text = text, color = color }) end
    if cur.at == nil then
        add("No status yet (updates every 10 game minutes)", C.head)
    else
        add("ALERTS", C.head)
        if #cur.alerts == 0 then add("  cold storage fine", C.ok) end
        for _, a in ipairs(cur.alerts) do add("  " .. a.text, a.bad and C.bad or C.quiet) end
        add("WISHLIST", C.head)
        if #cur.wants == 0 then add("  nothing low", C.ok) end
        for _, w in ipairs(cur.wants) do add("  " .. BKStatus.describeWant(w), C.want) end
        if cur.partial then add("(a zone is partly unloaded, counts incomplete)", C.head) end
    end
    -- the wishlist proper (BKWishlist): short rows by group, have/want, plus how fresh the base count is
    add("LOOT TO FIND", C.head)
    for _, l in ipairs(BKWishlist.lines()) do add(l.text, C[l.kind] or C.want) end
    self.lines = lines
    self.linesVersion = BKStatus.version + BKWishlist.version * 100000
    local h = self:titleBarHeight() + BKStatusWindow.PAD * 2 + #lines * FONT_HGT
    local w = BKStatusWindow.WIDTH
    for _, l in ipairs(lines) do
        w = math.max(w, getTextManager():MeasureStringX(FONT, l.text) + BKStatusWindow.PAD * 2)
    end
    self:setWidth(w)
    self:setHeight(h)
end

function BKStatusWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.linesVersion ~= BKStatus.version + BKWishlist.version * 100000 or self.lines == nil then self:buildLines() end
end

function BKStatusWindow:render()
    ISCollapsableWindow.render(self)
    if self.isCollapsed then return end
    local y = self:titleBarHeight() + BKStatusWindow.PAD
    for _, l in ipairs(self.lines or {}) do
        self:drawText(l.text, BKStatusWindow.PAD, y, l.color.r, l.color.g, l.color.b, 1, FONT)
        y = y + FONT_HGT
    end
end

function BKStatusWindow:close()
    BKStatusWindow.pos = { x = self:getX(), y = self:getY() }
    self:setVisible(false)
    self:removeFromUIManager()
    if BKStatusWindow.instance == self then BKStatusWindow.instance = nil end
end

function BKStatusWindow.isOpen()
    return BKStatusWindow.instance ~= nil
end

function BKStatusWindow.open(playerNum)
    if BKStatusWindow.instance then return BKStatusWindow.instance end
    local pos = BKStatusWindow.pos or { x = getPlayerScreenLeft(playerNum or 0) + 20, y = getPlayerScreenTop(playerNum or 0) + 120 }
    local o = BKStatusWindow:new(pos.x, pos.y, BKStatusWindow.WIDTH, 100)
    o:initialise()
    o:setTitle("Base Keeper")
    o:setResizable(false)
    o:addToUIManager()
    BKStatusWindow.instance = o
    -- fresh numbers when it opens; the ten-minute tick keeps them current afterwards
    pcall(BKStatus.refresh, "open")
    pcall(BKWishlist.recount, "open")
    return o
end

function BKStatusWindow.toggle(player)
    if BKStatusWindow.instance then
        BKStatusWindow.instance:close()
    else
        BKStatusWindow.open(player and player:getPlayerNum() or 0)
    end
end

table.insert(BKContextMenu.globalActions, {
    label = function() return BKStatusWindow.isOpen() and "Hide base status" or "Base status" end,
    fn = BKStatusWindow.toggle,
})
table.insert(BKContextMenu.zoneActions, { label = "Log base status (console)", fn = function() BKStatus.logStatus() end })
table.insert(BKContextMenu.zoneActions, { label = "Log wishlist (console)", fn = function() BKWishlist.logReport() end })

return BKStatusWindow
