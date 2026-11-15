-- Base Keeper: draws every zone (cyan), loot area (amber) and personal area (grey) as a tinted rectangle on the ground.
-- addAreaHighlightForPlayer is immediate-mode (it must be called every frame), so this is a 1x1 invisible UI
-- element whose prerender does the call, the same way the vanilla livestock-zone panel draws its drag rectangle.
require "ISUI/ISUIElement"
require "BaseKeeper/BKZones"
require "BaseKeeper/BKLoot"

BKOverlay = ISUIElement:derive("BKOverlay")

BKOverlay.enabled = false -- off unless toggled from the Base Keeper menu or while marking a zone / area
BKOverlay.instance = nil
BKOverlay.color = { r = 0.3, g = 0.85, b = 0.9, a = 0.25 }
BKOverlay.areaColor = { r = 0.95, g = 0.6, b = 0.15, a = 0.3 }
BKOverlay.personalColor = { r = 0.7, g = 0.7, b = 0.7, a = 0.3 }
BKOverlay.selectedColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.45 } -- the area selected in the loot area window
BKOverlay.RANGE = 120 -- tiles from the player beyond which zones are not drawn

-- v0.18.2 (Tanner: "zone overlay is weird when on basement"): everything is drawn for the floor the player stands
-- on only. A zone shows the part of it that exists on that floor (BKZones.floorBox: the marked rectangle on its own
-- floor, the box around the real tiles in a basement or upstairs); a loot area shows only on its own floor.
local function drawZones(zones, px, py, pz, color)
    for _, zone in pairs(zones or {}) do
        local cx, cy = math.floor((zone.x1 + zone.x2) / 2), math.floor((zone.y1 + zone.y2) / 2)
        if math.abs(cx - px) < BKOverlay.RANGE and math.abs(cy - py) < BKOverlay.RANGE then
            local ok, box = pcall(BKZones.floorBox, zone, pz)
            if ok and box then
                addAreaHighlightForPlayer(0, box.x1, box.y1, box.x2, box.y2, pz, color.r, color.g, color.b, color.a)
            end
        end
    end
end

local function drawRects(rects, px, py, pz, color, personalColor)
    for _, r in pairs(rects or {}) do
        local cx, cy = math.floor((r.x1 + r.x2) / 2), math.floor((r.y1 + r.y2) / 2)
        if r.z == pz and math.abs(cx - px) < BKOverlay.RANGE and math.abs(cy - py) < BKOverlay.RANGE then
            local c = (personalColor and BKLoot.isPersonal(r)) and personalColor or color
            addAreaHighlightForPlayer(0, r.x1, r.y1, r.x2, r.y2, r.z, c.r, c.g, c.b, c.a)
        end
    end
end

function BKOverlay:prerender()
    local marking = BKAddZoneUI and BKAddZoneUI.instance ~= nil
    local editing = BKAreaWindow and BKAreaWindow.instance ~= nil -- the loot area window shows the areas while open
    if not (BKOverlay.enabled or marking or editing or BKOverlay.sections) then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local px, py = player:getX(), player:getY()
    local pz = math.floor(player:getZ())
    if BKZones and BKZones.data then drawZones(BKZones.data.zones, px, py, pz, BKOverlay.color) end
    if BKLoot and BKLoot.data then drawRects(BKLoot.data.areas, px, py, pz, BKOverlay.areaColor, BKOverlay.personalColor) end
    if editing then
        -- the area being edited is drawn a second time, bright, so it stands out from the others
        local sel = BKAreaWindow.selectedArea()
        if sel and sel.z == pz then
            local c = BKOverlay.selectedColor
            addAreaHighlightForPlayer(0, sel.x1, sel.y1, sel.x2, sel.y2, sel.z, c.r, c.g, c.b, c.a)
        end
    end
    if BKOverlay.sections then pcall(drawSections, px, py, player:getZ()) end
end

-- v0.11.0 sections: each sectioned container tile, green when its role is accepted, blue when only suggested,
-- dim grey with no suggestion. Uses BKSections' 10 s cache, so the zone is rescanned at most every 10 s.
BKOverlay.sections = false
BKOverlay.sectionColors = {
    role = { r = 0.35, g = 0.9, b = 0.4, a = 0.35 },
    suggest = { r = 0.35, g = 0.55, b = 1.0, a = 0.3 },
    none = { r = 0.5, g = 0.5, b = 0.5, a = 0.2 },
    planned = { r = 0.85, g = 0.4, b = 0.95, a = 0.4 }, -- v0.13.0: a layout plan not yet applied
}

local function drawSections(px, py, pz)
    if not (BKSections and BKZones and BKZones.list) then return end
    for _, zone in ipairs(BKZones.list()) do
        local cx, cy = math.floor((zone.x1 + zone.x2) / 2), math.floor((zone.y1 + zone.y2) / 2)
        if math.abs(cx - px) < BKOverlay.RANGE and math.abs(cy - py) < BKOverlay.RANGE then
            local plan = BKLayout and BKLayout.lastPlan and BKLayout.lastPlan[zone.id] or nil
            if plan then
                local col = BKOverlay.sectionColors.planned
                for _, room in ipairs(plan.rooms) do
                    for _, t in ipairs(room.tiles) do
                        if #t.keys > 0 then addAreaHighlightForPlayer(0, t.x, t.y, t.x + 1, t.y + 1, t.z, col.r, col.g, col.b, col.a) end
                    end
                end
            else
                for _, s in ipairs(BKSections.forZone(zone)) do
                    local col = (s.role and BKOverlay.sectionColors.role) or (s.suggest and BKOverlay.sectionColors.suggest)
                        or BKOverlay.sectionColors.none
                    for _, c in ipairs(s.containers) do
                        addAreaHighlightForPlayer(0, c.x, c.y, c.x + 1, c.y + 1, c.z, col.r, col.g, col.b, col.a)
                    end
                end
            end
        end
    end
end

function BKOverlay.toggleSections()
    BKOverlay.sections = not BKOverlay.sections
    return BKOverlay.sections
end

function BKOverlay:render() end

function BKOverlay.toggle()
    BKOverlay.enabled = not BKOverlay.enabled
    return BKOverlay.enabled
end

function BKOverlay.ensure()
    if BKOverlay.instance and BKOverlay.instance.javaObject then return BKOverlay.instance end
    BKOverlay.instance = nil
    local o = BKOverlay:new(0, 0, 1, 1)
    o:initialise()
    o.wantMouseEvents = false
    o:setVisible(true)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o:addToUIManager()
    BKOverlay.instance = o
    return o
end

Events.OnGameStart.Add(BKOverlay.ensure)

return BKOverlay
