-- Base Keeper: debug entries in the zone right-click menu. Logs the sort plan to console.txt without moving anything.
require "BaseKeeper/UI/BKContextMenu"
require "BaseKeeper/Engine/BKPlanner"

BKDebugMenu = BKDebugMenu or {}

local function logPlan(player, zone)
    BKLog.info("--- Log sort plan requested for zone " .. tostring(zone.id) .. " ---")
    BKPlanner.logPlan(zone)
end

local function classifyHands(player, zone)
    local item = player:getPrimaryHandItem() or player:getSecondaryHandItem()
    if not item then BKLog.info("classify: nothing in hands"); return end
    local class, why, sure, group = BKItemClass.classify(item)
    BKLog.info(string.format("classify %s -> %s / %s (%s) (%s, %s) displaycat=%s", tostring(item:getDisplayName()), class,
        tostring(group), BKItemClass.groupLabel(group), why, sure and "certain" or "guess", tostring(item:getDisplayCategory())))
    local c, s = BKPlanner.bestDestination(BKPlanner.plan(zone).scan, class, sure, item, -- fallback = true: same rule as the floor
        { x = player:getX(), y = player:getY(), z = player:getZ() }, nil, nil, true)
    if c then
        BKLog.info(string.format("  best destination: %s(%s) @%d,%d score=%.1f", c.ctype, c.place or "?", c.x, c.y, s))
    else
        BKLog.info("  no destination in zone")
    end
end

table.insert(BKContextMenu.zoneActions, { label = "Log sort plan (console)", fn = logPlan })
table.insert(BKContextMenu.zoneActions, { label = "Classify item in hands (console)", fn = classifyHands })

return BKDebugMenu
