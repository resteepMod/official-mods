-- Helicopter mode (docs/todo/10-helicopter.md, route A). F8 (or the pad's BACK) starts and ends it. The mod holds the
-- rider (resteep.rider.hold: the trainer's Fly + noclip, so the game's physics and collision leave it alone) and
-- moves it every frame with resteep.rider.set_position, from a flight model in Lua; the game's own helicopter
-- (STP_Helico, the Alps' intro helicopter, moved with resteep.prop) flies with the rider in its open side door; a
-- chase camera follows. Two flight models (the setting "realistic"):
-- - arcade (default): the disc tilts with the stick and springs back, the heading turns with the pedals, released
--   collective holds the height; it never tips over;
-- - realistic: a light single-engine helicopter (the AS350 / H125 class the model is) as a rigid body (orientation as
--   three axis vectors, no angles: no gimbal lock). The collective is a lever that stays where it is set; the rotor's
--   thrust (never below 0) acts along the body's up axis and thins out with height; a power limit, translational lift,
--   vortex ring state, the main rotor's torque against the pedals and the tail fin at speed, retreating blade stall
--   near VNE, low g (a warning and a roll, no crash). Momentum and rotational inertia: at speed little drag slows it
--   and the fin keeps the nose in the wind, so slowing down or turning tightly means tilting the rotor's thrust (a
--   flare and a bank: a J-hook); the stick builds up turn rates that go on until countered. It cannot hover upside
--   down; rolls and loops need timing.
-- F8 / B lets go: the game takes the rider back (it falls from there). Left in the air, the helicopter's pilot (the
-- model has one) holds a hover there with the rotors running; left on the ground it is parked and the rotors stop.
-- It collides with the game's own collision world (resteep.world.raycast / spherecast: terrain, rocks, buildings);
-- on an older ReSteep only with the terrain's height (resteep.world.ground).
-- Credits: the gravity constant and the shape of the arcade model's horizontal drag are the paraglider's, from
-- steep-gameplay-research (github.com/Sean-Shmulevich/steep-gameplay-research, docs/systems/air/CLIENT_GUIDE.txt,
-- used with the author's permission); the tuning values are ours.

local G = 9.8100004196167          -- the game's gravity in the paraglider force law (steep-gameplay-research)
local MAX_SPEED = 80               -- m/s (the API refuses beyond 1000; the game clamps further)
-- arcade
local MAX_TILT = math.rad(25)      -- full cyclic tilts the rotor disc this far
local TILT_TAU = 0.35              -- s, the disc follows the stick with this lag
local YAW_RATE = 1.2               -- rad/s at full pedal
local COLLECTIVE = 0.8             -- full collective: +-0.8 g on top of hover (released = hold the height)
local DRAG_H = 0.00226             -- quadratic horizontal drag, -DRAG_H * |v_h|^2 along v_h: ~45 m/s at full tilt
local DAMP_V = 0.8                 -- 1/s, linear vertical damping: ~10 m/s climb at full collective
local SKIDS = 1.2                  -- m: the lowest the rider goes over the ground in arcade mode, as if on its skids
-- realistic (per unit of mass: accelerations); the rotor's numbers by momentum theory for a ~2.2 t, 10.7 m rotor
local LEVER_RATE = 0.4             -- collective lever travel per second at full RT / LT (0..1: 2.5 s end to end)
local PITCH_THRUST = {0.1, 2.1}    -- the blades' thrust at the lever's bottom and top, in g at sea level (never < 0):
                                   -- hover at ~50 % low in the Alps, ~75 % at 4800 m
local VI0 = 10                     -- m/s: the induced velocity of a 1 g hover at sea level
local HEAVE = {0.45, 1.0}          -- 1/s: thrust lost per m/s of air up through the disc (climbs and sinks settle),
                                   -- in a hover and from 50 m/s on (a tilted disc at speed: the g of a pull or push)
local ETL = {0.5, 1.0}             -- the share of the induced velocity's drop with speed that the rotor gets back as
                                   -- lift, in a hover and from 50 m/s on (translational lift: ~+10 % at 12 m/s; at
                                   -- speed it makes up for the forward-tilted disc's inflow)
local P_PROFILE, P_INDUCED = 0.22, 0.05   -- power (1 = 100 % torque): profile + P_INDUCED * thrust (g) * inflow (m/s)
local TORQUE_MAX, TORQUE_LIMIT = 1.0, 1.1 -- over-torque warning above; above the limit the rotor droops (less thrust)
local ENGINE = 1.35                -- the turbine's power at sea level, times density^0.8 (less up high)
local P_TRIM = 0.75                -- the power at which the tail rotor balances the main rotor's torque, pedals centred
local TORQUE_YAW = 1.6             -- rad/s^2 of yaw per unit of power off P_TRIM (the rotor turns clockwise seen from
                                   -- above: more power yaws the nose left)
local CYCLIC = {2.6, 3.0}          -- rad/s^2 at full stick, pitch and roll (at speed and 1 g; 70 % of it in a hover;
                                   -- with the rotor's load: little thrust, little control)
local PEDAL = 3.0                  -- rad/s^2 at full pedal
-- the rates' damping, (linear + quadratic * |rate|) * rate: small, so a rate goes on after the stick is centred (the
-- rotational inertia) and the top rates come from the quadratic part: at full stick ~130 / 150 deg/s pitch / roll
-- bare, ~100 / 115 at 20 % assist; a 1 rad/s roll left alone halves in ~0.65 s (20 % assist), ~1.2 s bare
local DAMP_ROT = {0.35, 0.35, 0.8}
local DAMP_QUAD = {0.35, 0.3, 0.6}
local ASSIST_DAMP = 2.5            -- 1/s more (linear) rate damping at 100 % assist (it never levels)
local EXPO = 0.45                  -- the player's stick: x * (EXPO + (1 - EXPO) * |x|) (fine near the centre)
local CROSS = 0.25                 -- roll torque per rad/s of pitch rate (small cross-coupling)
local DRAG = {0.003, 0.00022, 0.01}   -- quadratic drag along the body's right, nose and up axes (the disc resists
                                   -- most; ~0.7 m/s^2 along the nose at 200 km/h: speed carries)
local VANE = 0.0035                -- yaw torque per m/s of sideslip and m/s of forward speed (the tail fin: at 200
                                   -- km/h full pedal holds ~15 degrees of sideslip, slowly a flat turn)
local FIN_ARM = 7                  -- m: the fin behind the centre of mass (its yaw damping grows with speed)
local GROUND_EFFECT = 0.12         -- up to +12 % thrust with the skids on the ground, gone at a rotor's width (10 m)
local VRS_LOSS = 0.4               -- the thrust lost in a full vortex ring state
local LOAD_MAX = 2.8               -- g at sea level (less up high): what the blades can lift before they stall
local RBS_SPEED = 76               -- m/s: retreating blade stall sets in (earlier with load and up high)
local RBS_PITCH, RBS_ROLL = 0.8, 1.0   -- rad/s^2 in full stall: pitch up, roll right (the retreating blade is right)
local LOW_G_ROLL = 0.6             -- rad/s^2 of right roll at 0 g (the tail rotor's thrust above the centre of mass)
local BUFFET = 0.6                 -- rad/s^2: the vortex ring's shaking
local CRASH_SPEED = 12             -- m/s into the ground (or a blade / the tail hitting it upside down): a crash
-- the points that touch the ground, in the model's frame: the skids' ends, then nose, tail, the rotor's hub and tips
local SKID_POINTS = {{-1.1, 1.6, 0.1}, {1.1, 1.6, 0.1}, {-1.1, -1.5, 0.1}, {1.1, -1.5, 0.1}}
local HULL_POINTS = {{0, 3.8, 1.0}, {0.34, -8.7, 2.3}, {0.06, 0.74, 3.4}, {4.5, 0.74, 3.3}, {-4.5, 0.74, 3.3},
                     {0.06, 5.2, 3.3}, {0.06, -3.7, 3.3}}
local HUB = {0.06, 0.74, 3.12}     -- the main rotor's hub in the model's frame (the sound comes from there)
local COM = {0.06, -0.3, 1.6}      -- the centre of mass in the model's frame (by eye: under the hub, in the cabin);
                                   -- the rays that probe the world start there

-- STP_Helico: the Alps' root cell has it; Alaska's and Japan's get a copy with a fixed id from this mod's world edits
-- (resteep.json, assets/helicopter_*.json: built at game start; without the build: no model there)
local HELICOS = {0x1105920500E, 0x2F000001000}
local SEAT = {-1.25, 0.4, 0.7}     -- the rider in the left sliding door, in the helicopter's frame
                                   -- (x right, y nose, z up; metres from its origin under the skids; by eye;
                                   -- the cabin floor is 1.1 m up, the sitting rider's hips 0.44 m above its feet)

-- The rotors turn as in the game's drop scenes (TODO 10 "The drop scenes decoded", tools/forge/cinematic.py on
-- STP_ALP_HELICO_02/03): the main rotor -1000 deg/s, the tail rotor +2000 deg/s, each about its bone's own X axis.
-- The game rebuilds the final pose from the local pose every frame (TODO 10, 2026-11-15), so the turn goes into the
-- local pose (resteep.prop.set_bone(..., "local")): the hub's rotation, which carries its blades. Without that
-- (an older ReSteep, or the game not taking it: checked the next frames) each bone goes into the final pose as before.
local MAIN_BLADES = {"Rotor_Blade_A_01", "Rotor_Blade_A_02", "Rotor_Blade_A_03", "Rotor_Blade_B_01",
                     "Rotor_Blade_B_02", "Rotor_Blade_B_03", "Rotor_Blade_C_01", "Rotor_Blade_C_02",
                     "Rotor_Blade_C_03"}
local MAIN_RATE, TAIL_RATE = math.rad(-1000), math.rad(2000)
local SPIN_UP, SPIN_DOWN = 4, 8    -- s from still to full speed, and back

-- The rider sits while flying: the game's sitting idle (ID06 SIT_IDLE, in the rider templates, so it is loaded)
-- plays instead of the idles of the rider on foot (resteep.rider.play_anim). In the game (2026-11-15) a held rider
-- played ID00_PS00_male_STAND_IDLE_Breaker_01/03, ID01_..._Breaker_02_LEFT_STEEP, ID05_PS00_male_STAND_IDLE_04 and
-- ID05_PS99_male_STD (the idle it goes back to after a breaker). The game's clip list (data/modbuild/anim_names.json)
-- has 112 male and 79 female clips of these shapes: the ones built below. While flying, every clip the game looks up
-- (resteep.rider.anim_seen) is matched against the same shapes, so one this list misses sits from its second time on.
local SIT = {male = "ID06_PS00_male_SIT_IDLE", female = "ID06_PS00_female_SIT_IDLE"}
local function standing(name)                         -- "male" / "female" when name is a standing idle, else nil
    local g = name:match("^ID0%d_PS%d%d_(%a+)_STAND_IDLE") or name:match("^ID0%d_PS%d%d_(%a+)_STD$")
    if not SIT[g] or name:find("DRONE") or name:find("_base$") or name:find("_layer$") then return nil end
    return g
end
local function standing_names(g)                      -- the shapes of the game's clip list (unknown ones are skipped)
    local t = {}
    local function add(s) t[#t + 1] = s end
    for ps = 0, 4 do
        local p = string.format("ID00_PS%02d_%s_STAND_IDLE", ps, g)
        add(p)
        for b = 1, 4 do add(string.format("%s_Breaker_%02d", p, b)) add(string.format("%s_breaker_%02d", p, b)) end
        local l = string.format("ID01_PS%02d_%s_STAND_IDLE", ps, g)
        add(l .. "_LEFT") add(l .. "_LEFT_STEEP")
        for b = 1, 4 do
            for _, k in ipairs({"Breaker", "breaker"}) do
                add(string.format("%s_%s_%02d_LEFT", l, k, b)) add(string.format("%s_%s_%02d_LEFT_STEEP", l, k, b))
            end
        end
    end
    for _, s in ipairs({"ID00_PS00_%s_STAND_IDLE_BINOCULAR_BACK", "ID01_PS00_%s_STAND_IDLE_BINOCULAR",
                        "ID01_PS00_%s_STAND_IDLE_BINOCULAR_COPY", "ID01_PS00_%s_STAND_IDLE_STEEP_BINOCULART",
                        "ID01_PS00_%s_STAND_IDLE_STEEP_BINOCULART_COPY", "ID03_PS00_%s_STAND_IDLE",
                        "ID03_PS00_%s_STAND_IDLE_LEFT", "ID03_PS00_%s_STAND_IDLE_LEFT_STEEP",
                        "ID03_PS00_%s_STAND_IDLE_RIGHT", "ID03_PS00_%s_STAND_IDLE_RIGHT_STEEP",
                        "ID03_PS00_%s_STAND_IDLE_STEEP", "ID04_PS00_%s_STAND_IDLE", "ID05_PS00_%s_STAND_IDLE_01",
                        "ID05_PS00_%s_STAND_IDLE_02", "ID05_PS00_%s_STAND_IDLE_03", "ID05_PS00_%s_STAND_IDLE_04",
                        "ID05_PS00_%s_STAND_IDLE_BINOCULAR", "ID05_PS99_%s_STD", "ID06_PS00_%s_STAND_IDLE",
                        "ID06_PS00_%s_STAND_IDLE_BINOCULAR"}) do
        add(string.format(s, g))
    end
    for ps = 0, 1 do
        local p = string.format("ID02_PS%02d_%s_STAND_IDLE", ps, g)
        add(p)
        for b = 1, 4 do add(string.format("%s_Breaker_%02d", p, b)) end
    end
    return t
end
local WATCH_CLIPS = 10             -- s after the start: the clips the game looks up are logged

-- Sound: the mod's own loops (resteep.sound, no game audio), cut from the player's recordings of a real helicopter
-- (tools/helicopter/make_loops.py): rotor_close.wav (next to it) and rotor_far.wav (a fly-by's approach), both at
-- the rotor's hub, crossfaded by the camera's distance (equal power); pitch with the rotor's speed and a little with
-- its load, a Doppler shift. rotor_loop.wav (synthesised by ReSteep's tools/sound/rotor_loop.py) when they are missing.
local LOOPS = {close = "sounds/rotor_close.wav", far = "sounds/rotor_far.wav"}
local RANGE = {close = 500, far = 2000, loop = 500}   -- m: the overlay's falloff (full within a quarter, silent beyond)
local NEAR, FAR = 25, 120          -- m from the camera: only the close loop below, only the far one beyond
local MIX = 0.9                    -- the level at the chase camera (both loops at the same loudness, RMS 0.125: at the
                                   -- default volume ~0.07 RMS, a little under the synthetic layers' 0.45 mix, ~0.08;
                                   -- at 0.9 each those were "very loud", 2026-11-15)
local SPEED_OF_SOUND = 343

local on = false                   -- the rider is held and flies
local hovering = false             -- left in the air: the pilot holds a hover, rotors running
local realistic = false            -- the flight model in use
local v = {0, 0, 0}                -- velocity, world, Z up
local org                          -- the helicopter's origin (under the skids), world
local R = {r = {1, 0, 0}, f = {0, 1, 0}, u = {0, 0, 1}}   -- its axes: right, nose, up (world)
local W = {0, 0, 0}                -- realistic: angular velocity about the body's right, nose, up axes (rad/s)
local yaw, pitch, roll = 0, 0, 0   -- arcade: heading (0 = +Y, positive turns towards -X) and the disc's tilt
local hold_z                       -- the height the pilot holds while hovering
local cam, cam_heading             -- the chase camera's smoothed position and heading
local heli                         -- resteep.prop handle of the helicopter (nil: not in this world)
local crash_cool = 0               -- s: after a crash, the next one is not reported
local last_coll = 0                -- the collective last used (the sound's load)
local lever = 0                    -- realistic: the collective lever, 0 (down) .. 1 (up); stays where it is set
-- realistic: the rotor this frame (rotor_state, rigid_step): thrust along the up axis and translational lift (m/s^2),
-- power (1 = 100 % torque) and what is available, the load (g along the up axis; the lowest of the frame), vortex ring
-- and retreating blade stall (0..1), stall from load, the control authority, how far the rotor droops for want of
-- power (0..1), the airspeed in the disc's plane, the air's density (relative to sea level), the heave damping (1/s)
local rotor = {thrust = 0, lift = 0, power = 0, avail = 1, n = 1, nmin = 1, vrs = 0, rbs = 0, auth = 0.6, droop = 0,
               vp = 0, sigma = 1, stall = false, heave = 0.45}
local clock = 0                    -- s of realistic flight (the vortex ring's buffeting)
local crashed = false              -- a crash happened this frame (the pilot gives up the hover)
local grounded = false             -- the model rested on the ground last frame

local held_before = {}             -- pad buttons held last frame (for presses)
local rotors                       -- the rotors' bones as the parked helicopter has them (nil: not read / none)
local spin, turned_main, turned_tail = 0, 0, 0   -- 0..1 of full speed; the angles turned so far
local rotor_way                    -- "local" (the local pose) or "final" (each bone in the final pose)
local local_check                  -- {angle, frames, good}: is the local pose's turn in the game's final pose?
local watching = 0                 -- s left of logging the rider's clips
local seated = {}                  -- clip name -> true: redirected to the sitting idle
local to_seat = {}                 -- {name, gender} still to redirect: a few per frame (SEAT_PER_FRAME)
local SEAT_PER_FRAME = 24          -- ~310 names at once took the mod past its 20 ms and made the game stutter
local sounds = {}                  -- {close = id, far = id} or {loop = id}
local sound_failed = false         -- no sound could start (no audio device): not tried again every frame
local cam_prev                     -- the camera's position last frame (the Doppler shift)

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end
local function smooth(x, a, b) local t = clamp((x - a) / (b - a), 0, 1) return t * t * (3 - 2 * t) end

-- small vector helpers (arrays {x, y, z})
local function add(a, b, s) s = s or 1 return {a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s} end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) local l = len(a) return l > 1e-9 and {a[1] / l, a[2] / l, a[3] / l} or {0, 0, 1} end
local function body(p)                                    -- a point of the model's frame in the world
    return {org[1] + R.r[1] * p[1] + R.f[1] * p[2] + R.u[1] * p[3],
            org[2] + R.r[2] * p[1] + R.f[2] * p[2] + R.u[2] * p[3],
            org[3] + R.r[3] * p[1] + R.f[3] * p[2] + R.u[3] * p[3]}
end
local function turn_about(x, k, a)                        -- x turned by angle a about the unit axis k (Rodrigues)
    local c, s = math.cos(a), math.sin(a)
    local kx, kd = cross(k, x), dot(k, x) * (1 - c)
    return {x[1] * c + kx[1] * s + k[1] * kd, x[2] * c + kx[2] * s + k[2] * kd, x[3] * c + kx[3] * s + k[3] * kd}
end
local function orthonormal()                              -- keep the axes square and of length 1
    R.f = unit(R.f)
    R.u = unit(add(R.u, R.f, -dot(R.f, R.u)))
    R.r = cross(R.f, R.u)
end
local function heading_axes(h)                            -- level axes for heading h
    R.f, R.u = {-math.sin(h), math.cos(h), 0}, {0, 0, 1}
    R.r = cross(R.f, R.u)
end

-- quaternions {x, y, z, w} (the API's rotations)
local function qmul(a, b)
    return {x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z}
end
local function qrot(q, p)                                 -- p turned by q
    local r = qmul(qmul(q, {x = p.x, y = p.y, z = p.z, w = 0}), {x = -q.x, y = -q.y, z = -q.z, w = q.w})
    return {x = r.x, y = r.y, z = r.z}
end
local function about(axis, angle)
    local s = math.sin(angle / 2)
    return {x = axis.x * s, y = axis.y * s, z = axis.z * s, w = math.cos(angle / 2)}
end
local X = {x = 1, y = 0, z = 0}

local function setting(key, default)
    local ok, val = pcall(resteep.config.get, key)
    if ok and val ~= nil then return val end
    return default
end

---------------------------------------------------------------------------------------------------------- rotors

-- the rotors' bones as the parked helicopter has them; the local pose when this ReSteep has it (its records come
-- without `world`; an older one ignores "local" and gives the final pose's)
local function read_rotors()
    local function rec(n, pose)
        local b, why = resteep.prop.bone(heli, n, pose)
        if not b then error(n .. ": " .. tostring(why), 0) end
        return b
    end
    local ok, r = pcall(function()
        local t = {main = rec("Main_Rotor"), tail = rec("Tail_Rotor"), blades = {}}
        for _, n in ipairs(MAIN_BLADES) do t.blades[n] = rec(n) end
        local lm = resteep.prop.bone(heli, "Main_Rotor", "local")
        local lt = resteep.prop.bone(heli, "Tail_Rotor", "local")
        if lm and lt and lm.world == nil then t.local_main, t.local_tail = lm, lt end
        t.center = {x = t.main.x, y = t.main.y, z = t.main.z}
        t.axis = qrot(t.main.rot, X)                          -- the hub's own X in the model's frame
        t.tail_center = {x = t.tail.x, y = t.tail.y, z = t.tail.z}
        t.tail_axis = qrot(t.tail.rot, X)
        return t
    end)
    if not ok then resteep.log("helicopter: the rotors stay still: " .. tostring(r)) return end
    rotors, rotor_way = r, r.local_main and "local" or "final"
    local_check = rotor_way == "local" and {frames = 0, good = 0} or nil
    resteep.log(string.format("helicopter: rotor axis (%.2f, %.2f, %.2f), hub (%.2f, %.2f, %.2f), turned in the %s "
                              .. "pose", r.axis.x, r.axis.y, r.axis.z, r.center.x, r.center.y, r.center.z, rotor_way))
end

-- the final pose's way: each bone turned about its rotor's hub (the game puts its own pose back every frame, so
-- this flickers: the fallback only)
local function turn_final(main, tail)
    local function turn(name, b, center, axis, angle)
        local q = about(axis, angle)
        local d = qrot(q, {x = b.x - center.x, y = b.y - center.y, z = b.z - center.z})
        return resteep.prop.set_bone(heli, name, {x = center.x + d.x, y = center.y + d.y, z = center.z + d.z,
                                                  rot = qmul(q, b.rot)})
    end
    local ok, why = turn("Main_Rotor", rotors.main, rotors.center, rotors.axis, main)
    for _, n in ipairs(MAIN_BLADES) do
        if not ok then break end
        ok, why = turn(n, rotors.blades[n], rotors.center, rotors.axis, main)
    end
    if ok then ok, why = turn("Tail_Rotor", rotors.tail, rotors.tail_center, rotors.tail_axis, tail) end
    return ok, why
end

-- the local pose's way: the hub's rotation about its own X axis (the game's rebuild turns the blades with it)
local function turn_local(main, tail)
    local ok, why = resteep.prop.set_bone(heli, "Main_Rotor", {rot = qmul(rotors.local_main.rot, about(X, main))},
                                          "local")
    if ok then
        ok, why = resteep.prop.set_bone(heli, "Tail_Rotor", {rot = qmul(rotors.local_tail.rot, about(X, tail))},
                                        "local")
    end
    return ok, why
end

-- did the game's final pose take last frame's local turn? (its rebuild runs between two mods' frames)
local function check_local()
    if not (local_check and local_check.angle) then return end
    if math.abs(math.sin(local_check.angle / 2)) < 0.05 then return end  -- near the parked pose: tells nothing
    local b = resteep.prop.bone(heli, "Main_Rotor")
    local want = qmul(rotors.main.rot, about(X, local_check.angle))
    local d = b and math.abs(b.rot.x * want.x + b.rot.y * want.y + b.rot.z * want.z + b.rot.w * want.w) or 0
    local_check.frames = local_check.frames + 1
    if d > 0.999 then local_check.good = local_check.good + 1 end
    if local_check.good >= 5 then
        resteep.log("helicopter: the rotors turn through the local pose (the game's own pose update carries them)")
        local_check = nil
    elseif local_check.frames >= 20 then
        resteep.log("helicopter: the game does not take the local pose's turn: each bone into the final pose instead")
        resteep.prop.set_bone(heli, "Main_Rotor", {rot = rotors.local_main.rot}, "local")
        resteep.prop.set_bone(heli, "Tail_Rotor", {rot = rotors.local_tail.rot}, "local")
        rotor_way, local_check = "final", nil
    end
end

-- every frame: towards full speed while the engine runs (flying or hovering), to a stop when parked
local function spin_rotors(dt)
    if not (heli and rotors) then return end
    check_local()
    local engine = on or hovering
    spin = clamp(spin + (engine and dt / SPIN_UP or -dt / SPIN_DOWN), 0, 1)
    if spin == 0 and turned_main == 0 then return end
    local rate = setting("rotor_speed", 100) / 100
    turned_main = (turned_main + MAIN_RATE * rate * spin * dt) % (2 * math.pi)
    turned_tail = (turned_tail + TAIL_RATE * rate * spin * dt) % (2 * math.pi)
    if spin == 0 then turned_main, turned_tail = 0, 0 end                 -- stopped: back to the parked pose
    local ok, why
    if rotor_way == "local" then ok, why = turn_local(turned_main, turned_tail)
    else ok, why = turn_final(turned_main, turned_tail) end
    if not ok then resteep.log("helicopter: the rotors stop: " .. tostring(why)) rotors = nil return end
    if local_check then local_check.angle = turned_main end
end

------------------------------------------------------------------------------------------------------------ seat

-- play_anim gives nil for a name this game's clip list lacks (an error on older overlays: pcall covers both)
local function redirect(name, g)
    local ok, set, why = pcall(resteep.rider.play_anim, name, SIT[g])
    if ok and set then seated[name] = true return true end
    return false, ok and why or set
end

-- the rider sits (true) or stands again (false)
local seat_count = 0
local function seat(sit)
    if not sit then
        to_seat = {}
        for name in pairs(seated) do pcall(resteep.rider.play_anim, name) end
        seated = {}
        return
    end
    to_seat = {}                                                          -- redirected over the next frames
    for g in pairs(SIT) do
        for _, name in ipairs(standing_names(g)) do to_seat[#to_seat + 1] = {name, g} end
    end
    seat_count = 0
end

-- a few of the queued names each frame (names this game lacks are skipped)
local function seat_step()
    if #to_seat == 0 then return end
    for _ = 1, math.min(SEAT_PER_FRAME, #to_seat) do
        local e = table.remove(to_seat)
        if not seated[e[1]] and redirect(e[1], e[2]) then seat_count = seat_count + 1 end
    end
    if #to_seat == 0 then resteep.log("helicopter: " .. seat_count .. " standing idles play the sitting one") end
end

-- the clips the game looked up: a standing idle the list missed sits from now on
local function watch_clips(dt)
    local seen = resteep.rider.anim_seen()
    if not seen then return end
    for _, name in ipairs(seen) do
        local g = standing(name)
        if g and not seated[name] then
            local ok, err = redirect(name, g)
            resteep.log("helicopter: " .. name .. (ok and " sits from now on" or (": " .. tostring(err))))
        end
    end
    if watching > 0 then
        watching = watching - dt
        if #seen > 0 then resteep.log("helicopter: the rider plays " .. table.concat(seen, ", ")) end
    end
end

---------------------------------------------------------------------------------------------------------- sound

local function sound_start()
    if sounds.close or sounds.loop or sound_failed then return end
    local at = org and body(HUB) or {0, 0, 0}
    local where = {x = at[1], y = at[2], z = at[3]}
    local function play(file, range)
        return resteep.sound.play(file, {loop = true, volume = 0, range = range, at = where})
    end
    local c, why = play(LOOPS.close, RANGE.close)
    local f = c and play(LOOPS.far, RANGE.far)
    if c and f then sounds = {close = c, far = f} return end
    if c then resteep.sound.stop(c) end
    local l, why2 = play("sounds/rotor_loop.wav", RANGE.loop)
    if l then sounds = {loop = l} return end
    sound_failed = true
    resteep.log("helicopter: no rotor sound: " .. tostring(why2 or why))
end

local function sound_stop()
    for _, id in pairs(sounds) do resteep.sound.stop(id) end
    sounds = {}
end

-- the mix: close / far by the camera's distance, softer further away (on top of the overlay's falloff), louder under
-- load; pitch from the rotor's speed (winding up and down, drooping when the power runs out) and load; Doppler from
-- the helicopter's speed towards the camera
local function sound_update(dt, load)
    if spin <= 0 or not org then sound_stop() return end
    sound_start()
    local at = body(HUB)
    local doppler, d = 1, 0
    local c = resteep.camera()
    if c then
        local cv = cam_prev and {(c.x - cam_prev[1]) / dt, (c.y - cam_prev[2]) / dt, (c.z - cam_prev[3]) / dt}
                   or {0, 0, 0}
        cam_prev = {c.x, c.y, c.z}
        local to = {at[1] - c.x, at[2] - c.y, at[3] - c.z}
        d = len(to)
        if d > 1 then
            local away = dot(add(v, cv, -1), to) / d                      -- m/s the source moves away from the ear
            doppler = clamp(SPEED_OF_SOUND / (SPEED_OF_SOUND + away), 0.8, 1.25)
        end
    end
    local where = {x = at[1], y = at[2], z = at[3]}
    local level = MIX * setting("volume", 60) / 100 * spin * (0.3 + 0.7 * spin) * clamp(1.6 / (1 + d / 60), 0, 1)
    local droop = realistic and (on or hovering) and rotor.droop or 0
    local rate = (0.5 + 0.5 * spin) * (0.98 + 0.05 * load) * (1 - 0.04 * droop)
    local function set(id, volume, range)
        resteep.sound.set(id, {loop = true, volume = clamp(volume, 0, 1), range = range, at = where,
                               pitch = clamp(rate * doppler, 0.25, 4)})
    end
    if sounds.loop then set(sounds.loop, level * (0.85 + 0.3 * load), RANGE.loop) return end
    if not sounds.close then return end                                   -- no audio device
    local t = smooth(d, NEAR, FAR) * math.pi / 2
    set(sounds.close, level * math.cos(t) * (0.85 + 0.3 * load), RANGE.close)
    set(sounds.far, level * math.sin(t) * (0.9 + 0.2 * load), RANGE.far)
end

------------------------------------------------------------------------------------------------------- controls

-- the real pad's buttons pressed since the last frame (a set of names), and the pad itself (nil without one)
local function pad_presses()
    local pad, now, pressed = resteep.input.read(), {}, {}
    for _, b in ipairs(pad and pad.buttons or {}) do
        now[b] = true
        if not held_before[b] then pressed[b] = true end
    end
    held_before = now
    return pressed, pad
end

-- what the pad or the keyboard asks for: forward, right, pedal (right = clockwise), collective; each -1..1
local function controls(pad)
    local f, r, pedal, coll = 0, 0, 0, 0
    if pad then f, r, pedal, coll = pad.ly, pad.lx, pad.rx, pad.rt - pad.lt end
    local function key(k) return resteep.held(k) and 1 or 0 end
    -- letters for a keyboard without a numpad (thought free in Steep's default keys, not checked): I J K L tilt,
    -- U O turn, Y H up / down; the numpad and Page Up / Down do the same
    f = f + key("I") - key("K") + key("NUMPAD8") - key("NUMPAD5") - key("NUMPAD2")
    r = r + key("L") - key("J") + key("NUMPAD6") - key("NUMPAD4")
    pedal = pedal + key("O") - key("U") + key("NUMPAD9") - key("NUMPAD7")
    coll = coll + key("Y") - key("H") + key("PAGEUP") - key("PAGEDOWN")
    local function dead(x) x = clamp(x, -1, 1) return math.abs(x) < 0.12 and 0 or x end
    return dead(f), dead(r), dead(pedal), dead(coll)
end

-- realistic: the damping (1/s) of the turn rate w about body axis i (1 pitch, 2 roll, 3 yaw); the tail fin's grows
-- with the forward speed
local function damping(i, w, assist)
    local d = DAMP_ROT[i] + DAMP_QUAD[i] * math.abs(w) + assist * ASSIST_DAMP
    if i == 3 then d = d + VANE * FIN_ARM * math.abs(dot(v, R.f)) end
    return d
end

-- the helicopter's pilot while nobody flies it: level, no drift, the height it was left at (stick values, as a
-- player would give them)
local function autopilot()
    if not realistic then                                 -- arcade: lean against the drift, hold the height
        local fh, rh = unit({R.f[1], R.f[2], 0}), unit({R.r[1], R.r[2], 0})
        return clamp(-dot(v, fh) / 12, -1, 1), clamp(-dot(v, rh) / 12, -1, 1), 0,
               clamp(-(org[3] - hold_z) / 20, -0.5, 0.5)
    end
    -- realistic, the way a pilot flies it (approximately: the lever at the player's rate, rate-limited cyclic): the
    -- disc level, tilted against the drift (at most ~17 degrees), the yaw held against the rotor's torque, the lever at
    -- the thrust that holds the height
    local want = unit({clamp(-0.06 * v[1], -0.3, 0.3), clamp(-0.06 * v[2], -0.3, 0.3), 1})
    local k = cross(R.u, want)
    local angle = math.atan(len(k), dot(R.u, want))                         -- how far off, 0..pi
    k = len(k) > 1e-3 and unit(k) or R.f                                    -- upside down: roll over
    local rate = math.min(1, 2.5 * angle)
    local wx, wy = rate * dot(k, R.r), rate * dot(k, R.f)
    local assist = setting("assist", 20) / 100
    local sens = setting("sensitivity", 100) / 100
    local f = -(damping(1, W[1], assist) * W[1] + 4 * (wx - W[1])) / (CYCLIC[1] * rotor.auth)
    local r = (damping(2, W[2], assist) * W[2] + 4 * (wy - W[2])) / (CYCLIC[2] * rotor.auth)
    local pedal = (TORQUE_YAW * (rotor.power - P_TRIM) + 3 * W[3]) / (PEDAL * sens)
    local want_lever = 0.4                                                  -- on its side or upside down: some load
    if R.u[3] > 0.3 then                                                    -- upright: hold the height
        local need = (G + clamp(-0.8 * (org[3] - hold_z) - 1.6 * v[3], -4, 4)) / R.u[3] - rotor.lift
        local per = G * rotor.sigma * (PITCH_THRUST[2] - PITCH_THRUST[1])
        want_lever = (need - G * rotor.sigma * PITCH_THRUST[1]) / per
    end
    return clamp(f, -1, 1), clamp(r, -1, 1), clamp(pedal, -1, 1), clamp((want_lever - lever) * 5, -1, 1)
end

---------------------------------------------------------------------------------------------------- flight models

-- Contact with the world. With resteep.world.raycast (the game's own collision world: rocks, buildings, trees) each
-- point of the skids and the hull is probed by a ray from inside the helicopter (its centre of mass) out to the point,
-- and the move of the frame is swept; without it (an older ReSteep) only the terrain's height (resteep.world.ground,
-- a 4 m raster, no objects) counts, at the points themselves. A probe gives how deep the point is in, and the
-- surface's normal.
local function world_fn(name)
    local ok, f = pcall(function() return resteep.world[name] end)
    return ok and type(f) == "function" and f or nil
end
local function raycast_fn() return world_fn("raycast") end
-- the helicopter's own model is left out (its collision, if it has any, moves with it): opts.ignore
local function opts() return heli and {ignore = heli} or nil end
-- a cast: the hit, nil when nothing is in the way, false when it was not asked (a menu, the per-frame budget, a model
-- not loaded): then the terrain's raster decides, as on an older ReSteep
local function cast(a, b, radius)
    local f = world_fn(radius and "spherecast" or "raycast")
    if not f then return false end
    local ok, hit, why
    if radius then ok, hit, why = pcall(f, a, b, radius, opts())
    else ok, hit, why = pcall(f, a[1], a[2], a[3], b[1], b[2], b[3], opts()) end
    if ok and type(hit) == "table" and hit.x then return hit end
    if ok and hit == nil and why == nil then return nil end
    return false
end
local function probe(p)                                   -- a world point: depth in the world (> 0) and normal, or nil
    local hit = cast(body(COM), p)
    if hit then
        local n = unit({hit.nx or 0, hit.ny or 0, hit.nz or 1})
        local d = dot({hit.x - p[1], hit.y - p[2], hit.z - p[3]}, n)
        if d > 0 then return d, n end
        return nil
    end
    if hit == nil then return nil end
    local g = resteep.world.ground(p[1], p[2])
    if g and g > p[3] then return g - p[3], {0, 0, 1} end
end
local function height_below(p, most)                      -- metres from p down to what is under it (nil: unknown / far)
    local hit = cast(p, {p[1], p[2], p[3] - most})
    if hit then return p[3] - hit.z end
    if hit == nil then return nil end
    local g = resteep.world.ground(p[1], p[2])
    return g and p[3] - g or nil
end

-- a crash: still and upright where it is, pushed out of what it hit; the rider stays in it (never flung away)
local function crash(n, depth, what)
    local h = math.abs(R.f[3]) < 0.9 and math.atan(-R.f[1], R.f[2]) or (cam_heading or 0)
    heading_axes(h)
    v, W = {0, 0, 0}, {0, 0, 0}
    org = add(org, n, math.min(3, depth + 0.3))
    local g = resteep.world.ground(org[1], org[2])
    if g and org[3] < g then org[3] = g + 0.05 end
    if crash_cool <= 0 then resteep.notify("helicopter: crashed (" .. what .. "): back on its skids", 3) end
    crash_cool, lever, crashed = 2, 0, true
end

-- the skids, hull and rotor against the world after a step; true when it stands on its skids. crashes: whether a hard
-- hit (or a blade / the tail hitting something upside down) is a crash (realistic) or only stops it (arcade)
local function contacts(dt, crashes, from_com)
    local skid_d, skid_n, hull_d, hull_n, hull_what = 0, nil, 0, nil, nil
    for _, p in ipairs(SKID_POINTS) do
        local d, n = probe(body(p))
        if d and d > skid_d then skid_d, skid_n = d, n end
    end
    for i, p in ipairs(HULL_POINTS) do
        local d, n = probe(body(p))
        if d and d > hull_d then hull_d, hull_n, hull_what = d, n, i >= 3 and "the rotor" or "the hull" end
    end
    if from_com and raycast_fn() then                     -- the frame's move swept (the cabin as a 1.2 m sphere)
        local now = body(COM)
        local hit = cast(from_com, now, 1.2)
        if hit then
            local n = unit({hit.nx or 0, hit.ny or 0, hit.nz or 1})
            local d = dot({hit.x - now[1], hit.y - now[2], hit.z - now[3]}, n) + 0.2
            if d > hull_d then hull_d, hull_n, hull_what = d, n, "the hull" end
        end
    end
    local depth, n = skid_d, skid_n
    if hull_d > skid_d then depth, n = hull_d, hull_n end
    if depth <= 0 then return false end
    local impact = -dot(v, n)
    if crashes and (impact > CRASH_SPEED or (hull_d > 0 and (R.u[3] < 0.3 or impact > 6 or hull_what == "the rotor"))) then
        crash(n, depth, impact > CRASH_SPEED and "too fast" or hull_what)
        return true
    end
    org = add(org, n, math.min(3, depth))                -- out of it, never faster than it came
    if impact > 0 then v = add(v, n, impact * (impact > 3 and 1.2 or 1)) end
    local fr = math.max(0, 1 - 3 * dt)                    -- friction along the surface
    local vn = dot(v, n)
    v = add({v[1] * fr, v[2] * fr, v[3] * fr}, n, vn * (1 - fr))
    local wd = math.max(0, 1 - 8 * dt)
    W = {W[1] * wd, W[2] * wd, W[3] * math.max(0, 1 - 4 * dt)}
    if skid_d > 0 and R.u[3] > 0.5 then                   -- on the skids: it settles level
        local k = cross(R.u, {0, 0, 1})
        local s = len(k)
        if s > 1e-6 then
            local a = math.min(math.asin(math.min(1, s)), 2 * dt)
            R.f, R.u = turn_about(R.f, unit(k), a), turn_about(R.u, unit(k), a)
            orthonormal()
        end
    end
    return skid_d > 0 and skid_d >= hull_d
end

-- arcade: the disc tilts towards the stick, thrust holds the height; true when it rests on the ground
local function arcade(dt, f, r, pedal, coll)
    local a = math.min(1, dt / TILT_TAU)
    pitch = pitch + (f * MAX_TILT - pitch) * a
    roll = roll + (r * MAX_TILT - roll) * a
    yaw = yaw - pedal * YAW_RATE * dt
    local fx, fy = -math.sin(yaw), math.cos(yaw)             -- heading
    local rx, ry = fy, -fx                                   -- its right
    -- the rotor's thrust along the tilted disc's axis: hover at collective 0
    local ax, ay, az = fx * math.tan(pitch) + rx * math.tan(roll), fy * math.tan(pitch) + ry * math.tan(roll), 1
    local n = math.sqrt(ax * ax + ay * ay + az * az)
    local thrust = G * (1 + coll * COLLECTIVE) / (az / n)    -- the vertical part alone holds the height
    ax, ay, az = ax / n * thrust, ay / n * thrust, az / n * thrust
    local h = math.sqrt(v[1] * v[1] + v[2] * v[2])
    if h > 1e-5 then ax, ay = ax - DRAG_H * h * v[1], ay - DRAG_H * h * v[2] end
    az = az - G - DAMP_V * v[3]
    v = {v[1] + ax * dt, v[2] + ay * dt, v[3] + az * dt}
    local s = len(v)
    if s > MAX_SPEED then v = {v[1] / s * MAX_SPEED, v[2] / s * MAX_SPEED, v[3] / s * MAX_SPEED} end
    -- the axes: pitch forward = nose down, roll right = right side down
    local cy, sy, cp, sp, cr, sr = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch), math.cos(roll),
                                   math.sin(roll)
    local ua, ra = {-sy * sp, cy * sp, cp}, {cy, sy, 0}
    R.f = {-sy * cp, cy * cp, -sp}
    R.r = {ra[1] * cr - ua[1] * sr, ra[2] * cr - ua[2] * sr, ra[3] * cr - ua[3] * sr}
    R.u = {ua[1] * cr + ra[1] * sr, ua[2] * cr + ra[2] * sr, ua[3] * cr + ra[3] * sr}
    org = add(org, v, dt)
    -- never below the ground: the rider's seat at least SKIDS over it (the game's collision under the seat, else the
    -- terrain's raster; nil where neither knows: no check there)
    local seat_at = body(SEAT)
    local below = height_below({seat_at[1], seat_at[2], seat_at[3] + 3}, 100)   -- from just above: not a roof over it
    local ground = below and seat_at[3] + 3 - below or nil
    if ground and seat_at[3] < ground + SKIDS then
        org[3] = org[3] + ground + SKIDS - seat_at[3]
        if v[3] < 0 then v[3] = 0 end                        -- landed: the descent stops
    end
    if raycast_fn() and contacts(dt, false, nil) then return true end   -- rocks and buildings: stops at them
    return ground ~= nil and seat_at[3] < ground + SKIDS + 0.3
end

local function density(z) return (1 - 2.2558e-5 * clamp(z, -500, 9000)) ^ 4.2559 end   -- ISA, relative to sea level
local function hover_lever(z)                             -- the lever of a 1 g hover out of ground effect at height z
    return clamp((1 / density(z) - PITCH_THRUST[1]) / (PITCH_THRUST[2] - PITCH_THRUST[1]), 0, 1)
end

-- realistic: the rotor for this frame, from the lever, the air's density at this height (the world's z as metres
-- above the sea: the Alps reach 4800), the airflow through and along the disc and the last load
local function rotor_state(ground_h)
    local sigma = density(org[3])
    local vb3 = dot(v, R.u)                                       -- air up through the disc (+: climbing)
    local vp = len(add(v, R.u, -vb3))                             -- airspeed in the disc's plane
    local tp = G * sigma * (PITCH_THRUST[1] + (PITCH_THRUST[2] - PITCH_THRUST[1]) * lever)
    local vh = VI0 * math.sqrt(math.max(tp / G, 0.05) / sigma)    -- the induced velocity of a hover at this thrust
    local vl = math.sqrt((math.sqrt(vp ^ 4 + 4 * vh ^ 4) - vp * vp) / 2)   -- ... in level flight at vp (Glauert)
    -- vortex ring: sinking at 0.3-1.9 times that, slowly, the rotor in its own downwash (lowering the lever lowers
    -- the band, speed blows it away)
    local vrs = smooth(-vb3, 0.3 * vh, 0.6 * vh) * (1 - smooth(-vb3, 1.3 * vh, 1.9 * vh)) * (1 - smooth(vp, 5, 11))
    local rbs = clamp((vp - (RBS_SPEED - 10 * math.max(0, rotor.n - 1) - 20 * (1 - sigma))) / 8, 0, 1)
    local ge = ground_h and 1 + GROUND_EFFECT * clamp(1 - ground_h / 10, 0, 1) or 1
    local t = tp * ge * (1 - VRS_LOSS * vrs) * (1 - 0.2 * rbs)
    local w, vi = math.max(vb3, 0), vh                            -- the induced velocity with speed and climb
    for _ = 1, 4 do vi = 0.5 * (vi + vh * vh / math.sqrt(vp * vp + (w + vi) ^ 2)) end
    -- power: the blades' profile + thrust times the air through the disc (induced, climb, and the tilted disc's share
    -- of the drag); sinking, the air drives the rotor (autorotation: 0)
    local p = math.max(0, P_PROFILE + P_INDUCED * t / G * (vi / ge + vb3) + 0.15 * vrs)
    local avail = math.min(TORQUE_LIMIT, ENGINE * sigma ^ 0.8)
    rotor.droop = clamp((p - avail) / 0.3, 0, 1)
    if p > avail then                                             -- the rotor droops: only the thrust the power gives
        t = t * ((avail - P_PROFILE) / (p - P_PROFILE)) ^ 0.8
        p = avail
    end
    rotor.sigma, rotor.vp, rotor.thrust, rotor.power, rotor.avail = sigma, vp, t, p, avail
    local fast = clamp(vp / 50, 0, 1)
    rotor.heave = HEAVE[1] + (HEAVE[2] - HEAVE[1]) * fast
    rotor.lift = (ETL[1] + (ETL[2] - ETL[1]) * fast) * rotor.heave * (vh - vl) * clamp(tp / G, 0, 1)   -- translational
    rotor.vrs, rotor.rbs = vrs, rbs
end

-- realistic: one step of the rigid body (dt small)
local function rigid_step(dt, f, r, pedal, assist, sens)
    -- along the up axis: the rotor's thrust and translational lift, less what the air up through the disc takes
    -- (the vortex ring takes the sink's part; never below 0: pushed over, the rotor unloads, low g); this is the load
    -- the hub feels. A flare at speed: the air comes up through the tilted disc and loads it, its thrust tilted back
    -- slows the helicopter (up to the blades' stall)
    local vb = {dot(v, R.r), dot(v, R.f), dot(v, R.u)}
    local heave = rotor.heave * vb[3] * (vb[3] < 0 and 1 - rotor.vrs or 1)
    local fu = math.max(0, rotor.thrust + rotor.lift - heave) - DRAG[3] * math.abs(vb[3]) * vb[3]
    if fu > LOAD_MAX * G * rotor.sigma then fu, rotor.stall = LOAD_MAX * G * rotor.sigma, true end
    rotor.n = fu / G
    rotor.nmin = math.min(rotor.nmin, rotor.n)
    local acc = {R.u[1] * fu, R.u[2] * fu, R.u[3] * fu - G}
    acc = add(acc, R.r, -DRAG[1] * math.abs(vb[1]) * vb[1])
    acc = add(acc, R.f, -DRAG[2] * math.abs(vb[2]) * vb[2])
    v = add(v, acc, dt)
    org = add(org, v, dt)
    -- torques: the cyclic (with the rotor's load: little thrust, little control; weaker in a hover), the pedals
    -- against the rotor's torque, the tail fin turning the nose into the wind (and damping its yaw, damping()), blade
    -- stall, low-g roll, the vortex ring's buffeting, against a small damping (and the assist's): the rates have
    -- inertia, nothing levels it
    local auth = clamp(0.25 + 0.75 * rotor.n, 0.15, 1.3) * (0.7 + 0.3 * clamp(rotor.vp / 30, 0, 1)) * sens
    rotor.auth = math.max(auth, 0.05)
    local alpha = {-CYCLIC[1] * auth * f, CYCLIC[2] * auth * r, -PEDAL * sens * pedal}
    alpha[1] = alpha[1] + RBS_PITCH * rotor.rbs + BUFFET * rotor.vrs * math.sin(clock * 5.3)
    alpha[2] = alpha[2] + RBS_ROLL * rotor.rbs + LOW_G_ROLL * clamp(1 - rotor.n / 0.5, 0, 1) + CROSS * W[1]
               + BUFFET * rotor.vrs * math.sin(clock * 7.1 + 1)
    alpha[3] = alpha[3] + TORQUE_YAW * (rotor.power - P_TRIM) - VANE * vb[1] * math.abs(vb[2])
    if grounded then alpha[3] = alpha[3] * clamp(rotor.n, 0, 1) ^ 2 end   -- its weight on the skids holds the heading
    for i = 1, 3 do W[i] = W[i] + (alpha[i] - damping(i, W[i], assist) * W[i]) * dt end
    -- turn the axes about the world vector of W (body right = pitch, nose = roll, up = yaw)
    local w = add(add({R.r[1] * W[1], R.r[2] * W[1], R.r[3] * W[1]}, R.f, W[2]), R.u, W[3])
    local wl = len(w)
    if wl > 1e-9 then
        local k = {w[1] / wl, w[2] / wl, w[3] / wl}
        R.f, R.u = turn_about(R.f, k, wl * dt), turn_about(R.u, k, wl * dt)
        orthonormal()
    end
end

local function realistic_fly(dt, f, r, pedal, coll)
    local assist = setting("assist", 20) / 100
    local sens = setting("sensitivity", 100) / 100
    lever = clamp(lever + coll * LEVER_RATE * dt, 0, 1)
    clock = clock + dt
    local ground_h = height_below(body(COM), 12)
    if ground_h then ground_h = math.max(0, ground_h - COM[3]) end
    rotor_state(ground_h)
    rotor.nmin, rotor.stall = math.huge, false
    local from = body(COM)
    local n = math.max(1, math.ceil(dt * 120 - 1e-9))
    for _ = 1, n do rigid_step(dt / n, f, r, pedal, assist, sens) end
    local s = len(v)
    if s > MAX_SPEED then v = {v[1] / s * MAX_SPEED, v[2] / s * MAX_SPEED, v[3] / s * MAX_SPEED} end
    if contacts(dt, true, from) then return true end
    local lowest                                          -- the skids just above something: resting on it
    for _, p in ipairs(SKID_POINTS) do
        local h = height_below(body(p), 0.5)
        if h and (not lowest or h < lowest) then lowest = h end
    end
    return lowest ~= nil and lowest < 0.3
end

-- the helicopter where the model says (the full matrix: rows right, nose, up, origin)
local function place_heli()
    if not heli then return end
    local ok, why = resteep.prop.set(heli, {matrix = {R.r[1], R.r[2], R.r[3], 0, R.f[1], R.f[2], R.f[3], 0,
                                                      R.u[1], R.u[2], R.u[3], 0, org[1], org[2], org[3], 1}})
    if not ok then resteep.log("helicopter: the model stays behind: " .. tostring(why)) heli = nil end
end

-- one frame of either model; true when it rests on the ground
local function step_model(dt, f, r, pedal, coll)
    last_coll = coll
    if realistic then return realistic_fly(dt, f, r, pedal, coll) end
    return arcade(dt, f, r, pedal, coll)
end

-- the model switched in flight: the realistic one goes on from the arcade one's axes, the arcade one keeps the
-- heading and levels out
local function set_model(want)
    if want == realistic then return end
    realistic = want
    if want then W, lever = {0, 0, 0}, grounded and 0 or hover_lever(org[3])
    else yaw, pitch, roll = math.atan(-R.f[1], R.f[2]), 0, 0 end
end

----------------------------------------------------------------------------------------------------- start / stop

-- the game's activities of a sport (player().activity, docs/modding/api.md): the helicopter starts only on foot and
-- standing still, else the game goes on riding the board / skis under the held rider
local ON_FOOT = 6                  -- walking (seen in the game, 2026-11-11)
local RIDING = {[0] = "snowboard", [1] = "wingsuit", [2] = "ski", [3] = "paraglider", [5] = "speed riding",
                [7] = "a crash", [9] = "sled", [10] = "rocket wingsuit", [11] = "free fall"}
local STILL = 3.0                  -- m/s: on foot that is standing or walking (a slope reads ~1 m/s standing still)

local function find_heli()
    if heli then return end
    local why
    for _, id in ipairs(HELICOS) do
        heli, why = resteep.prop.find(id)
        if heli then break end
    end
    if not heli then resteep.log("helicopter: no model here: " .. tostring(why)) end
end

local function start()
    local p = resteep.player()
    if not p then resteep.notify("helicopter: no rider", 2) return end
    local riding = p.activity ~= ON_FOOT and (RIDING[p.activity] or ("activity " .. tostring(p.activity))) or nil
    local airborne = p.air and (p.airtime or 0) > 0.4               -- the flag flickers on slopes
    if riding or airborne or (p.speed or 0) > STILL then
        resteep.log(string.format("helicopter: not started (activity %s, speed %.1f, air %s)", tostring(p.activity),
                                  p.speed or 0, tostring(p.air)))
        resteep.notify(riding and ("helicopter: get off first (" .. riding .. "): walk, stand still, then F8 / BACK")
                       or "helicopter: stop first (standing still, on the ground)", 4)
        return
    end
    resteep.log("helicopter: started on foot (activity " .. tostring(p.activity) .. ")")
    local ok, why = resteep.rider.hold(true)
    if not ok then resteep.notify("helicopter: can't hold the rider: " .. tostring(why), 4) return end
    realistic = setting("realistic", false) == true
    v, W, hovering, grounded, lever = {0, 0, 0}, {0, 0, 0}, false, true, 0
    local c = resteep.camera()
    yaw = c and math.atan(-c.forward.x, c.forward.y) or 0
    pitch, roll, cam, cam_heading = 0, 0, nil, yaw
    heading_axes(yaw)                                    -- the helicopter comes to the rider, level, its seat on it
    org = {0, 0, 0}
    local s = body(SEAT)
    org = {p.x - s[1], p.y - s[2], p.z - s[3]}
    resteep.input.pad{}            -- puts the pad hook in, so input.read() has the real pad from now on
    find_heli()
    if heli and not rotors and spin == 0 then read_rotors() end   -- parked as the map has it: the bones at rest
    seat(true)
    watching = WATCH_CLIPS
    resteep.rider.anim_seen()                                     -- starts the recording
    pcall(resteep.hud.hide, true)                                 -- the game's HUD (activity card, prompts) goes
    on = true
    resteep.notify((realistic and "helicopter on (realistic)" or "helicopter on")
                   .. ": tilt = left stick or I J K L, turn = right stick or U O, "
                   .. (realistic and "collective lever = RT LT or Y H (stays where set; ~50 % hovers), "
                       or "up / down = RT LT or Y H, ") .. "let go = B or F8", 6)
end

-- the rider let go: in the air the pilot holds a hover there with the rotors running, on the ground it is parked
local function stop(why, on_ground)
    on = false
    seat(false)
    resteep.rider.hold(false)                -- the game takes the rider back where it is
    resteep.camera.release(0.6)
    pcall(resteep.hud.hide, false)
    hovering = org ~= nil and not on_ground
    if hovering then hold_z = org[3] end
    resteep.notify("helicopter off" .. (why and (": " .. why) or "") .. (hovering and " (it hovers there)" or ""), 3)
end

---------------------------------------------------------------------------------------------------------- frame

-- chase camera: behind along the heading (further with the helicopter: its tail is 8.7 m long), up, smoothed; the
-- heading of a helicopter on its nose or tail is kept from before
local function camera_follow(dt, p)
    if math.sqrt(R.f[1] * R.f[1] + R.f[2] * R.f[2]) > 0.25 then
        local h = math.atan(-R.f[1], R.f[2])
        local d = (h - (cam_heading or h) + math.pi) % (2 * math.pi) - math.pi
        cam_heading = (cam_heading or h) + d * math.min(1, dt / 0.3)
    end
    local hx, hy = -math.sin(cam_heading or yaw), math.cos(cam_heading or yaw)
    local back, up = heli and 24 or 14, heli and 7 or 5
    local want = {x = p.x - hx * back, y = p.y - hy * back, z = p.z + up}
    cam = cam or want
    local c = math.min(1, dt / 0.25)
    for _, k in ipairs({"x", "y", "z"}) do cam[k] = cam[k] + (want[k] - cam[k]) * c end
    local lx, ly, lz = p.x - cam.x, p.y - cam.y, p.z + 1.5 - cam.z
    local l = math.sqrt(lx * lx + ly * ly + lz * lz)
    if l > 0.1 then resteep.camera.set{x = cam.x, y = cam.y, z = cam.z, forward = {x = lx / l, y = ly / l, z = lz / l},
                                       fov = 70} end
end

local aboard_hover = false          -- the helicopter holds itself in the air, the rider still in the side door

-------------------------------------------------------------------------------------------------------------- HUD

-- A small flight HUD at the bottom centre (screen fractions; resteep.line / text / box): the heading tape on top, the
-- attitude indicator in the middle (horizon, pitch ladder every 10 degrees, bank pointer), airspeed and vertical speed
-- left, height above the sea and above the ground right; realistic adds the collective and torque bars, the g load and
-- the warnings. "+Y" of the world is taken as north.
local HUD = {x = 0.5, y = 0.875, r = 0.07, deg = 40}   -- the attitude indicator's centre and radius (of the screen's
                                                       -- height), the pitch that reaches its edge
local INK, DIM, AMBER, RED = "#FFE8F0F8", "#90E8F0F8", "#FFFFC040", "#FFFF5040"
local COMPASS = {[0] = "N", [90] = "E", [180] = "S", [270] = "W"}

-- realistic: the warnings, short
local function warnings()
    local w = {}
    if rotor.power > TORQUE_MAX then w[#w + 1] = "OVER-TORQUE" end
    if not grounded and rotor.nmin < 0.3 then w[#w + 1] = "LOW G" end
    if rotor.vrs > 0.3 then w[#w + 1] = "VORTEX RING" end
    if rotor.rbs > 0 or rotor.stall then w[#w + 1] = "BLADE STALL" end
    if len(v) > MAX_SPEED - 4 then w[#w + 1] = "VNE" end
    return w
end

local function draw_hud()
    if setting("hud", true) == false then return end
    local c = resteep.camera()
    local asp = c and c.aspect or 16 / 9
    local cx, cy, R0 = HUD.x, HUD.y, HUD.r
    local function px(dx, dy) return cx + dx / asp, cy + dy end           -- offsets in screen heights -> fractions
    local function seg(x1, y1, x2, y2, col, w)
        local a, b = px(x1, y1)
        local e, f = px(x2, y2)
        resteep.line(a, b, e, f, col, w)
    end
    resteep.box(0.5 - 0.215, 0.728, 0.43, 0.262, "#50000000")
    -- heading tape: +-40 degrees over +-0.085 of the width, ticks every 10, labels every 30
    local hd = math.abs(R.f[3]) < 0.97 and math.deg(math.atan(R.f[1], R.f[2])) or -math.deg(cam_heading or yaw)
    hd = hd % 360
    resteep.text(0.5, 0.733, string.format("%03d", math.floor(hd + 0.5) % 360), INK, 0.85)
    resteep.line(0.5, 0.758, 0.5, 0.775, AMBER, 2)
    for t = math.ceil((hd - 40) / 10) * 10, hd + 40, 10 do
        local x = 0.5 + (t - hd) / 40 * 0.085
        local deg = t % 360
        local major = deg % 30 == 0
        resteep.line(x, 0.765, x, major and 0.775 or 0.771, DIM, 1.2)
        if major then resteep.text(x, 0.777, COMPASS[deg] or string.format("%02d", deg // 10), DIM, 0.65) end
    end
    -- attitude: the horizon's normal on the screen (towards the sky, y down) is (r.z, -u.z) / cos(pitch); a line at
    -- elevation e lies (e - pitch) along it
    local nose = math.deg(math.asin(clamp(R.f[3], -1, 1)))
    local nx, ny = R.r[3], -R.u[3]
    local nl = math.sqrt(nx * nx + ny * ny)
    if nl > 1e-3 then nx, ny = nx / nl, ny / nl else nx, ny = 0, -1 end
    local k = R0 / HUD.deg
    for i = 0, 23 do                                                      -- the ring
        local a1, a2 = i / 24 * 2 * math.pi, (i + 1) / 24 * 2 * math.pi
        seg(R0 * math.cos(a1), R0 * math.sin(a1), R0 * math.cos(a2), R0 * math.sin(a2), DIM, 1)
    end
    local function rung(e, half, col, w)                                  -- a line at elevation e, cut at the ring
        local d = (e - nose) * k
        if math.abs(d) >= R0 * 0.95 then return end
        half = math.min(half, math.sqrt(R0 * R0 - d * d))
        local mx, my = nx * d, ny * d
        seg(mx - ny * half, my + nx * half, mx + ny * half, my - nx * half, col, w)
    end
    rung(0, R0, INK, 2)
    for e = -80, 80, 10 do
        if e ~= 0 then rung(e, R0 * (e % 20 == 0 and 0.45 or 0.28), e > 0 and DIM or "#90FFB070", 1) end
    end
    for _, b in ipairs({-60, -30, 0, 30, 60}) do                          -- the bank scale on top, and its pointer
        local a = math.rad(b)
        seg(R0 * math.sin(a), -R0 * math.cos(a), 1.12 * R0 * math.sin(a), -1.12 * R0 * math.cos(a), DIM, 1.2)
    end
    seg(0.8 * nx * R0, 0.8 * ny * R0, nx * R0, ny * R0, AMBER, 2.5)
    seg(-0.5 * R0, 0, -0.18 * R0, 0, AMBER, 2.5)                          -- the helicopter: wings and centre
    seg(0.18 * R0, 0, 0.5 * R0, 0, AMBER, 2.5)
    seg(-0.004, 0, 0.004, 0, AMBER, 4)
    -- left: airspeed and vertical speed; right: heights
    local lx, rx = 0.5 - 0.115, 0.5 + 0.115
    resteep.text(lx, 0.815, string.format("%.0f", len(v) * 3.6), INK, 1.4)
    resteep.text(lx, 0.858, "km/h", DIM, 0.65)
    resteep.text(lx, 0.895, string.format("VS %+.1f m/s", v[3]), INK, 0.8)
    local below = grounded and 0 or height_below(body(COM), 2000)
    if below and not grounded then below = math.max(0, below - COM[3]) end
    resteep.text(rx, 0.82, string.format("ALT %.0f m", org[3]), INK, 0.85)
    resteep.text(rx, 0.855, below and string.format("AGL %.0f m", below) or "AGL ---", INK, 0.85)
    if not realistic then return end
    local g = grounded and 1 or rotor.nmin
    resteep.text(rx, 0.895, string.format("%+.1f g", g), g < 0.3 and RED or INK, 0.8)
    -- the collective lever (0-100 %) and torque (0-120 %, a mark at 100) as bars
    local function bar(x, frac, label, col, mark)
        local top, h, w = 0.8, 0.125, 0.008
        resteep.box(x - w / 2, top, w, h, "#40FFFFFF")
        local fh = h * clamp(frac, 0, 1)
        resteep.box(x - w / 2, top + h - fh, w, fh, col)
        if mark then resteep.line(x - w, top + h * (1 - mark), x + w, top + h * (1 - mark), INK, 1.5) end
        resteep.text(x, top + h + 0.004, label, INK, 0.6)
    end
    bar(0.5 + 0.17, lever, string.format("COL %.0f%%", lever * 100), "#C0A0D8FF")
    bar(0.5 + 0.2, rotor.power / 1.2, string.format("TQ %.0f%%", rotor.power * 100),
        rotor.power > TORQUE_LIMIT - 0.005 and RED or (rotor.power > TORQUE_MAX and AMBER or "#C080F0A0"), 1 / 1.2)
    local w = warnings()
    if #w > 0 then resteep.text(0.5, 0.955, table.concat(w, "  "), RED, 0.85) end
end

local function fly(dt, pad)
    local f, r, pedal, coll = controls(pad)
    if aboard_hover then                                     -- any stick or trigger takes the controls back
        if math.abs(f) + math.abs(r) + math.abs(pedal) + math.abs(coll) > 0 then
            aboard_hover = false
            resteep.notify("helicopter: you fly again", 2)
        else
            f, r, pedal, coll = autopilot()
        end
    elseif realistic then                                    -- the player's stick: finer near the centre
        local function expo(x) return x * (EXPO + (1 - EXPO) * math.abs(x)) end
        f, r, pedal = expo(f), expo(r), expo(pedal)
    end
    crashed = false
    grounded = step_model(dt, f, r, pedal, coll)
    if crashed then aboard_hover = false end                 -- the pilot gives up after a crash
    local s = body(SEAT)
    local ok, why = resteep.rider.set_position(s[1], s[2], s[3])
    if not ok then stop(why, grounded) return end
    place_heli()
    resteep.input.pad{}                                      -- the game gets a neutral pad meanwhile
    resteep.input.capture(true)                              -- ... and no keyboard or mouse (keys still reach us)
    camera_follow(dt, {x = s[1], y = s[2], z = s[3]})
    draw_hud()
end

-- nobody flies it: the pilot holds the hover (rotors and sound go on); once it rests on the ground it is parked
local function hover(dt)
    local f, r, pedal, coll = autopilot()
    grounded = step_model(dt, f, r, pedal, coll)
    place_heli()
    if grounded and realistic then lever = 0 end
    if grounded then
        hovering = false
        resteep.log("helicopter: down on its skids by itself: parked")
    end
end

local function sound_load()
    if not (on or hovering) then return 0 end
    if realistic then                                        -- the rotor's power, the slap of its own wake and stall
        return clamp((rotor.power - P_PROFILE) / (TORQUE_MAX - P_PROFILE) + 0.4 * rotor.vrs + 0.3 * rotor.rbs, 0, 1)
    end
    return clamp(math.abs(last_coll) * 0.8 + 0.15 * len(W) + (v[3] < -4 and 0.3 or 0), 0, 1)
end

-- B / BACK / F8 while flying: on the ground it parks; in the air the first press hovers with the rider aboard, the
-- second one is the jump out (the helicopter goes on hovering alone)
local function leave_pressed()
    if grounded then aboard_hover = false stop("parked", true)
    elseif not aboard_hover then
        aboard_hover, hold_z = true, org and org[3] or hold_z
        resteep.notify("helicopter: hovering (press again to jump out, a stick to fly on)", 3)
    else aboard_hover = false stop("jumped out", false) end
end

resteep.on("key", function(k)
    if k == "F8" then if on then leave_pressed() else start() end end
end)

resteep.on("frame", function(dt)
    local pressed, pad = pad_presses()
    dt = clamp(dt, 0.001, 0.05)
    if crash_cool > 0 then crash_cool = crash_cool - dt end
    if on or hovering then set_model(setting("realistic", false) == true) end
    if hovering then hover(dt) end
    spin_rotors(dt)
    sound_update(dt, sound_load())
    if not on then
        if pressed.BACK then start() end
        return
    end
    if pressed.BACK or pressed.B then leave_pressed() if not on then return end end
    local p = resteep.player()
    if not p or p.ragdoll then stop(p and "crashed" or "no rider", grounded) return end
    if not resteep.rider.held() then stop("the rider was let go", grounded) return end
    fly(dt, pad)
    if on then seat_step() watch_clips(dt) end
end)

resteep.on("world_leave", function()
    if on then stop(nil, true) end
    hovering, heli, rotors, rotor_way, local_check = false, nil, nil, nil, nil
    aboard_hover = false
    spin, turned_main, turned_tail, org = 0, 0, 0, nil
    sound_stop()
end)
