-- Base Keeper: breakfast entries in the zone right-click menu. Single player shares one Lua state with the server
-- files, so BKCook is called directly; on a multiplayer client the entries are hidden.
require "BaseKeeper/UI/BKContextMenu"

BKCookMenu = BKCookMenu or {}

local function logPlan(player, zone)
    if not BKCook then return end
    BKLog.info("--- Breakfast plan requested for zone " .. tostring(zone.id) .. " ---")
    BKCook.logPlan(zone, player)
end

local function logDiag(player, zone)
    if not BKCook or not BKCook.logDiagnostics then return end
    BKLog.info("--- Cooking diagnostics for zone " .. tostring(zone.id) .. " ---")
    local ok, err = pcall(BKCook.logDiagnostics, zone, player)
    if not ok then BKLog.warn("diagnostics failed: " .. tostring(err)) end
end

local function prepNow(player, zone)
    if not BKCook then return end
    BKLog.info("--- Meal prep requested for zone " .. tostring(zone.id) .. " ---")
    local results = BKCook.prepZone(zone, player, "manual")
    if #results > 0 then
        local names = {}
        for _, r in ipairs(results) do table.insert(names, r.name) end
        pcall(function() player:setHaloNote("Meal prepped: " .. table.concat(names, ", ")) end)
    else
        local msg = results.ovenMeal and (results.ovenMeal .. " is already in the oven") or "Nothing to prep (see console)"
        pcall(function() player:setHaloNote(msg) end)
    end
end

local function toggle(player, zone)
    if not BKCook then return end
    BKCook.setEnabled(not BKCook.isEnabled())
end

if not isClient() then
    table.insert(BKContextMenu.zoneActions, { label = "Log meal plan + calories (console)", fn = logPlan })
    table.insert(BKContextMenu.zoneActions, { label = "Prep a meal now", fn = prepNow })
    table.insert(BKContextMenu.zoneActions, { label = "Log cooking diagnostics (console)", fn = logDiag })
    table.insert(BKContextMenu.zoneActions, {
        label = function() return (BKCook and BKCook.isEnabled()) and "Meal prep: on (click to turn off)"
            or "Meal prep: off (click to turn on)" end,
        fn = toggle,
    })
end

return BKCookMenu
