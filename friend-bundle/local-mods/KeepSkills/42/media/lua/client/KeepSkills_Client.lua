-- Keep Skills, client half.
-- The server owns the skill records and the XP. It tells this client which levels the
-- character should have; this side only raises its own levels to match (never lowers).

if not isClient() then return end

local MOD = "KeepSkills"

local function onServerCommand(module, command, args)
    if module ~= MOD or command ~= "apply" or not args or not args.levels then return end
    local player = getPlayer()
    if not player or player:isDead() then return end
    for id, value in pairs(args.levels) do
        local level = tonumber(value)
        local t = Perks.FromString(id)
        local perk = t and t ~= Perks.MAX and t ~= Perks.None and PerkFactory.getPerk(t)
        if perk and level and level >= 1 and level <= 10 then
            local guard = 0
            while player:getPerkLevel(t) < level and guard < 10 do
                player:LevelPerk(t)
                guard = guard + 1
            end
            if player:getXp():getXP(t) < perk:getTotalXpForLevel(level) then
                player:getXp():setXPToLevel(t, level)
            end
        end
    end
end

-- Ask the server shortly after the character appears, and once more a bit later.
local ticks = -1
local asked = 0

local function onTick()
    if ticks < 0 then return end
    ticks = ticks + 1
    if (asked == 0 and ticks >= 180) or (asked == 1 and ticks >= 3600) then
        local player = getPlayer()
        if player and not player:isDead() then
            sendClientCommand(player, MOD, "hello", {})
            asked = asked + 1
            if asked >= 2 then ticks = -1 end
        end
    end
end

local function onCreatePlayer()
    ticks = 0
    asked = 0
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnTick.Add(onTick)
