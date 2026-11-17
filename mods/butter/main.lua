-- Butter: nose and tail butters on the snow. Hold RB while riding and push the left stick forward (onto the nose) or
-- back (onto the tail); the further the stick, the more the board tips up and the rider's weight goes over that end.
-- Letting go of RB ends the butter. Steering (left stick X) stays as it is; nothing goes to the game's right stick.
--
-- How: the game's input file inputsettings_surfboard (skis and snowboard, tools/forge/HANDLING.md "The input file")
-- maps each stick axis onto four channels per speed band (normalSettings below 7 m/s, fastSettings above 12 m/s):
-- attitude (the board's orientation target: vertical = pitch, 45 degrees from the right stick), buttering (the right
-- stick's pivot butters: what turned the rider sideways), steering and weightShift (vertical = the rider's weight
-- along the board, riderSettings.legSettings bowward/sternward offsets; the left stick's at speed: the tuck). While
-- the button is held this mod has the game parse a copy (resteep.handling.set) in which the left stick's Y feeds
-- the pitch and the weight shift instead of its steering, and puts the shipped file back when it is let go. The pad
-- (resteep.input.pad) carries the left stick's Y scaled into 0..REACH, below the quick stop's threshold (0.5: stick
-- back would brake), with the remap curves ending at REACH; RB is taken out of it. Each curve keeps its sample count.
-- A press while standing still or walking stays the game's (RB: the sport wheel). In the air the left stick's Y is
-- kept from the game (no flip), and after letting go in the air until it is back in the middle.
local FILE = "inputsettings_surfboard"
local REACH = 0.45            -- the stick the game gets at full lean: under bindingSettings.quickStop's 0.5
local BANDS = {"normalSettings", "fastSettings"}
local HANDOVER = 0.3          -- s of the real pad sent after the butter: the mod's pad lasts 250 ms

local function setting(key, default)
    local ok, v = pcall(resteep.config.get, key)
    if not ok or v == nil then return default end
    return v
end

local function debug(fmt, ...)
    if setting("debug", false) then resteep.log(string.format(fmt, ...)) end
end

local owned = false           -- the button press is the mod's (pressed while riding), until it is let go
local was_held = false
local leaning = false         -- the game holds the butter copy of the input file now
local mute_ly = false         -- after the butter in the air: left stick Y kept from the game until centred
local handover_until = -1
local shipped = nil           -- the game's input table, read once
local failed = false          -- the file could not be changed: said once per press

local function has(list, name)
    for _, b in ipairs(list or {}) do if b == name then return true end end
    return false
end

local function without(list, name)
    local out = {}
    for _, b in ipairs(list or {}) do if b ~= name then out[#out + 1] = b end end
    return out
end

local function copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = copy(v) end
    return c
end

-- the stick's forward (+) / back (-) as the lean asked for, -1..1
local function shape(y)
    local dz = setting("deadzone", 0.15)
    local a = math.abs(y)
    if a <= dz then return 0 end
    local t = math.min(((a - dz) / math.max(1 - dz, 0.01)) ^ setting("response", 1.0), 1)
    if y < 0 then t = -t end
    if setting("invert", false) then t = -t end
    return t
end

-- a two-sample remap curve reaching `top` at REACH: the shipped ones have two samples, so the game's arrays keep
-- their size (no reallocation while the physics may read them)
local function remap(curve, top)
    local c = copy(curve)
    c[1], c[2] = 0, top
    c.domain = {0, REACH}
    return c
end

-- the butter copy of the game's input table: left stick Y -> pitch + weight shift, out of steering
local function butter_table()
    if not shipped then
        local why
        shipped, why = resteep.handling.get(FILE)
        if not shipped then return nil, why end
    end
    local t = copy(shipped)
    local pitch, weight = math.rad(setting("board_tilt", 45)), math.rad(setting("body_lean", 45))
    for _, band in ipairs(BANDS) do
        local b = t[band]
        local ok = b and b.attitude and b.weightShift and b.steering
        if not ok then return nil, "the input file has no " .. band .. " channels" end
        for _, ch in ipairs({b.attitude.vertical, b.weightShift.vertical, b.steering.vertical}) do
            if type(ch) ~= "table" or type(ch.leftAxisRemap) ~= "table" or #ch.leftAxisRemap ~= 2 then
                return nil, "the input file's " .. band .. " is not the one this mod knows"
            end
        end
        b.attitude.vertical.leftAxisRemap = remap(b.attitude.vertical.leftAxisRemap, pitch)
        b.weightShift.vertical.leftAxisRemap = remap(b.weightShift.vertical.leftAxisRemap, weight)
        b.steering.vertical.leftAxisRemap = remap(b.steering.vertical.leftAxisRemap, 0)
    end
    return t
end

local function set_leaning(on, why)
    if on == leaning or (on and failed) then return end
    if on then
        local t, err = butter_table()
        local ok = t ~= nil
        if t then ok, err = resteep.handling.set(FILE, t) end
        if not ok then
            if not failed then resteep.log("butter: the lean is off: " .. tostring(err)) end
            failed = true
            return
        end
    else
        resteep.handling.reset(FILE)
    end
    leaning = on
    debug("butter %s (%s)", on and "on" or "off", why)
end

-- on the board or the skis now: the game's activity (0 snowboard, 2 ski) where it is known, so walking (6) and the
-- rest keep RB (sport wheel and the like) although the sport still says ski or snowboard
local function riding(p)
    if not p or p.ragdoll then return false end
    if p.activity ~= nil and p.activity ~= 0 and p.activity ~= 2 then return false end
    return p.sport == "snowboard" or (p.sport == "ski" and setting("ski", true))
end

resteep.on("frame", function()
    local now = resteep.time()
    local real = resteep.input.read()
    if not real then
        owned, was_held, mute_ly = false, false, false
        set_leaning(false, "no pad")
        return
    end
    local button = setting("button", "RB")
    local held = has(real.buttons, button)
    local p = resteep.player()
    if held and not was_held then
        owned = riding(p) and (p.air or p.speed >= setting("min_speed", 1.0))
        failed = false
        -- every press says why (a press is rare): "it brakes like normal" is then one look at the log
        resteep.log(string.format("%s %s (%s, activity %s, %.1f m/s%s), left stick y %.2f", button,
            owned and "pressed: buttering" or "pressed: left to the game", p and tostring(p.sport) or "no rider",
            p and tostring(p.activity) or "-", p and p.speed or 0, p and p.air and ", in the air" or "", real.ly))
    elseif not held and owned then
        owned = false
        mute_ly = p ~= nil and p.air            -- let go in the air: a pushed stick would flip the rider
    end
    was_held = held

    local air = p ~= nil and p.air
    -- the copy stays while the button is the mod's, in the air too: two parses per butter, not one per bump
    set_leaning(owned and riding(p), not owned and "button" or "not riding")
    if mute_ly and (math.abs(real.ly) < setting("deadzone", 0.15) or not air) then mute_ly = false end
    if setting("debug", false) then                 -- which clips the game picks, leaning or not
        for _, clip in ipairs(resteep.rider.anim_seen() or {}) do
            debug("clip %s%s", clip, leaning and " (butter)" or "")
        end
    end

    if not (owned or mute_ly or now < handover_until) then return end
    local pad = {lx = real.lx, ly = real.ly, rx = real.rx, ry = real.ry, lt = real.lt, rt = real.rt,
                 buttons = owned and without(real.buttons, button) or real.buttons}
    if mute_ly then
        pad.ly = 0
    elseif leaning then                             -- (a lean the game refused: the stick stays the game's)
        local lean = air and 0 or shape(real.ly)    -- in the air: no flip from a held lean
        pad.ly = lean * REACH
        if setting("debug", false) then
            resteep.text(0.5, 0.86, string.format("BUTTER %s %3.0f%%", lean >= 0 and "NOSE" or "TAIL",
                math.abs(lean) * 100), "#FFFFE08A")
        end
    end
    if owned or mute_ly then handover_until = now + HANDOVER end
    resteep.input.pad(pad)
end)

resteep.on("config_change", function()
    if leaning then leaning = false; set_leaning(true, "settings") end   -- the new tilt at once
end)
resteep.on("player_lost", function() set_leaning(false, "player lost") end)
resteep.on("world_leave", function() set_leaning(false, "world left") end)

resteep.log("butter ready: hold " .. setting("button", "RB") .. " and push the left stick forward / back")
