-- Helicopter mode (docs/todo/10-helicopter.md, route A). F8 (or the pad's BACK) starts and ends it. The mod holds the
-- rider (resteep.rider.hold: the trainer's Fly + noclip, so the game's physics and collision leave it alone) and
-- moves it every frame with resteep.rider.set_position, from a flight model in Lua; the game's own helicopter
-- (STP_Helico, the Alps' intro helicopter, moved with resteep.prop) flies with the rider in its open side door; a
-- chase camera follows. Two flight models (the setting "realistic"):
-- - arcade (default): the disc tilts with the stick and springs back, the heading turns with the pedals, released
--   collective holds the height; it never tips over;
-- - realistic: a rigid body (orientation as three axis vectors, no angles: no gimbal lock) with the rotor's thrust
--   along its own up axis, cyclic and pedals as torques against the rotor's damping, gravity, drag per body axis,
--   ground effect and a weathervaning tail: it loops and rolls, and upside down the thrust pushes it down.
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
-- realistic (per unit of mass: accelerations)
local THRUST_RANGE = 1.25          -- collective -1..1: thrust (1 + 1.25 c) g along the body's up axis: -0.25 .. 2.25 g
local CYCLIC = 7.0                 -- rad/s^2 at full stick (pitch, roll)
local PEDAL = 4.5                  -- rad/s^2 at full pedal
local DAMP_ROT = {2.6, 2.6, 2.4}   -- 1/s: the rotor's damping of pitch, roll, yaw rates (top rate = torque / damping)
local DRAG = {0.006, 0.0022, 0.02} -- quadratic drag along the body's right, nose and up axes (the disc resists most)
local HEAVE = 0.6                  -- 1/s: linear damping along the up axis (the rotor's inflow): climbs and sinks settle
local LEVEL = 5.0                  -- rad/s^2 per rad of tilt: the assist's levelling, scaled by the "assist" setting
local VANE = 0.03                  -- yaw torque per m/s of sideslip (the tail fin)
local GROUND_EFFECT = 0.08         -- up to +8 % thrust with the skids on the ground, gone at a rotor's width (10 m)
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

-- Sound: the mod's own loops (resteep.sound; synthesised by tools/sound/rotor_loop.py, no game audio): the turbine
-- and tail rotor (rotor_turbine.wav) and the main rotor's blade slap (rotor_slap.wav, 3 blades at the drop scenes'
-- 2.78 turns a second), mixed by rotor speed and load; rotor_loop.wav (both in one) when the layers are missing.
local SOUND_RANGE = 500
local MIX = 0.45                   -- the layers' overall level (the player: "very loud" at 0.9 each, 2026-11-15)
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
local start_z = 0
local crash_cool = 0               -- s: after a crash, the next one is not reported
local last_coll = 0                -- the collective last used (the sound's load)
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
local sounds = {}                  -- {turbine = id, slap = id} or {loop = id}
local sound_failed = false         -- no sound could start (no audio device): not tried again every frame
local cam_prev                     -- the camera's position last frame (the Doppler shift)

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end

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
    if sounds.turbine or sounds.loop or sound_failed then return end
    local at = org and body(HUB) or {0, 0, 0}
    local where = {x = at[1], y = at[2], z = at[3]}
    local function play(file) return resteep.sound.play(file, {loop = true, volume = 0, range = SOUND_RANGE, at = where}) end
    local t, why = play("sounds/rotor_turbine.wav")
    local s = t and play("sounds/rotor_slap.wav")
    if t and s then sounds = {turbine = t, slap = s} return end
    if t then resteep.sound.stop(t) end
    local l, why2 = play("sounds/rotor_loop.wav")
    if l then sounds = {loop = l} return end
    sound_failed = true
    resteep.log("helicopter: no rotor sound: " .. tostring(why2 or why))
end

local function sound_stop()
    for _, id in pairs(sounds) do resteep.sound.stop(id) end
    sounds = {}
end

-- volume and pitch from the rotor's speed and load, a Doppler shift from the helicopter's speed towards the camera
local function sound_update(dt, load)
    if spin <= 0 or not org then sound_stop() return end
    sound_start()
    local at = body(HUB)
    local doppler = 1
    local c = resteep.camera()
    if c then
        local cv = cam_prev and {(c.x - cam_prev[1]) / dt, (c.y - cam_prev[2]) / dt, (c.z - cam_prev[3]) / dt}
                   or {0, 0, 0}
        cam_prev = {c.x, c.y, c.z}
        local to = {at[1] - c.x, at[2] - c.y, at[3] - c.z}
        local d = len(to)
        if d > 1 then
            local away = dot(add(v, cv, -1), to) / d                      -- m/s the source moves away from the ear
            doppler = clamp(SPEED_OF_SOUND / (SPEED_OF_SOUND + away), 0.8, 1.25)
        end
    end
    local where = {x = at[1], y = at[2], z = at[3]}
    local vol = MIX * setting("volume", 60) / 100              -- two layers at once: the mix keeps them moderate
    local spool = 0.45 + 0.55 * spin                                      -- the turbine winds up with the rotor
    local function set(id, volume, p)
        resteep.sound.set(id, {loop = true, volume = clamp(volume, 0, 1), range = SOUND_RANGE, at = where,
                               pitch = clamp(p * doppler, 0.25, 4)})
    end
    if sounds.loop then set(sounds.loop, vol * spin, spool * (0.9 + 0.2 * load)) return end
    if sounds.turbine then set(sounds.turbine, vol * (0.25 + 0.75 * spin) * spin, spool * (0.97 + 0.06 * load)) end
    if sounds.slap then set(sounds.slap, vol * spin * spin * (0.35 + 0.65 * load), math.max(0.3, spin) * (0.95 + 0.1 * load)) end
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

-- the helicopter's pilot while nobody flies it: level, no drift, the height it was left at (stick values, as a
-- player would give them)
local function autopilot()
    if not realistic then                                 -- arcade: lean against the drift, hold the height
        local fh, rh = unit({R.f[1], R.f[2], 0}), unit({R.r[1], R.r[2], 0})
        return clamp(-dot(v, fh) / 12, -1, 1), clamp(-dot(v, rh) / 12, -1, 1), 0,
               clamp(-(org[3] - hold_z) / 20, -0.5, 0.5)
    end
    -- the disc's up axis wanted: level, tilted against the drift (at most ~20 degrees)
    local want = unit({clamp(-0.06 * v[1], -0.35, 0.35), clamp(-0.06 * v[2], -0.35, 0.35), 1})
    local k = cross(R.u, want)
    local angle = math.atan(len(k), dot(R.u, want))                         -- how far off, 0..pi
    k = len(k) > 1e-3 and unit(k) or R.f                                    -- upside down: roll over
    local ax = 6 * angle * dot(k, R.r) - W[1]
    local ay = 6 * angle * dot(k, R.f) - W[2]
    local az = -1.5 * W[3]
    local coll = -1                                                         -- on its side or upside down: no push
    if R.u[3] > 0.3 then                                                    -- downwards; upright: hold the height
        local need = (G + clamp(-0.8 * (org[3] - hold_z) - 1.6 * v[3], -6, 6)) / R.u[3]
        coll = clamp((need / G - 1) / THRUST_RANGE, -1, 1)
    end
    return clamp(-ax / CYCLIC, -1, 1), clamp(ay / CYCLIC, -1, 1), clamp(-az / PEDAL, -1, 1), coll
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
    crash_cool = 2
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

-- realistic: one step of the rigid body (dt small)
local function rigid_step(dt, f, r, pedal, coll, assist, sens, ground_h)
    -- thrust along the body's up axis, more near the ground (ground effect)
    local thrust = G * (1 + coll * THRUST_RANGE)
    if ground_h then thrust = thrust * (1 + GROUND_EFFECT * clamp(1 - ground_h / 10, 0, 1)) end
    if grounded and coll <= 0.05 then thrust = math.min(thrust, 0.95 * G) end   -- on its skids: flat until pulled
    local acc = {R.u[1] * thrust, R.u[2] * thrust, R.u[3] * thrust - G}
    -- drag per body axis (quadratic)
    local vb = {dot(v, R.r), dot(v, R.f), dot(v, R.u)}
    for i, axis in ipairs({R.r, R.f, R.u}) do acc = add(acc, axis, -DRAG[i] * math.abs(vb[i]) * vb[i]) end
    acc = add(acc, R.u, -HEAVE * vb[3])
    v = add(v, acc, dt)
    org = add(org, v, dt)
    -- torques: cyclic and pedals against the rotor's damping; the assist levels the disc while the stick is centred;
    -- the tail fin turns the nose into the wind
    local alpha = {-CYCLIC * sens * f, CYCLIC * sens * r, -PEDAL * sens * pedal}
    local lv = cross(R.u, {0, 0, 1})                          -- the axis that brings the up axis to the vertical
    local centred = 1 - clamp(math.max(math.abs(f), math.abs(r)), 0, 1)
    alpha[1] = alpha[1] + assist * centred * LEVEL * dot(lv, R.r)
    alpha[2] = alpha[2] + assist * centred * LEVEL * dot(lv, R.f)
    alpha[3] = alpha[3] - VANE * vb[1] * clamp(math.abs(vb[2]) / 10, 0, 1)
    for i = 1, 3 do W[i] = W[i] + (alpha[i] - (DAMP_ROT[i] + assist * 1.5) * W[i]) * dt end
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
    local assist = setting("assist", 50) / 100
    local sens = setting("sensitivity", 100) / 100
    local ground_h = height_below(body(COM), 12)
    if ground_h then ground_h = math.max(0, ground_h - COM[3]) end
    local from = body(COM)
    local n = math.max(1, math.ceil(dt * 120 - 1e-9))
    for _ = 1, n do rigid_step(dt / n, f, r, pedal, coll, assist, sens, ground_h) end
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
    if want then W = {0, 0, 0} else yaw, pitch, roll = math.atan(-R.f[1], R.f[2]), 0, 0 end
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
    v, W, hovering, grounded = {0, 0, 0}, {0, 0, 0}, false, true
    local c = resteep.camera()
    yaw = c and math.atan(-c.forward.x, c.forward.y) or 0
    pitch, roll, cam, cam_heading, start_z = 0, 0, nil, yaw, p.z
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
                   .. "up / down = RT LT or Y H, let go = B or F8", 6)
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

local function fly(dt, pad)
    local f, r, pedal, coll = controls(pad)
    if aboard_hover then                                     -- any stick or trigger takes the controls back
        if math.abs(f) + math.abs(r) + math.abs(pedal) + math.abs(coll) > 0 then
            aboard_hover = false
            resteep.notify("helicopter: you fly again", 2)
        else
            f, r, pedal, coll = autopilot()
        end
    end
    grounded = step_model(dt, f, r, pedal, coll)
    local s = body(SEAT)
    local ok, why = resteep.rider.set_position(s[1], s[2], s[3])
    if not ok then stop(why, grounded) return end
    place_heli()
    resteep.input.pad{}                                      -- the game gets a neutral pad meanwhile
    resteep.input.capture(true)                              -- ... and no keyboard or mouse (keys still reach us)
    camera_follow(dt, {x = s[1], y = s[2], z = s[3]})
    resteep.text(0.5, 0.9, string.format("HELI%s  %+.0f m  %3.0f km/h  climb %+.1f m/s%s", realistic and " R" or "",
                                         s[3] - start_z, len(v) * 3.6, v[3],
                                         R.u[3] < 0 and "  INVERTED" or ""), "#FFFFFF", 1.1)
end

-- nobody flies it: the pilot holds the hover (rotors and sound go on); once it rests on the ground it is parked
local function hover(dt)
    local f, r, pedal, coll = autopilot()
    grounded = step_model(dt, f, r, pedal, coll)
    place_heli()
    if grounded then
        hovering = false
        resteep.log("helicopter: down on its skids by itself: parked")
    end
end

local function sound_load()
    if not (on or hovering) then return 0 end
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
