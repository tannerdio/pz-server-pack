-- Keep Skills, server half.
-- Skills a player earns stay with the account. Per account name the server keeps (global
-- ModData "KeepSkills", saved with the world):
--   start  XP the current character was created with (its profession and trait skills)
--   bank   XP earned in all earlier lives, starting skills not included
--   given  how much of the bank this character has already received
--   live   XP earned so far in this life (current - start - given)
-- A new character gets its own starting skills plus the whole bank. When it dies, what it
-- earned moves into the bank. Starting skills of a dead character are never passed on.
-- The server's copy of a character is the one that gets saved and its XP is pushed to the
-- client by the game; the client is only told the levels.
--   know   everything any character of the account has learned or read: recipes, recipe
--          magazines, pages read per book, magazines/comics (with the day read, so the game's
--          re-read cooldown still counts), flyers and maps, watched tape and CD lines.
-- "know" only grows. Every character gets all of it on joining, and the XP multiplier of a
-- skill book read in an earlier life is put back for the level range that book covers.

if not isServer() then return end

local MOD = "KeepSkills"
local VERSION = "1.2.0"
local SEED_FILE = "KeepSkills_seed.txt"
-- A character is looked at once it is this old (game hours), so its starting skills have
-- arrived from the client before they are written down.
local MIN_HOURS = 0.03

local data

local function accounts()
    if not data then
        data = ModData.getOrCreate(MOD)
        data.players = nil -- 1.0.0 layout (best XP ever), replaced
        data.accounts = data.accounts or {}
    end
    return data.accounts
end

local function account(name)
    local all = accounts()
    local rec = all[name]
    if not rec then
        rec = {}
        all[name] = rec
    end
    rec.bank = rec.bank or {}
    rec.given = rec.given or {}
    rec.live = rec.live or {}
    return rec
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

local function num(v) return tonumber(v) or 0 end

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

-- Raise the character to "wanted" total XP in one skill. Returns the level it ends on.
local function raise(player, p, wanted)
    local xp = player:getXp()
    wanted = math.min(wanted, p.perk:getTotalXpForLevel(10))
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
        local room = p.perk:getTotalXpForLevel(level + 1) - xp:getXP(p.type)
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

-- ---------------------------------------------------------------------------------------
-- Recipes, books, magazines, tapes

local LINES_PER_MESSAGE = 250

local function knowledge(rec)
    local k = rec.know
    if not k then
        k = {}
        rec.know = k
    end
    k.recipes = k.recipes or {}
    k.books = k.books or {}
    k.pages = k.pages or {}
    k.lit = k.lit or {}
    k.print = k.print or {}
    k.lines = k.lines or {}
    return k
end

-- Every item script with pages: { type, pages, skill, lvl, max }
local bookList
local function books()
    if bookList then return bookList end
    local list = {}
    local all = getAllItems()
    for i = 0, all:size() - 1 do
        local item = all:get(i)
        pcall(function()
            local pages = item:getNumberOfPages()
            if pages and pages > 0 then
                table.insert(list, {
                    type = item:getFullName(), pages = pages, skill = item:getSkillTrained(),
                    lvl = item:getLevelSkillTrained(), max = item:getMaxLevelTrained(),
                })
            end
        end)
    end
    if #list > 0 then bookList = list end
    return list
end

-- The text id of every line of every tape and CD.
local lineList
local function mediaLines()
    if lineList then return lineList end
    local list = {}
    local media = getZomboidRadio():getRecordedMedia()
    local cats = media:getCategories()
    for c = 0, cats:size() - 1 do
        local all = media:getAllMediaForCategory(cats:get(c))
        for m = 0, all:size() - 1 do
            local one = all:get(m)
            for l = 0, one:getLineCount() - 1 do
                local guid = one:getLine(l):getTextGuid()
                if guid and guid ~= "" then table.insert(list, guid) end
            end
        end
    end
    if #list > 0 then lineList = list end
    return list
end

local function part(what, fn)
    local ok, err = pcall(fn)
    if not ok then print("[KeepSkills] " .. what .. " failed: " .. tostring(err)) end
end

-- Write down what this character knows.
local function learn(player, rec)
    local k = knowledge(rec)
    part("reading recipes", function()
        local list = player:getKnownRecipes()
        for i = 0, list:size() - 1 do k.recipes[tostring(list:get(i))] = true end
        list = player:getAlreadyReadBook()
        for i = 0, list:size() - 1 do k.books[tostring(list:get(i))] = true end
    end)
    part("reading book pages", function()
        for _, b in ipairs(books()) do
            local read = math.min(player:getAlreadyReadPages(b.type), b.pages)
            if read > num(k.pages[b.type]) then k.pages[b.type] = read end
        end
    end)
    part("reading magazines", function()
        local read = player:getReadLiterature()
        for title in pairs(transformIntoKahluaTable(read)) do
            local day = num(read:get(title))
            title = tostring(title)
            if not k.lit[title] or day > num(k.lit[title]) then k.lit[title] = day end
        end
    end)
    part("reading flyers", function()
        local list = ArrayList.new(player:getReadPrintMedia())
        for i = 0, list:size() - 1 do k.print[tostring(list:get(i))] = true end
    end)
    part("reading tapes", function()
        for _, guid in ipairs(mediaLines()) do
            if not k.lines[guid] and player:isKnownMediaLine(guid) then k.lines[guid] = true end
        end
    end)
end

-- Give this character (the server's copy) everything the account knows.
local function teach(player, rec)
    local k = knowledge(rec)
    local got = 0
    part("giving recipes", function()
        local known = player:getKnownRecipes()
        for name in pairs(k.recipes) do
            if not known:contains(name) and player:learnRecipe(name) then got = got + 1 end
        end
        local read = player:getAlreadyReadBook()
        for name in pairs(k.books) do
            if not read:contains(name) then
                read:add(name)
                got = got + 1
            end
        end
    end)
    part("giving book pages", function()
        for name, pages in pairs(k.pages) do
            if player:getAlreadyReadPages(name) < num(pages) then
                player:setAlreadyReadPages(name, num(pages))
                got = got + 1
            end
        end
    end)
    part("giving magazines", function()
        local read = player:getReadLiterature()
        for title, day in pairs(k.lit) do
            if not read:containsKey(title) then
                player:addReadLiterature(title, num(day))
                got = got + 1
            end
        end
    end)
    part("giving flyers", function()
        for id in pairs(k.print) do
            if not player:isPrintMediaRead(id) then
                player:addReadPrintMedia(id)
                got = got + 1
            end
        end
    end)
    part("giving tapes", function()
        for guid in pairs(k.lines) do
            if not player:isKnownMediaLine(guid) then
                player:addKnownMediaLine(guid)
                got = got + 1
            end
        end
    end)
    if got > 0 then
        -- The game's own sync of recipes (1) and recipe magazines (4) to the client.
        part("recipe sync", function() sendSyncPlayerFields(player, 5) end)
        print("[KeepSkills] " .. player:getUsername() .. " got " .. got .. " known things back (recipes, books, tapes)")
    end
end

-- The client keeps its own copy of what is read and watched (it draws the "already read"
-- marks from it) and the game does not send those lists, so send them.
local function sendKnowledge(player, rec)
    local k = knowledge(rec)
    local prints = {}
    for id in pairs(k.print) do table.insert(prints, id) end
    sendServerCommand(player, MOD, "know", { pages = k.pages, lit = k.lit, print = prints })
    local chunk = {}
    for guid in pairs(k.lines) do
        table.insert(chunk, guid)
        if #chunk >= LINES_PER_MESSAGE then
            sendServerCommand(player, MOD, "lines", { lines = chunk })
            chunk = {}
        end
    end
    if #chunk > 0 then sendServerCommand(player, MOD, "lines", { lines = chunk }) end
end

-- A skill book read in an earlier life: put its XP multiplier back while the character is in
-- the levels that book covers (the game keeps one multiplier per skill).
local function boost(player, rec)
    if not SkillBook or not rec.know or not rec.know.pages then return end
    for _, b in ipairs(books()) do
        local read = num(rec.know.pages[b.type])
        local book = read > 0 and b.skill and SkillBook[b.skill]
        if book and book.perk then
            local nextLevel = player:getPerkLevel(book.perk) + 1
            if b.lvl <= nextLevel and nextLevel <= b.max then
                local most = num(book["maxMultiplier" .. math.floor((b.lvl + 1) / 2)])
                local mult = math.floor(math.min(read / b.pages, 1) * 10) * (most / 10)
                if mult > player:getXp():getMultiplier(book.perk) + 0.01 then
                    addXpMultiplier(player, book.perk, mult, b.lvl, b.max)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- XP

-- The life is over: what it earned goes to the bank, the next character seen is a new one.
local function endLife(name, rec, why)
    local text = nil
    for id, earned in pairs(rec.live) do
        earned = num(earned)
        if earned > 0 then
            rec.bank[id] = num(rec.bank[id]) + earned
            text = (text and (text .. ", ") or "") .. id .. " +" .. math.floor(earned)
        end
    end
    rec.live = {}
    rec.given = {}
    rec.start = nil
    rec.hours = nil
    print("[KeepSkills] " .. name .. " life ended (" .. why .. "), banked: " .. (text or "nothing"))
end

-- Returns the levels that were raised, or nil.
local function check(player)
    if not player then return nil end
    local name = player:getUsername()
    if not name or name == "" then return nil end
    local rec = account(name)
    local hours = player:getHoursSurvived()
    local xp = player:getXp()
    if player:isDead() then
        if not rec.diedKnow then
            learn(player, rec)
            rec.diedKnow = true
        end
        -- Note the death and the last XP; the life is closed when the next character shows up.
        if rec.start and not rec.diedAt then
            for _, p in ipairs(perks()) do
                local earned = xp:getXP(p.type) - num(rec.start[p.id]) - num(rec.given[p.id])
                if earned > num(rec.live[p.id]) then rec.live[p.id] = earned end
            end
            rec.diedAt = hours
        end
        return nil
    end
    rec.diedKnow = nil
    if hours < MIN_HOURS or player:isAsleep() then return nil end

    -- A new character: hours survived dropped (they only go up within one life), or a death
    -- was seen and the hours are below what they were then.
    if rec.start and ((rec.hours and hours < rec.hours - 0.5) or (rec.diedAt and hours < rec.diedAt)) then
        endLife(name, rec, "new character")
    end
    rec.diedAt = nil
    rec.hours = hours
    if not rec.start then
        rec.start = {}
        for _, p in ipairs(perks()) do
            local have = xp:getXP(p.type)
            if have > 0 then rec.start[p.id] = have end
        end
        print("[KeepSkills] " .. name .. ": new character noted")
    end

    local raised, text = nil, nil
    for _, p in ipairs(perks()) do
        local id = p.id
        local start, bank, given = num(rec.start[id]), num(rec.bank[id]), num(rec.given[id])
        local have = xp:getXP(p.type)
        local earned = have - start - given
        if earned > num(rec.live[id]) then rec.live[id] = earned end
        local live = num(rec.live[id])
        local before = player:getPerkLevel(p.type)
        local wanted = nil
        if bank > given + 0.5 then
            -- Earlier lives' XP this character has not had yet.
            wanted = start + bank + live
            rec.given[id] = bank
        elseif before < levelFor(p.perk, math.min(start + given + live, p.perk:getTotalXpForLevel(10))) then
            -- A level went missing (the game's Strength/Fitness loss, a rollback).
            wanted = start + given + live
        end
        if wanted and wanted > have + 0.5 then
            local level = raise(player, p, wanted)
            raised = raised or {}
            raised[id] = level
            if level ~= before then
                text = (text and (text .. ", ") or "") .. id .. " " .. before .. " -> " .. level
            end
        end
    end
    if text then print("[KeepSkills] " .. name .. " got skills back: " .. text) end
    part("book multipliers", function() boost(player, rec) end)
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

-- Written down every ten game minutes, when a character dies and when one joins.
local function everyTenMinutes()
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        local name = player and player:getUsername()
        if name and name ~= "" and not player:isDead() then
            part("writing down what " .. name .. " knows", function() learn(player, account(name)) end)
        end
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MOD or command ~= "hello" or not player then return end
    local ok, err = pcall(check, player)
    if not ok then print("[KeepSkills] check failed: " .. tostring(err)) end
    sendLevels(player)
    local name = player:getUsername()
    if not name or name == "" or player:isDead() then return end
    part("knowledge for " .. name, function()
        local rec = account(name)
        learn(player, rec)
        teach(player, rec)
        boost(player, rec)
        sendKnowledge(player, rec)
    end)
end

local function onPlayerDeath(player)
    pcall(check, player)
end

-- Optional one-time seed: Zomboid\Lua\KeepSkills_seed.txt, XP totals, one line each:
--   account name|bank|Aiming=254,Reloading=344     XP earned in earlier lives (replaces the bank)
--   account name|start|Strength=337500,Woodwork=75 what the current character was created with
-- Applied at server start, then the file is blanked.
local function readSeed()
    local reader = getFileReader(SEED_FILE, false)
    if not reader then return end
    local count = 0
    local line = reader:readLine()
    while line do
        local name, kind, list = string.match(line, "^([^#|][^|]*)|(%a+)|(.*)$")
        if name and (kind == "bank" or kind == "start") then
            local rec = account(name)
            local values = {}
            for id, value in string.gmatch(list, "([%w_]+)=([%d%.]+)") do
                values[id] = tonumber(value)
            end
            if kind == "bank" then
                rec.bank = values
            else
                rec.start = values
                rec.given = {}
                rec.live = {}
                rec.hours = nil
            end
            count = count + 1
            print("[KeepSkills] seed applied: " .. name .. " " .. kind)
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
    accounts()
    local ok, err = pcall(readSeed)
    if not ok then print("[KeepSkills] seed failed: " .. tostring(err)) end
    local n = 0
    for _ in pairs(accounts()) do n = n + 1 end
    print("[KeepSkills] " .. VERSION .. " ready, records for " .. n .. " account(s)")
end

Events.OnInitGlobalModData.Add(onInit)
Events.EveryOneMinute.Add(everyMinute)
Events.EveryTenMinutes.Add(everyTenMinutes)
Events.OnClientCommand.Add(onClientCommand)
Events.OnPlayerDeath.Add(onPlayerDeath)
