-- Keep Skills, server half.
-- The server keeps, per account name, the highest XP that account has ever had in each skill
-- (global ModData "KeepSkills", saved with the world). Every game minute each living player is
-- compared with their record: higher XP raises the record, a character below the record (a new
-- one after a death) is raised to it. The server's copy of a character is the one that gets
-- saved and its XP is pushed to the client by the game; the client is only told the levels.

if not isServer() then return end

local MOD = "KeepSkills"
local SEED_FILE = "KeepSkills_seed.txt"
-- Below this many hours survived a character counts as new and also gets back the XP inside
-- a level. Older characters are only topped up when a whole level is missing, so the game's
-- slow Strength/Fitness loss is not fought every minute.
local NEW_CHARACTER_HOURS = 1

local data

local function records()
    if not data then
        data = ModData.getOrCreate(MOD)
        data.players = data.players or {}
    end
    return data.players
end

-- { { id = "Woodwork", type = Perks.Woodwork, perk = <PerkFactory.Perk> }, ... }
local perkList
local function perks()
    if perkList then return perkList end
    perkList = {}
    for i = 0, Perks.getMaxIndex() - 1 do
        local t = Perks.fromIndex(i)
        local perk = t and PerkFactory.getPerk(t)
        if perk and perk:getParent() ~= Perks.None then
            table.insert(perkList, { id = tostring(perk:getType()), type = t, perk = perk })
        end
    end
    return perkList
end

local function levelFor(perk, xp)
    for level = 10, 1, -1 do
        if xp >= perk:getTotalXpForLevel(level) then return level end
    end
    return 0
end

-- Strength XP is scaled by protein inside AddXP even with multipliers off; undo that.
local function strengthFactor(player)
    local ok, proteins = pcall(function() return player:getNutrition():getProteins() end)
    if not ok or not proteins then return 1 end
    if proteins > 50 and proteins < 300 then return 1.5 end
    if proteins < -300 then return 0.7 end
    return 1
end

local function restore(player, p, wanted)
    local xp = player:getXp()
    local level = levelFor(p.perk, wanted)
    local guard = 0
    while player:getPerkLevel(p.type) < level and guard < 10 do
        player:LevelPerk(p.type)
        guard = guard + 1
    end
    if xp:getXP(p.type) < p.perk:getTotalXpForLevel(level) then
        xp:setXPToLevel(p.type, level)
    end
    -- XP inside the level. Never enough to level up by itself.
    local rest = wanted - xp:getXP(p.type)
    if level < 10 and rest > 0.5 then
        local room = p.perk:getTotalXpForLevel(level + 1) - p.perk:getTotalXpForLevel(level)
        rest = math.min(rest, room - 1)
        if p.type == Perks.Strength then rest = rest / strengthFactor(player) end
        if rest > 0.5 then
            pcall(function() xp:AddXP(p.type, rest, false, false, false, false) end)
        end
    end
    return level
end

local function sendLevels(player, levels)
    if not levels then
        levels = {}
        for _, p in ipairs(perks()) do
            local level = player:getPerkLevel(p.type)
            if level > 0 then levels[p.id] = level end
        end
    end
    sendServerCommand(player, MOD, "apply", { levels = levels })
end

-- Returns the levels that were raised, or nil.
local function check(player)
    if not player or player:isDead() or player:isAsleep() then return nil end
    local name = player:getUsername()
    if not name or name == "" then return nil end
    local all = records()
    local rec = all[name]
    if not rec then
        rec = {}
        all[name] = rec
    end
    local xp = player:getXp()
    local fresh = player:getHoursSurvived() < NEW_CHARACTER_HOURS
    local raised, text = nil, nil
    for _, p in ipairs(perks()) do
        local have = xp:getXP(p.type)
        local best = tonumber(rec[p.id]) or 0
        if have > best then
            rec[p.id] = have
        elseif best > have + 0.5 then
            local before = player:getPerkLevel(p.type)
            if before < levelFor(p.perk, best) or fresh then
                local level = restore(player, p, best)
                raised = raised or {}
                raised[p.id] = level
                if level ~= before then
                    text = (text and (text .. ", ") or "") .. p.id .. " " .. before .. " -> " .. level
                end
                -- Whatever could not be given back inside the level (Fitness blocked by
                -- weight, for one) is dropped from the record so it is not retried forever.
                local now = xp:getXP(p.type)
                if fresh and now < best and levelFor(p.perk, now) >= levelFor(p.perk, best) then
                    rec[p.id] = now
                end
            end
        end
    end
    if text then print("[KeepSkills] " .. name .. " got skills back: " .. text) end
    return raised
end

local function everyMinute()
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        local ok, raised = pcall(check, player)
        if not ok then
            print("[KeepSkills] check failed: " .. tostring(raised))
        elseif raised then
            sendLevels(player, raised)
        end
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MOD or command ~= "hello" or not player then return end
    local ok, err = pcall(check, player)
    if not ok then print("[KeepSkills] check failed: " .. tostring(err)) end
    sendLevels(player)
end

-- Optional one-time seed: Zomboid\Lua\KeepSkills_seed.txt, one line per account:
--   account name|Woodwork=1350,Strength=340527
-- (XP totals). Merged into the records, never lowering one, then the file is blanked.
local function readSeed()
    local reader = getFileReader(SEED_FILE, false)
    if not reader then return end
    local all = records()
    local count = 0
    local line = reader:readLine()
    while line do
        local name, list = string.match(line, "^([^#|][^|]*)|(.*)$")
        if name and list then
            local rec = all[name]
            if not rec then
                rec = {}
                all[name] = rec
            end
            for id, value in string.gmatch(list, "([%w_]+)=([%d%.]+)") do
                local xp = tonumber(value)
                if xp and xp > (tonumber(rec[id]) or 0) then rec[id] = xp end
            end
            count = count + 1
            print("[KeepSkills] seed applied for " .. name)
        end
        line = reader:readLine()
    end
    reader:close()
    if count > 0 then
        local writer = getFileWriter(SEED_FILE, true, false)
        if writer then
            writer:write("# applied, nothing left to do\r\n")
            writer:close()
        end
    end
end

local function onInit()
    data = nil
    records()
    local ok, err = pcall(readSeed)
    if not ok then print("[KeepSkills] seed failed: " .. tostring(err)) end
    local n = 0
    for _ in pairs(records()) do n = n + 1 end
    print("[KeepSkills] 1.0.0 ready, records for " .. n .. " account(s)")
end

Events.OnInitGlobalModData.Add(onInit)
Events.EveryOneMinute.Add(everyMinute)
Events.OnClientCommand.Add(onClientCommand)
