-- Physics playground: change the ski and snowboard physics while you ride (resteep.handling, tools/forge/HANDLING.md).
--   F5  jump strength: x1 -> x2 -> x4 -> x8 (baseImpulseFactor, 80 as shipped)
--   F6  air: normal -> floaty (falls slowly) -> heavy (drops like a stone)
--   F9  ground: normal -> fast (less drag) -> slow
-- (No mass key: riderSettings.mass 20 -> 60 while riding hung the game, a worker thread at 100% CPU, 2026-11-13.)
--   F11 everything as shipped
-- Each change is parsed by the game into what the riding reads (game thread). Whether every value takes effect live or
-- only after a respawn (or a change of sport) is what this playground finds out: if something seems to do nothing,
-- switch sport and back. Switching the mod off puts the shipped physics back.
local FILE = "settings_surfboard"                  -- skis and snowboard (sled, speed riding: their own files)
local shipped = nil                                 -- the game's table, read once

local steps = {
    jump = {1, 2, 4, 8},
    air = {{"normal", 0.3}, {"floaty", 4.0}, {"heavy", 0.0}},
    ground = {{"normal", 1.0}, {"fast", 0.2}, {"slow", 4.0}},
}
local at = {jump = 1, air = 1, ground = 1}

local function copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = copy(v) end
    return c
end

local function apply(what)
    if not shipped then
        local why
        shipped, why = resteep.handling.get(FILE)
        if not shipped then resteep.notify("physics: " .. tostring(why), 4) return end
    end
    local t = copy(shipped)
    local rider = t.riderSettings
    rider.legSettings.jumpSettings.baseImpulseFactor = shipped.riderSettings.legSettings.jumpSettings.baseImpulseFactor
        * steps.jump[at.jump]
    t.dampingSettings.riderVerticalLinearDampingFactor = steps.air[at.air][2]
    t.dampingSettings.riderHorizontalLinearDampingFactor = steps.ground[at.ground][2]
    local ok, why = resteep.handling.set(FILE, t)
    if ok then
        resteep.notify(string.format("physics: %s | jump x%d, air %s, ground %s", what, steps.jump[at.jump],
            steps.air[at.air][1], steps.ground[at.ground][1]), 4)
    else
        resteep.notify("physics: not set: " .. tostring(why), 4)
    end
end

local function next_of(name) at[name] = at[name] % #steps[name] + 1 end

resteep.on("key", function(key)
    if key == "F5" then next_of("jump") apply("jump")
    elseif key == "F6" then next_of("air") apply("air")
    elseif key == "F9" then next_of("ground") apply("ground")
    elseif key == "F11" then
        at = {jump = 1, air = 1, ground = 1}
        local ok, why = resteep.handling.reset(FILE)
        resteep.notify(ok and "physics: as shipped" or ("physics: " .. tostring(why)), 3)
    end
end)

resteep.on("takeoff", function() resteep.log("takeoff") end)
resteep.on("landing", function(airtime) resteep.log(string.format("landing after %.2f s in the air", airtime)) end)
resteep.log("physics playground: F5 jump, F6 air, F9 ground, F11 reset")
