-- Base Keeper: right-click menu. "Base Keeper" submenu with Mark zone / zone info / Log sort plan / Remove zone,
-- plus loot areas: Mark loot area / area info / Edit loot area (opens UI/BKAreaWindow) / Remove loot area.
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"
require "BaseKeeper/BKSections"
require "BaseKeeper/BKLayout"
require "BaseKeeper/Engine/BKTaxonomy"
require "BaseKeeper/UI/BKAddZoneUI"
require "BaseKeeper/UI/BKOverlay"

BKContextMenu = BKContextMenu or {}

-- Other files append {label=, fn=function(player, zone)} here (shown inside a zone; label may be a function)...
BKContextMenu.zoneActions = BKContextMenu.zoneActions or {}
-- ...and {label=, fn=function(player)} here (shown everywhere, next to the overlay toggle).
BKContextMenu.globalActions = BKContextMenu.globalActions or {}

local function clickedSquare(playerNum, context, worldobjects)
    if context and context.x and context.y then
        local player = getSpecificPlayer(playerNum)
        local z = player and player:getZ() or 0
        local wx = screenToIsoX(playerNum, context.x, context.y, z)
        local wy = screenToIsoY(playerNum, context.x, context.y, z)
        local sq = getCell():getGridSquare(wx, wy, z)
        if sq then return sq end
    end
    for _, obj in ipairs(worldobjects) do
        if obj and obj.getSquare then
            local sq = obj:getSquare()
            if sq then return sq end
        end
    end
    return nil
end

local function onMarkZone(player)
    BKAddZoneUI.open(player:getPlayerNum())
end

local function confirm(player, text, onYes)
    local modal = ISModalDialog:new(0, 0, 300, 120, text, true,
        nil, function(_, button) if button.internal == "YES" then onYes() end end,
        player:getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
    if JoypadState.players[player:getPlayerNum() + 1] then
        modal.prevFocus = JoypadState.players[player:getPlayerNum() + 1].focus
        setJoypadFocus(player:getPlayerNum(), modal)
    end
end

local function onRemoveZone(player, zone)
    confirm(player, "Remove Base Keeper zone " .. tostring(zone.id) .. "?",
        function() BKZones.requestRemove(player, zone.id) end)
end

-- Loot areas ------------------------------------------------------------------------------------------------

-- v0.16.0: categories are edited in the loot area window (UI/BKAreaWindow.lua), not in nested menus. The window
-- file loads after this one, so it is looked up when the entry is clicked.
local function onMarkArea(player)
    if BKAreaWindow then BKAreaWindow.markNew(player) end
end

local function onEditArea(player, area)
    if BKAreaWindow then BKAreaWindow.open(player:getPlayerNum(), area.id) end
end

local function onRemoveArea(player, area)
    confirm(player, "Remove loot area " .. tostring(area.id) .. "?",
        function() BKLoot.requestRemove(player, area.id) end)
end

-- v0.12.0: categories are nested by family ("Workshop" -> Tools (all), Carpentry, Metalwork...). keep(cat) filters,
-- ticked(cat) says whether the entry is checked, onPick(player, cat.key) is the click handler with `arg` first.
local function fillCategoryTree(parent, player, keep, ticked, onPick, arg)
    for _, fam in ipairs(BKTaxonomy.FAMILIES) do
        local cats = {}
        for _, cat in ipairs(BKLoot.categoriesOf(fam.key)) do
            if keep == nil or keep(cat) then table.insert(cats, cat) end
        end
        if #cats > 0 then
            local n = 0
            for _, cat in ipairs(cats) do if ticked(cat) then n = n + 1 end end
            local famOpt = parent:addOption(fam.label .. (n > 0 and string.format("  (%d ticked)", n) or ""), nil, nil)
            local famSub = ISContextMenu:getNew(parent)
            parent:addSubMenu(famOpt, famSub)
            for _, cat in ipairs(cats) do
                local o = famSub:addOption((cat.fine and "   " or "") .. cat.label, player, onPick, arg, cat.key)
                famSub:setOptionChecked(o, ticked(cat))
            end
        end
    end
end

local function fillArea(sub, player, sq)
    local area = sq and BKLoot.at(sq:getX(), sq:getY(), sq:getZ()) or nil
    if not area then
        sub:addOption("Mark loot area here", player, onMarkArea)
        return
    end
    local text = BKLoot.labels(area)
    if string.len(text) > 70 then text = string.sub(text, 1, 67) .. "..." end
    local info = sub:addOption(string.format("Loot area %d: %s", area.id, text), nil, nil)
    info.notAvailable = true
    sub:addOption(string.format("Edit loot area %d (what goes here)", area.id), player, onEditArea, area)
    sub:addOption("Remove loot area", player, onRemoveArea, area)
end

-- Sections (v0.11.0) ----------------------------------------------------------------------------------------------
-- "Sections" submenu inside a zone: the clicked container's section (profile, suggestion, accept, set role) and the
-- zone-wide entries. Suggestions never act until accepted.

local function onSectionRole(player, s, key)
    BKSections.requestRole(player, s, key)
end

local function onAcceptAll(player, zone)
    local n = BKSections.requestAcceptAll(player, zone)
    if HaloTextHelper then pcall(HaloTextHelper.addText, player, string.format("Accepted %d section suggestion(s)", n)) end
end

local function onClearAll(player)
    confirm(player, "Clear every section role? Suggestions stay; nothing is moved back.", function() BKSections.requestClearAll(player) end)
end

-- Layout (v0.13.0, "Zone Theory"): plan every storage tile's role from room, entrance, fit and stock; apply as
-- section roles, optionally removing the loot areas inside the zone. Nothing moves until Tanner applies it.
local function onPlanLayout(player, zone)
    local plan = BKLayout.log(zone)
    if plan then
        BKOverlay.sections = true
        if HaloTextHelper then pcall(HaloTextHelper.addText, player, plan.summary .. " (console has the tile list)") end
    else
        if HaloTextHelper then pcall(HaloTextHelper.addText, player, "Layout failed, see console") end
    end
end

local function onApplyLayout(player, zone, replaceAreas)
    local areas = BKLayout.areasInside(zone)
    local text = replaceAreas
        and string.format("Apply the planned layout to zone %d and remove its %d loot area(s) (personal ones stay)? Items are then re-sorted a few at a time.", zone.id, #areas)
        or string.format("Apply the planned layout to zone %d? Loot areas stay and still win over the roles under them.", zone.id)
    confirm(player, text, function()
        local n, removed = BKLayout.apply(player, zone, replaceAreas)
        if HaloTextHelper and n then
            pcall(HaloTextHelper.addText, player, string.format("Layout applied: %d tile roles, %d loot areas removed", n, removed))
        end
    end)
end

local function fillLayout(ssub, player, zone)
    local opt = ssub:addOption("Layout (Zone Theory)", nil, nil)
    local lsub = ISContextMenu:getNew(ssub)
    ssub:addSubMenu(opt, lsub)
    local plan = BKLayout.lastPlan[zone.id]
    if plan then
        local head = lsub:addOption(plan.summary, nil, nil)
        head.notAvailable = true
    end
    lsub:addOption(plan and "Re-plan layout (console + overlay)" or "Plan layout (console + overlay)", player, onPlanLayout, zone)
    lsub:addOption("Apply layout, replace loot areas in this zone", player, onApplyLayout, zone, true)
    lsub:addOption("Apply layout, keep loot areas", player, onApplyLayout, zone, false)
    if plan then lsub:addOption("Forget plan", nil, function() BKLayout.forget(zone) end) end
end

local function fillSections(sub, player, zone, sq)
    local opt = sub:addOption("Sections", nil, nil)
    local ssub = ISContextMenu:getNew(sub)
    sub:addSubMenu(opt, ssub)
    local s = sq and BKSections.at(zone, sq:getX(), sq:getY(), sq:getZ()) or nil
    if s then
        local head = ssub:addOption(string.format("Section %d: %s, %s (%.0f/%.0f kg)", s.index, s.room, s.typesText, s.used, s.cap), nil, nil)
        head.notAvailable = true
        local holds = ssub:addOption("Holds: " .. s.contentsText, nil, nil)
        holds.notAvailable = true
        local roleText = s.role == "mixed" and "mixed" or BKSections.catLabel(s.role)
        local cur = ssub:addOption("Role: " .. roleText .. "   suggested: " .. (s.suggest and BKSections.catLabel(s.suggest) or "none"), nil, nil)
        cur.notAvailable = true
        if s.suggest and s.role ~= s.suggest then
            ssub:addOption("Accept suggestion: " .. BKSections.catLabel(s.suggest), player, onSectionRole, s, s.suggest)
        end
        local setOpt = ssub:addOption("Set section role", nil, nil)
        local setSub = ISContextMenu:getNew(ssub)
        ssub:addSubMenu(setOpt, setSub)
        fillCategoryTree(setSub, player,
            function(cat) return not cat.personal and cat.key ~= "trash" and cat.key ~= "food_cold" end,
            function(cat) return BKSections.hasKey(s.role, cat.key) end,
            onSectionRole, s)
        if s.role then ssub:addOption("Clear section role", player, onSectionRole, s, nil) end
    else
        local none = ssub:addOption("No section here (right-click a storage container)", nil, nil)
        none.notAvailable = true
    end
    ssub:addOption("Accept all suggested sections", player, onAcceptAll, zone)
    ssub:addOption("Log sections (console)", player, function() BKSections.logZone(zone) end)
    ssub:addOption(BKOverlay.sections and "Hide sections on overlay" or "Show sections on overlay", nil, BKOverlay.toggleSections)
    ssub:addOption("Clear all section roles", player, onClearAll)
end

-- v0.17.0 (Tanner: "the whole basekeeper menu, too much bloat"): the right-click menu is one entry that opens the
-- Base Keeper panel (UI/BKPanel.lua). The full list below is still built by fillFull, which the panel shows under
-- Tools -> Advanced. BKContextMenu.LEGACY = true puts the old submenu back in the right-click menu.
BKContextMenu.LEGACY = false

function BKContextMenu.openPanel(player, sq)
    if BKPanel then BKPanel.open(player:getPlayerNum(), sq) end
end

function BKContextMenu.fill(playerNum, context, worldobjects, test)
    if test then return ISWorldObjectContextMenu.setTest() end
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local sq = clickedSquare(playerNum, context, worldobjects)

    if BKPanel and not BKContextMenu.LEGACY then
        context:addOption("Base Keeper", player, BKContextMenu.openPanel, sq)
        return
    end
    local root = context:addOption("Base Keeper", worldobjects, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)
    BKContextMenu.fillFull(sub, player, sq)
end

-- Every entry the mod has, for the square sq (zone, loot area and section entries depend on it).
function BKContextMenu.fillFull(sub, player, sq)
    local zone = sq and BKZones.at(sq:getX(), sq:getY(), sq:getZ()) or nil
    if zone then
        local info = sub:addOption(string.format("Zone %d: %dx%d tiles, sorting the floor", zone.id,
            BKZones.width(zone), BKZones.height(zone)), nil, nil)
        info.notAvailable = true
        for _, action in ipairs(BKContextMenu.zoneActions) do
            local label = type(action.label) == "function" and action.label() or action.label
            sub:addOption(label, player, action.fn, zone)
        end
        fillLayout(sub, player, zone)
        fillSections(sub, player, zone, sq)
        sub:addOption("Remove zone", player, onRemoveZone, zone)
    else
        sub:addOption("Mark zone here", player, onMarkZone)
    end
    fillArea(sub, player, sq)
    for _, action in ipairs(BKContextMenu.globalActions) do
        local label = type(action.label) == "function" and action.label() or action.label
        sub:addOption(label, player, action.fn)
    end
    sub:addOption(BKOverlay.enabled and "Hide zone overlay" or "Show zone overlay", nil, BKOverlay.toggle)
end

Events.OnFillWorldObjectContextMenu.Add(BKContextMenu.fill)

return BKContextMenu
