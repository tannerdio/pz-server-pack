-- EFZ Boxes Only. Escape From Zomboid Firearms (EFZ) loot never makes single loose rounds.
--
-- Every EFZ loot path (container fill, zombie pockets, foraging, the world replacer, GunSwap)
-- draws ammunition with Loot.chooseKind and makes the items with LootItems.create. A loose-round
-- draw is turned into the same round's box here, and the number of loose rounds it stood for is
-- paid out in boxes: n rounds of a 20-round box give n/20 boxes on average (whole boxes, the
-- remainder by chance). Launcher shots have no box and stay as they are.
--
-- Only new loot changes. Loose rounds already lying in the world stay.

-- 1 = the same total ammo as before, 2 = twice as much from former loose-round rolls, and so on.
local AMOUNT = 1

local okLoot, Loot = pcall(require, 'TW/Loot')
local okItems, LI = pcall(require, 'TW/LootItems')
if not okLoot or not okItems or type(Loot) ~= 'table' or type(LI) ~= 'table'
        or not Loot.chooseKind or not Loot.roundOf or not Loot.roundItem or not LI.create then
    print('[EFZBoxesOnly] Escape From Zomboid Firearms loot code not found, doing nothing')
    return
end
if Loot.EFZBoxesOnly then return end
Loot.EFZBoxesOnly = true

local chooseKind = Loot.chooseKind
function Loot.chooseKind(kind, ctx, o, rng, noVanilla, people)
    local choice = chooseKind(kind, ctx, o, rng, noVanilla, people)
    if choice and choice.form == 'loose' then
        local e = Loot.roundOf(choice.type)
        local row = e and e.row
        local perBox = row and tonumber(row.perBox) or 0
        if row and not row.launcher and perBox > 1 then
            local box = Loot.roundItem(row, 'box', o)
            if box and box ~= choice.type then
                choice.type = box
                choice.form = 'box'
                choice.roundsPerBox = perBox
            end
        end
    end
    return choice
end

local create = LI.create
function LI.create(choice)
    if not choice or not choice.roundsPerBox then return create(choice) end
    -- choice.count is still the number of loose rounds; the caller may reuse the table, so
    -- work on a copy.
    local boxes = (choice.count or 1) * AMOUNT / choice.roundsPerBox
    local whole = math.floor(boxes)
    if Loot.rng() < boxes - whole then whole = whole + 1 end
    if whole <= 0 then return {} end
    local copy = {}
    for k, v in pairs(choice) do copy[k] = v end
    copy.count = whole
    return create(copy)
end

print('[EFZBoxesOnly] loose rounds become boxes')
