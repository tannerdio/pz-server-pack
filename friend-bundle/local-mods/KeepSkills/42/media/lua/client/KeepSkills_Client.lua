-- Keep Skills, client half.
-- The server owns the skill records and the XP. It tells this client which levels the
-- character should have; this side only raises its own levels to match (never lowers).
-- It also sends what the account has read and watched in earlier lives (book pages,
-- magazines, flyers, tape lines), which this side copies onto its own character so the
-- "already read" marks are right. Recipes arrive through the game's own sync.

if not isClient() then return end

local MOD = "KeepSkills"

local function num(v) return tonumber(v) or 0 end

local function know(player, args)
    for name, pages in pairs(args.pages or {}) do
        if player:getAlreadyReadPages(name) < num(pages) then
            player:setAlreadyReadPages(name, num(pages))
        end
    end
    local read = player:getReadLiterature()
    for title, day in pairs(args.lit or {}) do
        if not read:containsKey(title) then player:addReadLiterature(title, num(day)) end
    end
    for _, id in pairs(args.print or {}) do
        player:addReadPrintMedia(id)
    end
    for _, guid in pairs(args.lines or {}) do
        player:addKnownMediaLine(guid)
    end
end

local function onServerCommand(module, command, args)
    if module ~= MOD or not args then return end
    local player = getPlayer()
    if not player or player:isDead() then return end
    if command == "know" or command == "lines" then
        local ok, err = pcall(know, player, args)
        if not ok then print("[KeepSkills] know failed: " .. tostring(err)) end
        return
    end
    if command ~= "apply" or not args.levels then return end
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
