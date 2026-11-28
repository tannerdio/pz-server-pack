--[[
Harsh Winter 1.1.0 (solo, and server + clients in multiplayer).

1. Cold. When the game sets up its seasons, the coldest-day temperature is lowered to TEMP_MIN (vanilla Kentucky
   is 0 C). Summer is not touched. This runs on the server and on every client, so everyone has the same season
   dates. A colder winter is also a longer one: the game starts winter 40 + 2 x (degrees below zero) days before
   22 December. A lower `season.tempMin` in the save's erosion.ini still wins.

2. Snowfall. While the season is winter, the Rain sandbox option is held at Very Rainy: the game reads it live,
   so weather fronts arrive about 40% more often and last 50% longer. Below freezing all of that falls as snow.
   When winter ends the option goes back to what it was. The weather is made by the server, so this part does
   nothing on a multiplayer client.

Removing this mod in mid-winter can leave Rain at Very Rainy in a solo save: set it back by hand (3 = Normal).
]]
local TEMP_MIN = -15    -- C, mean of the coldest day. 0 = vanilla, -20 = the Winter is Coming challenge.
local WINTER = 5        -- ErosionSeason season id
local VERY_RAINY = 5    -- Rain option: 1 Very Dry .. 3 Normal .. 5 Very Rainy

local function onInitSeasons(season)
    local ok, err = pcall(function()
        local was = season:getTempMin()
        if was <= TEMP_MIN then return end
        season:init(season:getLat(), season:getTempMax(), TEMP_MIN, season:getTempDiff(), season:getSeasonLag(),
            season:getHighNoon(), season:getSeedA(), season:getSeedB(), season:getSeedC())
        print("[HarshWinter] coldest-day temperature " .. tostring(was) .. " -> " .. TEMP_MIN .. " C")
    end)
    if not ok then print("[HarshWinter] season error: " .. tostring(err)) end
end

local function applyRain()
    if isClient() then return end
    local ok, err = pcall(function()
        local options = getSandboxOptions()
        local rain = options and options:getOptionByName("Rain")
        local climate = getClimateManager()
        local season = climate and climate:getSeason()
        if not rain or not season then return end

        local data = ModData.getOrCreate("HarshWinter")
        local now = rain:getValue()

        if season:getSeason() == WINTER then
            if data.baseRain == nil then data.baseRain = now end
            if now ~= VERY_RAINY then
                rain:setValue(VERY_RAINY)
                options:toLua()
                print("[HarshWinter] winter: Rain " .. tostring(now) .. " -> " .. VERY_RAINY)
            end
        elseif data.baseRain ~= nil then
            if now ~= data.baseRain then
                rain:setValue(data.baseRain)
                options:toLua()
                print("[HarshWinter] winter over: Rain back to " .. tostring(data.baseRain))
            end
            data.baseRain = nil
        end
    end)
    if not ok then print("[HarshWinter] rain error: " .. tostring(err)) end
end

Events.OnInitSeasons.Add(onInitSeasons)
Events.OnGameStart.Add(applyRain)
Events.EveryHours.Add(applyRain)
