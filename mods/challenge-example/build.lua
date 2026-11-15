-- A race declared in Lua: the launcher runs this while it builds the mods (no game running, no file access) and
-- turns every resteep.challenge{...} into a challenge of the game (docs/modding/challenges.md).
-- The course runs down the slope of Dexterity Drift (Alps), every other gate of it, so it is surely rideable.

local gates = {
    {-736.2, -6051.7, 1401.2},
    {-858.4, -6092.0, 1345.4},
    {-938.1, -6189.9, 1271.8},
    {-1003.0, -6299.8, 1196.6},
    {-1080.4, -6399.1, 1111.8},
}
local finish = {-1106.5, -6458.5, 1073.8}

local elements = {}
for _, g in ipairs(gates) do
    elements[#elements + 1] = {type = "checkpoint", at = g, range = 10}
end
elements[#elements + 1] = {type = "finish", at = finish, range = 12}

local gold = resteep.config.get("gold") or 45
resteep.challenge{
    key = "short_downhill",
    kind = "race",
    map = "Alpes",
    title = {en = "ReSteep: Short Downhill", de = "ReSteep: Kurze Abfahrt"},
    rules = {en = "Pass every gate on the way down.", de = "Fahr durch alle Tore bis ins Ziel."},
    start = {-617.6, -6126.4, 1456.0},
    elements = elements,
    medals = {gold, gold * 1.3, gold * 1.7},   -- seconds: gold, silver, bronze
    time_of_day = 12,
    music = "theme",                           -- content.music's track (resteep.json), played while racing
}
resteep.log(("short_downhill: %d gates, gold in %d s"):format(#gates, gold))
