-- Stabilized GoPro cam: while the game's first-person head cam (the "GoPro" view) is on, the picture keeps the head's
-- position but gets a steady orientation instead of the head's shake: where the head looks (resteep.camera.game(), the
-- game's camera under the effect), smoothed (a time constant), the horizon locked level or its roll limited, through a
-- GoPro-like lens; or where the rider goes (the "travel" source). F3 (a setting) switches it
-- on and off. The head cam is told apart by where the game's camera is (resteep.camera.game()): right above the rider
-- (horizontally within `detect` plus a little for speed, 0.5 to 2.5 m above its feet); the third-person camera sits
-- metres behind, also at speed (a radius that grew with speed took it for the head cam at 30 m/s: harness 2026-11-13). In a crash, a menu, the pause camera or the third-person view the game's
-- camera is left alone (released with a short blend); a jump of the camera (respawn, travel) starts over from it.
-- The travel source follows the rider's velocity (the right stick looks around; standing still it holds its heading).
-- An overlay without resteep.camera.game() (older than 2026-11-13) can't read the head under the effect: then the head
-- source falls back to the travel one.
-- The position stays the game's: reading it back is how the head cam is told apart.
local BLEND_IN, BLEND_OUT = 0.3, 0.3
local ENGAGE_S, LOST_S = 0.25, 0.1                 -- the head cam seen this long before taking over / gone before letting go
local SNAP_DEG = 120                               -- the target turned more than this in one frame: a cut, no smoothing
local JUMP_M = 6                                   -- the camera moved this much more than the rider's speed explains
local MIN_SPEED, FULL_SPEED = 1.0, 4.0             -- m/s: the travel heading counts from MIN, fully from FULL
local PITCH_MIN, PITCH_MAX = -50, 30               -- degrees: how far the travel direction tips the view
local LOOK_YAW, LOOK_PITCH, LOOK_TAU, DEADZONE = 90, 40, 0.12, 0.15   -- the right stick looks around (travel)
local LEAN = 0.5                                   -- of the lean angle a turn asks for (horizon "limit", travel)
local G = 9.81
local LENS = {narrow = 73, linear = 87, wide = 118, superview = 122}   -- GoPro's horizontal degrees at 16:9

local function setting(key, default)
    local ok, v = pcall(resteep.config.get, key)
    if not ok or v == nil then return default end
    return v
end

-- vectors: {x, y, z}, Z up
local function v3(x, y, z) return {x = x, y = y, z = z} end
local Z = v3(0, 0, 1)
local function add(a, b, s) s = s or 1 return v3(a.x + b.x * s, a.y + b.y * s, a.z + b.z * s) end
local function mul(a, s) return v3(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) local l = len(a) return l > 1e-9 and mul(a, 1 / l) or v3(1, 0, 0) end
local function rotate(v, axis, ang)                -- about a unit axis, right-handed (Rodrigues)
    local c, s = math.cos(ang), math.sin(ang)
    return add(add(mul(v, c), cross(axis, v), s), axis, dot(axis, v) * (1 - c))
end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function angle(a, b) return math.acos(clamp(dot(a, b), -1, 1)) end
local function direction(heading, pitch)          -- radians: heading from +X towards +Y, pitch up
    return v3(math.cos(pitch) * math.cos(heading), math.cos(pitch) * math.sin(heading), math.sin(pitch))
end

-- the level frame of a direction: its right and its up without roll (straight up or down: the last right it had)
local last_right = v3(0, -1, 0)
local function level(f)
    local r = cross(f, Z)
    if len(r) < 0.2 then r = add(last_right, f, -dot(last_right, f)) end
    r = unit(r)
    last_right = r
    return r, cross(r, f)
end
local function roll_of(f, u)                       -- radians, positive: the camera leans left
    local r, l = level(f)
    return math.atan(-dot(u, r), dot(u, l))
end
local function up_of(f, roll)
    local r, l = level(f)
    return unit(add(mul(l, math.cos(roll)), r, -math.sin(roll)))
end
local function turn_toward(a, b, frac)             -- a part of the way along the great circle: no gimbal, no wrap
    local ang = angle(a, b)
    if ang < 1e-6 then return b end
    local ax = cross(a, b)
    if len(ax) < 1e-6 then ax = cross(a, math.abs(a.z) < 0.9 and Z or v3(1, 0, 0)) end   -- opposite: any side
    return unit(rotate(a, unit(ax), ang * frac))
end

local on, last_enabled = nil, nil                  -- the switch: the key flips it, a changed setting sets it
local state = "idle"                               -- idle: the game's camera; on: ours
local seen, lost, wait_until = 0, 0, 0
local s = {}                                       -- f (forward), roll, heading, yaw_rate, look_yaw/pitch, last, target, snap
local warned_head = false

local function release(blend)
    if state == "on" then resteep.camera.release(blend) end
    state, seen, lost = "idle", 0, 0
    wait_until = resteep.time() + blend + 0.1      -- the camera reads back ours for a moment after
end

local function head_source()
    if setting("source", "head") ~= "head" then return false end
    if type(resteep.camera.game) == "function" then return true end
    if not warned_head then
        warned_head = true
        resteep.notify("GoPro: this ReSteep cannot read the head under the effect (update it): following the travel direction", 5)
    end
    return false
end

local function engage(c)                           -- from the game's head cam as it is now (not ours yet)
    s.f = unit(c.forward)
    s.roll = roll_of(s.f, c.up or Z)
    s.heading, s.yaw_rate = math.atan(s.f.y, s.f.x), 0
    s.look_yaw, s.look_pitch = 0, 0
    s.last, s.target, s.snap = v3(c.x, c.y, c.z), nil, false
    state, lost = "on", 0
end

local function max_roll() return math.rad(setting("max_roll", 10)) end

-- where the view should look (forward) and its roll: the rider's travel, or the head's own camera
local function target(p, head)
    local horizon_lock = setting("horizon", "lock") == "lock"
    if head then
        local ok, g = pcall(resteep.camera.game)
        if not ok or not g or not g.forward then return s.f, s.roll end
        local tf = unit(g.forward)
        local roll = horizon_lock and 0 or clamp(roll_of(tf, g.up or Z), -max_roll(), max_roll())
        return tf, roll
    end
    local v = p.velocity or v3(0, 0, 0)
    local hs = math.sqrt(v.x * v.x + v.y * v.y)
    local w = clamp((hs - MIN_SPEED) / (FULL_SPEED - MIN_SPEED), 0, 1)
    local heading = s.heading
    if w > 0 then heading = heading + wrap(math.atan(v.y, v.x) - heading) * w end
    local pitch = clamp(math.deg(math.atan(v.z, math.max(hs, 1e-3))), PITCH_MIN, PITCH_MAX) * w + setting("tilt", -5)
    local roll = 0
    if not horizon_lock then                       -- lean into the turn: the angle a rider would lean, part of it
        roll = clamp(LEAN * math.atan(s.yaw_rate * hs / G), -max_roll(), max_roll())
    end
    return direction(heading, math.rad(pitch)), roll
end

local function deadzone(x)
    if not x or math.abs(x) <= DEADZONE then return 0 end
    return (x - DEADZONE * (x < 0 and -1 or 1)) / (1 - DEADZONE)
end

local function fov(c)                              -- vertical degrees, nil: the game's own
    local lens = setting("lens", "wide")
    if lens == "game" then return nil end
    if lens == "custom" then return clamp(setting("fov", 75), 5, 150) end
    local h = math.rad(LENS[lens] or LENS.wide)
    local aspect = (c.aspect and c.aspect > 0.2) and c.aspect or 16 / 9
    return clamp(math.deg(2 * math.atan(math.tan(h / 2) / aspect)), 5, 150)
end

local function step(dt, p, c)
    local head = head_source()
    local tf, troll = target(p, head)
    local a = dt > 0 and 1 - math.exp(-dt / math.max(setting("smoothing", 0.4), 0.01)) or 0
    if s.snap or (s.target and angle(s.target, tf) > math.rad(SNAP_DEG)) then
        s.f, s.roll, s.snap = tf, troll, false
    else
        s.f = turn_toward(s.f, tf, a)
        s.roll = s.roll + wrap(troll - s.roll) * a
    end
    s.target = tf
    local h = math.atan(s.f.y, s.f.x)
    if dt > 0 then s.yaw_rate = s.yaw_rate + (wrap(h - s.heading) / dt - s.yaw_rate) * a end
    s.heading = h

    local f, u = s.f, up_of(s.f, s.roll)
    if not head then                               -- the right stick looks around, back to the front when let go
        local ok, pad = pcall(resteep.input.read)
        pad = ok and pad or nil
        local k = dt > 0 and 1 - math.exp(-dt / LOOK_TAU) or 0
        s.look_yaw = s.look_yaw + (-deadzone(pad and pad.rx) * LOOK_YAW - s.look_yaw) * k
        s.look_pitch = s.look_pitch + (deadzone(pad and pad.ry) * LOOK_PITCH - s.look_pitch) * k
        if math.abs(s.look_yaw) > 0.01 or math.abs(s.look_pitch) > 0.01 then
            f, u = rotate(f, Z, math.rad(s.look_yaw)), rotate(u, Z, math.rad(s.look_yaw))
            local r = unit(cross(f, u))
            f, u = rotate(f, r, math.rad(s.look_pitch)), rotate(u, r, math.rad(s.look_pitch))
        end
    end
    -- no x, y, z: the position stays the game's head, so resteep.camera() keeps telling the head cam apart
    resteep.camera.set{forward = f, up = u, fov = fov(c), duration = BLEND_IN}
end

resteep.on("frame", function(dt)
    local enabled = setting("enabled", true)
    if enabled ~= last_enabled then on, last_enabled = enabled, enabled end
    local p, c = resteep.player(), resteep.camera()
    local g = c
    if type(resteep.camera.game) == "function" then          -- the game's own camera, under our effect
        local ok, got = pcall(resteep.camera.game)
        if ok and got then g = got end
    end
    local flat, above
    if p and g and g.x then
        flat, above = math.sqrt((g.x - p.x) ^ 2 + (g.y - p.y) ^ 2), g.z - p.z
    end
    local speed = p and p.speed or 0
    local headcam = flat ~= nil and not p.ragdoll and flat < setting("detect", 0.8) + speed * 0.02
        and above > 0.5 and above < 2.5
    if setting("show_info", false) then
        resteep.text(0.5, 0.05, string.format("GoPro %s: the camera %s", on and state or "switched off",
            flat and string.format("%.2f m beside the rider, %.2f m above its feet", flat, above) or "?"),
            "#FFFFFF", 0.8)
    end
    if state == "on" then
        lost = headcam and 0 or lost + dt
        if not on or not p or p.ragdoll or not c or lost >= LOST_S then release(BLEND_OUT) return end
        local here = v3(c.x, c.y, c.z)
        if len(add(here, s.last, -1)) > JUMP_M + speed * dt * 2 then   -- respawn, travel: not a move to smooth
            if not head_source() then release(0) return end
            s.snap = true
        end
        s.last = here
        step(dt, p, c)
    elseif on and headcam and c.forward and resteep.time() >= wait_until then
        seen = seen + dt
        if seen >= ENGAGE_S then
            engage(c)
            step(dt, p, c)
        end
    else
        seen = 0
    end
end)

resteep.on("key", function(name)
    if name ~= setting("toggle_key", "F3") then return end
    on = not on
    if not on then release(BLEND_OUT) end
    resteep.notify(on and "GoPro stabilizer on" or "GoPro stabilizer off", 2)
end)

resteep.on("crash", function() release(BLEND_OUT) end)
resteep.on("player_lost", function() release(0) end)
resteep.on("world_leave", function() release(0) end)
resteep.log("GoPro stabilizer: steadies the first-person head cam; " .. tostring(setting("toggle_key", "F3"))
            .. " switches it on and off")
