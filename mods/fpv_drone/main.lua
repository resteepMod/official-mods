-- FPV drone, acro (rate mode): launch a drone the way the game's own drone takes off (the rider's STAND_IDLE_DRONE
-- pose, the drone rising in front of them, seen from behind the rider), then fly it first-person like a real FPV
-- quad: the sticks set how fast it turns about its own axes (Betaflight rates: RC rate, super rate, expo), nothing
-- levels it, the motors push along its top, gravity and drag do the rest. The camera is tilted up like an FPV camera.
-- Gamepad, mode 2: left stick throttle (up/down) and yaw, right stick pitch and roll; Y sets it upright where it is
-- (after a crash), B brings it back; the d-pad's left / right change the field of view, up / down the camera's tilt
-- (kept as the settings). Arming: the throttle low (in the "hover" throttle mode the stick's centre hovers, so
-- letting go arms). Keyboard fallback: SPACE/C throttle, W/S pitch, A/D roll, Q/E yaw, R upright, the arrow keys as
-- the d-pad. G (a setting) launches and brings it back. While the drone is out the rider is held where it stood and
-- the game gets no input.
-- In the game's replay (resteep.world.replay): G starts the drone where the replay's camera is, at once and without
-- the rider (the replay's rider is left alone: no hold, no pose); it flies the same, also while the replay is paused,
-- and B / G hands the picture back to the replay's camera. The replay's controls get no input meanwhile.
-- The model (Alps only for now): the game's own drone mesh (STP_V_Drone_001_GoPro, rebuilt from the player's install
-- at game start) or the mod's own quad (assets/drone.glb, tools/fpv_drone/make_drone.py), both placed by
-- assets/drone_Alpes.json in the root cell with fixed ids and parked under the ground; resteep.prop moves the one
-- the settings pick. The motor sound (sounds/motor_loop.wav, generated) follows the throttle.
-- Collision: resteep.world.spherecast / raycast (the game's collision world) when this ReSteep has them, else the
-- terrain raster (resteep.world.ground: the ground only, about 4 m apart, not trees, rocks or buildings).
-- Culling and level of detail follow the game's own camera (the rider): far from it things pop in.
local G = 9.81
local DRAG_LIN, DRAG_QUAD = 0.05, 0.025            -- per s, per m: ~160 km/h flat out at 5:1, ~70 km/h falling
local SKID = 0.04                                  -- metres between the drone's centre and the snow
local RADIUS = 0.12                                -- for the collision sweeps (the props' reach)
local CRASH_SPEED = 5.0                            -- m/s into a surface (along its normal)
local TILT_CRASH = 1.5                             -- m/s into it on its side or upside down
local RASTER_SLACK = 1.0                           -- with a real collision query: the raster only below this
local MAX_STEP = 1 / 240                           -- physics sub-step
local FOV_MIN, FOV_MAX, TILT_MIN, TILT_MAX, STEP_DEG = 60, 150, 0, 60, 5
local REPEAT_DELAY, REPEAT_EVERY = 0.4, 0.12       -- s: a d-pad button held repeats
-- the launch and the landing (s)
local SPIN_UP, RISE_END, HOVER_END, TO_FPV = 0.7, 2.1, 2.5, 0.8
local TO_THIRD, RETURN_MAX, DESCEND, SPIN_DOWN = 0.7, 3.0, 0.8, 0.6
local FAR = 25                                     -- a drone further out comes back from this far (out of view)
-- the models (resteep.prop ids from assets/drone_Alpes.json): which way their nose points, where their origin sits
-- and where its camera is (from the drone's centre: forward, up; the game's drone has its GoPro under the nose)
local MODELS = {
    game = {id = 0x2FD00001000, flip = true, lift = -SKID, park = {x = 3, y = 0, z = -5}, cam = {0.29, 0.05}},
    own = {id = 0x2FD00002000, flip = false, lift = 0, park = {x = 6, y = 0, z = -5}, cam = {0.07, 0.02}},
}
local SOUND = "sounds/motor_loop.wav"
local SOUND_RANGE = 160                            -- full volume within 40 m, silent beyond

-- The rider's drone pose: every standing idle -> the matching STAND_IDLE_DRONE clip (the names from `python -m
-- resteep anims find STAND_IDLE`): skis (ID01) to the ski pose (its _STEEP variant from the _STEEP idles), everything
-- else to the snowboard's. Those not listed here are caught when the game looks them up (resteep.rider.anim_seen).
local function drone_clip(name)
    local act, g = name:match("^(ID%d%d)_PS%d%d_(%a+)_")
    if not act or (g ~= "male" and g ~= "female") or not name:find("STAND_IDLE", 1, true) then return nil end
    if name:find("DRONE", 1, true) or name:find("BINOCULAR", 1, true) then return nil end
    if act == "ID01" then
        return "ID01_PS00_" .. g .. (name:find("STEEP", 1, true) and "_STAND_IDLE_STEEP_DRONE" or "_STAND_IDLE_DRONE")
    end
    return "ID00_PS00_" .. g .. "_STAND_IDLE_DRONE"
end

local IDLES = {}
for _, g in ipairs({"male", "female"}) do
    for ps = 0, 4 do
        local p, br = string.format("_PS%02d_", ps), ps == 4 and "breaker" or "Breaker"
        IDLES[#IDLES + 1] = "ID00" .. p .. g .. "_STAND_IDLE"
        IDLES[#IDLES + 1] = "ID01" .. p .. g .. "_STAND_IDLE_LEFT"
        IDLES[#IDLES + 1] = "ID01" .. p .. g .. "_STAND_IDLE_LEFT_STEEP"
        for k = 1, 4 do
            IDLES[#IDLES + 1] = string.format("ID00%s%s_STAND_IDLE_%s_%02d", p, g, br, k)
            IDLES[#IDLES + 1] = string.format("ID01%s%s_STAND_IDLE_%s_%02d_LEFT", p, g, br, k)
            IDLES[#IDLES + 1] = string.format("ID01%s%s_STAND_IDLE_%s_%02d_LEFT_STEEP", p, g, br, k)
        end
    end
    for k = 1, 4 do IDLES[#IDLES + 1] = string.format("ID05_PS00_%s_STAND_IDLE_%02d", g, k) end
    IDLES[#IDLES + 1] = "ID06_PS00_" .. g .. "_STAND_IDLE"
end

local posed = {}                                   -- clip -> its drone pose, while redirected

local function pose(name)
    if posed[name] then return end
    local to = drone_clip(name)
    if not to then return end
    local ok, set = pcall(resteep.rider.play_anim, name, to)   -- raises for a clip this game does not have
    if ok and set then posed[name] = to end
end

local function unpose()
    for name in pairs(posed) do pcall(resteep.rider.play_anim, name) end
    posed = {}
end

local function setting(key, default)
    local ok, v = pcall(resteep.config.get, key)
    if not ok or v == nil then return default end
    return v
end

local function store(key, value)                   -- the player's last value becomes the setting
    local ok, v = pcall(resteep.config.set, key, value)
    return ok and v or value
end

-- vectors: {x, y, z}, Z up
local function v3(x, y, z) return {x = x, y = y, z = z} end
local function add(a, b, s) s = s or 1 return v3(a.x + b.x * s, a.y + b.y * s, a.z + b.z * s) end
local function sub(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v3(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) local l = len(a) return l > 1e-9 and mul(a, 1 / l) or v3(1, 0, 0) end
local function lerp(a, b, k) return add(a, sub(b, a), k) end
local function rotate(v, axis, ang)                -- about a unit axis, right-handed (Rodrigues)
    local c, s = math.cos(ang), math.sin(ang)
    return add(add(mul(v, c), cross(axis, v), s), axis, dot(axis, v) * (1 - c))
end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function smooth(k) k = clamp(k, 0, 1) return k * k * (3 - 2 * k) end

-- the drone: position p, velocity v, its axes f (nose), r (right) and u (top) with r = f x u, the motors' output
-- thr (0..1, spooled), armed (until then it stays where it is: risen after the launch, or crashed), crashed
local state = "off"                                -- off, launch, fly, landing
local hid_hud = false                              -- the game's HUD hidden by this flight (shown again on landing)
local t0, home, spot, third = 0, nil, nil, nil     -- state start; the rider; where the drone sits; the chase view
local back = nil                                   -- the landing's path
local d = {}
local kb_thr, last_buttons, said_at, rep = 0, {}, {}, {}
local fov, tilt = 90, 25
local note, note_until = nil, 0                    -- a short on-screen note (FOV / camera angle)
local spin = 0                                     -- the motors' speed for the sound, 0..1
local motor, mute = nil, false                     -- the sound's id; no audio here (asked once per flight)
local model, model_key, parked = nil, nil, nil     -- the prop handle, which model, its parked transform
local caster_broken = false
local seen_until = 0
local replay = false                               -- this flight is in the game's replay: no rider, camera only
local last_t = 0                                   -- resteep.time() of the last frame (the replay flight's own dt)

local function say(text, s, key)                   -- a notice at most every 2 s per kind
    local now = resteep.time()
    if said_at[key or text] and now - said_at[key or text] < 2 then return end
    said_at[key or text] = now
    resteep.notify(text, s)
end

local function hover_throttle() return 1 / setting("power", 5) end

local function orthonormalize()
    d.f = unit(d.f)
    d.r = unit(cross(d.f, d.u))
    d.u = cross(d.r, d.f)
end

local function face(dir, up)                       -- nose along dir (its level part), top up
    d.f, d.u = unit(v3(dir.x, dir.y, 0)), up or v3(0, 0, 1)
    orthonormalize()
end

local function upright()                           -- level, same heading, standing still
    local h = v3(d.f.x, d.f.y, 0)
    if len(h) < 0.05 then h = v3(d.u.x, d.u.y, 0) end   -- nose straight up or down: the top says where it was going
    face(h)
    d.v, d.thr = v3(0, 0, 0), 0
end

local function floor_at(x, y)
    -- the terrain raster can be off where the rider stands (600 m in the Alps' tutorial start, 2026-11-13): the floor
    -- is the raster shifted by what it misses under the rider
    local g = resteep.world.ground(x, y)
    if g and home and home.floor then g = g + home.floor end
    return g
end

local function ground_normal(x, y)                 -- the raster's slope over 4 m
    local h = 2
    local a, b, c, e = floor_at(x + h, y), floor_at(x - h, y), floor_at(x, y + h), floor_at(x, y - h)
    if not (a and b and c and e) then return v3(0, 0, 1) end
    return unit(v3((b - a) / (2 * h), (e - c) / (2 * h), 1))
end

local function camera_yaw()
    local c = resteep.camera()
    if c and c.forward then return math.atan(c.forward.y, c.forward.x) end
    return 0
end

-- ---- the model ---------------------------------------------------------------------------------------------------

local function model_wanted()
    local m = setting("model", "game")
    if m == "off" then return nil end
    if state == "fly" and not setting("model_fpv", true) then return nil end
    return m
end

local function park()                              -- back where the world edit put it, under the ground
    if model then resteep.prop.set(model, parked and {matrix = parked} or MODELS[model_key].park) end
end

local function find_model()
    local want = setting("model", "game")
    if want == "off" then park() model, model_key = nil, nil return end
    if model and model_key == want then return end
    park()
    model, model_key, parked = nil, nil, nil
    for _, key in ipairs(want == "own" and {"own", "game"} or {"game", "own"}) do   -- the other one if it is missing
        local h, why = resteep.prop.find(MODELS[key].id)
        if h then
            local at = resteep.prop.get(h)
            model, model_key, parked = h, key, at and at.matrix
            if key ~= want then resteep.log("drone: no " .. want .. " model here, the " .. key .. " one flies") end
            return
        end
        resteep.log("drone: no " .. key .. " model here (the Alps only; built at game start): " .. tostring(why))
    end
end

local function show_model()
    if not model then return end
    if not model_wanted() then park() return end
    local m = MODELS[model_key]
    local r, f, u = d.r, d.f, d.u
    if m.flip then r, f = mul(r, -1), mul(f, -1) end
    local o = add(d.p, u, m.lift)
    local ok, why = resteep.prop.set(model, {matrix = {r.x, r.y, r.z, 0, f.x, f.y, f.z, 0, u.x, u.y, u.z, 0,
                                                       o.x, o.y, o.z, 1}})
    if not ok then resteep.log("drone: the model stays behind: " .. tostring(why)) model = nil end
end

-- ---- the sound ---------------------------------------------------------------------------------------------------

local function sound(dt, target)
    spin = spin + (target - spin) * math.min(1, dt / 0.12)
    if mute or not setting("sound", true) then
        if motor then resteep.sound.stop(motor) motor = nil end
        return
    end
    local at = {x = d.p.x, y = d.p.y, z = d.p.z}
    local vol = setting("volume", 0.7) * clamp(spin * 1.6, 0, 1) * (0.5 + 0.5 * spin)
    local pitch = clamp(0.45 + 1.15 * spin + 0.004 * len(d.v or v3(0, 0, 0)), 0.25, 4)
    if not motor then
        if spin < 0.01 then return end
        local why
        motor, why = resteep.sound.play(SOUND, {loop = true, volume = vol, pitch = pitch, at = at, range = SOUND_RANGE})
        if not motor then
            resteep.log("drone: no motor sound: " .. tostring(why))
            mute = true                            -- e.g. no audio device: not every frame
        end
        return
    end
    resteep.sound.set(motor, {loop = true, volume = vol, pitch = pitch, at = at, range = SOUND_RANGE})
end

local function silence()
    if motor then resteep.sound.stop(motor) motor = nil end
    spin = 0
end

-- ---- the camera --------------------------------------------------------------------------------------------------

local function fpv_view()
    local a = math.rad(tilt)                       -- the FPV camera looks up from the nose
    local cam = MODELS[model_key or "own"].cam
    return {p = add(add(d.p, d.f, cam[1]), d.u, cam[2]), f = rotate(d.f, d.r, a), u = rotate(d.u, d.r, a), fov = fov}
end

local function third_view()                        -- from where the game's camera was, on the rider and the drone
    local look = lerp(v3(home.x, home.y, home.z + 1.2), d.p, 0.6)
    local f = unit(sub(look, third.p))
    local r = unit(cross(f, v3(0, 0, 1)))
    return {p = third.p, f = f, u = cross(r, f), fov = third.fov}
end

local function blend_view(a, b, k)
    k = smooth(k)
    local f = unit(lerp(a.f, b.f, k))
    local u = unit(lerp(a.u, b.u, k))
    return {p = lerp(a.p, b.p, k), f = f, u = u, fov = a.fov + (b.fov - a.fov) * k}
end

local function put_camera(v)
    resteep.camera.set{x = v.p.x, y = v.p.y, z = v.p.z, forward = v.f, up = v.u, fov = v.fov, duration = 0.6}
end

-- ---- d-pad: field of view and camera tilt ------------------------------------------------------------------------

local function repeated(name, down, now)           -- a press, then repeats while held
    if not down then rep[name] = nil return false end
    local nxt = rep[name]
    if not nxt then rep[name] = now + REPEAT_DELAY return true end
    if now >= nxt then rep[name] = now + REPEAT_EVERY return true end
    return false
end

local function stepped(v, dir, lo, hi)             -- the next multiple of STEP_DEG that way
    local n = dir > 0 and (math.floor(v / STEP_DEG + 1e-6) + 1) or (math.ceil(v / STEP_DEG - 1e-6) - 1)
    return clamp(n * STEP_DEG, lo, hi)
end

local function show_note(text)
    note, note_until = text, resteep.time() + 1.5
end

local function dpad(pad)
    local now, held = resteep.time(), {}
    for _, b in ipairs(pad and pad.buttons or {}) do held[b] = true end
    for _, b in ipairs({"LEFT", "RIGHT", "UP", "DOWN"}) do
        if repeated(b, held[b] or resteep.held(b), now) then
            if b == "LEFT" or b == "RIGHT" then
                fov = store("fov", stepped(fov, b == "RIGHT" and 1 or -1, FOV_MIN, FOV_MAX))
                show_note(string.format("FOV %d\194\176", math.floor(fov + 0.5)))
            else
                tilt = store("camera_angle", stepped(tilt, b == "UP" and 1 or -1, TILT_MIN, TILT_MAX))
                show_note(string.format("CAMERA ANGLE %d\194\176", math.floor(tilt + 0.5)))
            end
        end
    end
end

-- ---- launch and landing ------------------------------------------------------------------------------------------

-- the game's replay, when it plays or is paused: a table, else nil (also on a ReSteep without resteep.world.replay)
local function in_replay()
    local f = resteep.world.replay
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f)
    return ok and type(r) == "table" and r or nil
end

local function hold_input()                        -- the game gets nothing while the drone is out
    resteep.input.capture(true)
    resteep.input.pad{}
end

-- in a replay: the drone takes the replay camera's place (its FPV camera where that camera is, its nose the same way,
-- level), disarmed and hovering there until the throttle arms it; nothing of the rider is touched
local function launch_replay()
    local c = resteep.camera()
    if not c or not c.forward then resteep.notify("drone: no camera to start from", 2) return end
    replay = true
    home = {x = c.x, y = c.y, z = c.z}             -- the range counts from here
    hid_hud = resteep.hud.hide(true) == true
    local fwd = v3(c.forward.x, c.forward.y, 0)
    if len(fwd) < 0.05 then fwd = v3(math.cos(camera_yaw()), math.sin(camera_yaw()), 0) end
    face(fwd)
    fov, tilt, mute = setting("fov", 90), setting("camera_angle", 25), false
    find_model()
    local cam = MODELS[model_key or "own"].cam
    d.p = add(add(v3(c.x, c.y, c.z), d.f, -cam[1]), d.u, -cam[2])
    local floor = floor_at(d.p.x, d.p.y)
    if floor and d.p.z < floor + SKID then d.p.z = floor + SKID end
    d.v, d.thr, d.armed, d.crashed = v3(0, 0, 0), 0, false, false
    kb_thr, last_buttons, rep = hover_throttle(), {}, {}
    state, t0, last_t = "fly", resteep.time(), resteep.time()
    resteep.notify("drone: up in the replay (throttle low arms it; B or G gives the replay its camera back)", 4)
end

local function launch()
    if in_replay() then return launch_replay() end
    local p = resteep.player()
    if not p or not p.real then resteep.notify("drone: no rider", 2) return end
    -- in the air only after a real moment there, and never on foot: the flag flickers standing on a slope
    if p.air and (p.airtime or 0) > 0.4 and p.activity ~= 6 then resteep.notify("drone: land first", 2) return end
    home = {x = p.x, y = p.y, z = p.z}
    local g = resteep.world.ground(p.x, p.y)
    home.floor = g and (p.z - g) or nil
    local ok, why = resteep.rider.hold(true)
    if not ok then resteep.notify("drone: " .. tostring(why), 3) return end
    posed = {}
    for _, name in ipairs(IDLES) do pose(name) end
    if next(posed) == nil then resteep.log("drone: no launch pose on this game build") end
    if resteep.rider.anim_seen then resteep.rider.anim_seen() end   -- starts the recording: its idles get posed too
    seen_until = resteep.time() + 10
    -- the game's HUD off while flying (the activity card, challenge markers and prompts): only the drone's view
    hid_hud = resteep.hud.hide(true) == true
    local c = resteep.camera()
    local yaw = camera_yaw()
    local fwd, right = v3(math.cos(yaw), math.sin(yaw), 0), v3(math.sin(yaw), -math.cos(yaw), 0)
    third = {p = c and v3(c.x, c.y, c.z) or add(v3(home.x, home.y, home.z + 1.8), fwd, -3.5), fov = c and c.fov or 60}
    spot = add(add(v3(home.x, home.y, 0), fwd, 1.4), right, 0.5)
    spot.z = (floor_at(spot.x, spot.y) or home.z) + SKID
    face(mul(fwd, -1))                             -- it starts facing the rider, then turns away as it rises
    d.p, d.v, d.thr = v3(spot.x, spot.y, spot.z), v3(0, 0, 0), 0
    d.armed, d.crashed = false, false
    d.yaw0, d.yaw1 = yaw + math.pi, yaw
    fov, tilt, mute = setting("fov", 90), setting("camera_angle", 25), false
    kb_thr, last_buttons, rep = hover_throttle(), {}, {}
    find_model()
    state, t0 = "launch", resteep.time()
    resteep.notify("drone: launching", 2)
end

local function finish()                            -- the drone is back: everything to the game again
    silence()
    park()
    if hid_hud then resteep.hud.hide(false) hid_hud = false end
    resteep.camera.release(0.6)
    if not replay then
        unpose()
        resteep.rider.hold(false)
    end
    replay = false
    state = "off"
end

local function land()
    if state == "off" or state == "landing" then return end
    if replay then                                 -- no rider to fly back to: the replay's camera takes over again
        finish()
        resteep.notify("drone: back to the replay", 2)
        return
    end
    back = {from = fpv_view(), t_cam = state == "fly" and TO_THIRD or 0}
    state, t0 = "landing", resteep.time()
    resteep.notify("drone: coming back", 2)
end

local function launching(t, dt)
    local k = smooth((t - SPIN_UP) / (RISE_END - SPIN_UP))
    d.p.z = spot.z + 1.7 * k                       -- rises in front of the rider, as the game's drone intro does
    local yaw = d.yaw0 + (d.yaw1 - d.yaw0) * k     -- and turns away from them
    face(v3(math.cos(yaw), math.sin(yaw), 0))
    sound(dt, t < SPIN_UP and 0.35 * t / SPIN_UP or 0.35 + 0.15 * k)
    show_model()
    if t < HOVER_END then
        put_camera(third_view())
    else
        put_camera(blend_view(third_view(), fpv_view(), (t - HOVER_END) / TO_FPV))
    end
    if t >= HOVER_END + TO_FPV then
        state = "fly"
        resteep.notify("drone: up (throttle low arms it; B or G brings it back; d-pad: FOV / camera angle)", 4)
    end
end

local function landing(t, dt)
    if t < back.t_cam then                         -- the camera goes back to the rider first; the drone hovers
        put_camera(blend_view(back.from, third_view(), t / back.t_cam))
        sound(dt, d.armed and 0.4 or 0)
        show_model()
        return
    end
    if not back.path then                          -- then it flies back (from out of view if it was far)
        local to = add(spot, v3(0, 0, 1.4))
        local dir = sub(d.p, to)
        if len(dir) > FAR then d.p = add(to, unit(dir), FAR) d.p.z = math.max(d.p.z, to.z + 4) end
        back.path = {a = v3(d.p.x, d.p.y, d.p.z), b = to, t = t, dur = clamp(len(sub(d.p, to)) / 8, 0.8, RETURN_MAX)}
    end
    local w = back.path
    local k = (t - w.t) / w.dur
    local d2 = (t - w.t - w.dur) / DESCEND
    local d3 = (t - w.t - w.dur - DESCEND) / SPIN_DOWN
    local was = d.p
    if k < 1 then
        d.p = lerp(w.a, w.b, smooth(k))
        local go = sub(d.p, was)
        if len(v3(go.x, go.y, 0)) > 1e-4 then face(go) end
    else
        d.p = lerp(w.b, spot, smooth(d2))
    end
    d.v = mul(sub(d.p, was), 1 / math.max(dt, 1e-3))
    sound(dt, d3 < 0 and 0.45 or 0.45 * (1 - clamp(d3, 0, 1)))
    show_model()
    put_camera(third_view())
    if d3 >= 1 then
        finish()
        resteep.notify("drone: back", 2)
    end
end

-- ---- flying ------------------------------------------------------------------------------------------------------

-- Betaflight rates: stick -1..1 -> degrees per second (expo first, then RC rate, then super rate on the raw stick)
local function rate(x)
    local dz = setting("deadzone", 0.05)
    local a = math.abs(x)
    if a <= dz then return 0 end
    x = (a - dz) / (1 - dz) * (x < 0 and -1 or 1)
    a = math.abs(x)
    local expo = setting("expo", 0)
    if expo > 0 then x = x * a ^ 3 * expo + x * (1 - expo) end
    local r = 200 * setting("rc_rate", 1.0) * x
    local super = setting("super_rate", 0.7)
    if super > 0 then r = r / (1 - math.min(a * super, 0.99)) end
    return clamp(r, -1998, 1998)
end

local function key_axis(pos, neg) return (resteep.held(pos) and 1 or 0) - (resteep.held(neg) and 1 or 0) end

-- the sticks: throttle 0..1 and the rates (degrees per second) roll right, pitch nose down, yaw right
local function sticks(pad, dt)
    local roll, pitch, yaw = key_axis("D", "A"), key_axis("W", "S"), key_axis("E", "Q")
    kb_thr = clamp(kb_thr + key_axis("SPACE", "C") * 0.8 * dt, 0, 1)
    local thr = kb_thr
    if pad then
        local ty, py = pad.ly, pad.ry
        if setting("mode", "2") == "1" then ty, py = pad.ry, pad.ly end      -- mode 1: throttle on the right
        roll, pitch, yaw = roll + pad.rx, pitch + py, yaw + pad.lx
        local how = setting("throttle", "hover")
        if how == "trigger" then
            thr = pad.rt
        elseif how == "stick" then
            thr = (ty + 1) / 2
        else                                       -- hover: the stick's centre (and its dead zone) hovers
            local dz, hover = setting("deadzone", 0.05), hover_throttle()
            local y = math.abs(ty) <= dz and 0 or (ty - dz * (ty < 0 and -1 or 1)) / (1 - dz)
            thr = y < 0 and (y + 1) * hover or hover + y * (1 - hover)
        end
    end
    return clamp(thr, 0, 1), rate(clamp(roll, -1, 1)), rate(clamp(pitch, -1, 1)), rate(clamp(yaw, -1, 1))
end

local function crash(speed)
    d.armed, d.crashed, d.v, d.thr = false, true, v3(0, 0, 0), 0
    say(string.format("drone: crashed (%.0f km/h): Y sets it upright", speed * 3.6), 3, "crash")
end

-- the drone against a surface (normal n) it reached: a crash when it hits hard, or on its side; else it slides
local function touch(n, h)
    local into = -dot(d.v, n)
    if into > CRASH_SPEED or (into > TILT_CRASH and dot(d.u, n) < 0.5) then
        crash(math.max(into, len(d.v)))
        return true
    end
    if into > 0 then d.v = add(d.v, n, into) end
    local k = 1 - math.min(1, 4 * h)                -- friction while it rests on it
    if dot(d.u, n) > 0.5 and d.thr < hover_throttle() then d.v = mul(d.v, k) end
    return false
end

-- a sweep along the frame's motion through the game's collision world, when this ReSteep has one
local function caster()
    local w = resteep.world
    if caster_broken then return nil end
    if type(w.spherecast) == "function" then return "sphere" end
    if type(w.raycast) == "function" then return "ray" end
    return nil
end

-- the drone's own model is left out of the queries (its collision, if it has any, moves with it)
local function cast_opts() return model and {ignore = model} or nil end

-- the hit's contact point and normal; nil: nothing in the way; nil, true: not asked this time (a menu, the 64 casts
-- per frame, a world still loading: the answer is nil + why), then the raster decides
local function sweep(a, b)
    local how, ok, hit, why = caster(), false, nil, nil
    if not how then return nil end
    local dir = sub(b, a)
    if len(dir) < 1e-3 then return nil end         -- (the query wants 1 mm at least)
    if how == "sphere" then
        ok, hit, why = pcall(resteep.world.spherecast, a, b, RADIUS, cast_opts())
    else
        local e = add(b, unit(dir), RADIUS)        -- one radius past the new place
        ok, hit, why = pcall(resteep.world.raycast, a.x, a.y, a.z, e.x, e.y, e.z, cast_opts())
    end
    if not ok then
        caster_broken = true
        resteep.log("drone: the collision query failed, the terrain raster only: " .. tostring(hit))
        return nil
    end
    if hit == nil and why then return nil, true end
    if type(hit) ~= "table" or not hit.x then return nil end
    local n = (hit.nx and v3(hit.nx, hit.ny, hit.nz)) or mul(unit(dir), -1)
    return v3(hit.x, hit.y, hit.z), unit(n)
end

local function step(h, thr, roll, pitch, yaw, raster)
    d.thr = d.thr + (thr - d.thr) * math.min(1, h / 0.03)          -- the motors spool in ~30 ms
    local w = add(add(mul(d.f, math.rad(roll)), d.r, -math.rad(pitch)), d.u, -math.rad(yaw))
    local wl = len(w)
    if wl > 1e-6 then
        local ax, ang = mul(w, 1 / wl), wl * h
        d.f, d.r, d.u = rotate(d.f, ax, ang), rotate(d.r, ax, ang), rotate(d.u, ax, ang)
    end
    local a = mul(d.u, setting("power", 5) * G * d.thr)
    a.z = a.z - G
    a = add(a, d.v, -(DRAG_LIN + DRAG_QUAD * len(d.v)))
    d.v = add(d.v, a, h)
    d.p = add(d.p, d.v, h)
    local floor = floor_at(d.p.x, d.p.y)
    if not floor then return end
    -- the raster is approximate (4 m apart): only the ground, and the surface between its samples is a guess. With
    -- a collision query it is a safety net deep down; without one the drone touches it, and only hitting it hard
    -- (along its slope's normal, not just fast over it) is a crash
    local limit = raster and floor + SKID or floor - RASTER_SLACK
    if d.p.z < limit then
        d.p.z = raster and limit or floor + SKID
        if raster then
            if touch(ground_normal(d.p.x, d.p.y), h) then return end
        elseif d.v.z < 0 then
            d.v.z = 0
        end
    end
end

local function pressed(pad)                        -- buttons that went down this frame
    local now, out = {}, {}
    for _, b in ipairs(pad and pad.buttons or {}) do
        now[b] = true
        if not last_buttons[b] then out[b] = true end
    end
    last_buttons = now
    return out
end

local function floor_below(p)                      -- the z of what is under p (500 m at most), nil: unknown
    if caster() then
        local ok, hit, why = pcall(resteep.world.raycast, p.x, p.y, p.z, p.x, p.y, p.z - 500, cast_opts())
        if ok and type(hit) == "table" and hit.z then return hit.z end
        if ok and hit == nil and not why then return nil end
    end
    return floor_at(p.x, p.y)
end

local function osd(thr, pad)
    local floor = floor_below(d.p)
    local alt = floor and math.max(0, d.p.z - floor - SKID) or 0     -- (on the snow: 0, not "-0")
    local status = d.crashed and "CRASHED (Y)" or d.armed and "ARMED"
        or (thr > hover_throttle() + 0.02 and "THROTTLE DOWN TO ARM" or "DISARMED")
    local color = d.armed and "#FFFFFF" or "#FF5050"
    resteep.text(0.5, 0.86, string.format("%s   %3d%%   %3.0f km/h   %4.0f m%s", status, math.floor(d.thr * 100 + 0.5),
                                          len(d.v) * 3.6, alt, pad and "" or "   NO GAMEPAD (keyboard)"), color, 1)
end

local function fly(dt, pad)
    local hit = pressed(pad)
    if hit.B then land() return end
    if hit.Y or resteep.held("R") then
        upright()
        if d.crashed then d.crashed = false end
        local floor = floor_at(d.p.x, d.p.y)
        if floor and d.p.z < floor + SKID then d.p.z = floor + SKID end
        d.armed = false
    end
    dpad(pad)
    local thr, roll, pitch, yaw = sticks(pad, dt)
    if not d.armed and not d.crashed and thr <= hover_throttle() + 0.02 then
        d.armed, d.thr = true, thr                -- the motors start at the stick: no dip
        say("drone: armed", 1, "arm")
    end
    if d.armed then
        local from = v3(d.p.x, d.p.y, d.p.z)
        local raster = caster() == nil
        local n = math.max(1, math.ceil(math.min(dt, 0.1) / MAX_STEP))
        local h = math.min(dt, 0.1) / n
        for _ = 1, n do
            step(h, thr, roll, pitch, yaw, raster)
            if not d.armed then break end
        end
        if d.armed and not raster then
            local at, nrm = sweep(from, d.p)
            if at then
                d.p = add(at, nrm, RADIUS)
                touch(nrm, math.min(dt, 0.1))
            elseif nrm then                        -- not asked this frame: the raster's contact instead
                local floor = floor_at(d.p.x, d.p.y)
                if floor and d.p.z < floor + SKID then
                    d.p.z = floor + SKID
                    touch(ground_normal(d.p.x, d.p.y), math.min(dt, 0.1))
                end
            end
        end
    end
    local dx, dy = d.p.x - home.x, d.p.y - home.y
    local range, dist = setting("range", 300), math.sqrt(dx * dx + dy * dy)
    if dist > range then
        local out = v3(dx / dist, dy / dist, 0)
        d.p.x, d.p.y = home.x + out.x * range, home.y + out.y * range
        local vo = dot(d.v, out)
        if vo > 0 then d.v = add(d.v, out, -vo) end
        say("drone: out of range", 1, "range")
    end
    sound(dt, d.armed and (0.12 + 0.88 * d.thr) or 0)
    show_model()
    put_camera(fpv_view())
    osd(thr, pad)
end

local function watch_poses()                       -- the idles the game looks up get the drone pose too
    local seen = resteep.rider.anim_seen and resteep.rider.anim_seen()
    if type(seen) ~= "table" then return end
    for _, name in ipairs(seen) do
        if resteep.time() < seen_until and not posed[name] and drone_clip(name) then
            resteep.log("drone: the rider plays " .. name .. " -> " .. drone_clip(name))
        end
        pose(name)
    end
end

-- The drone poses looked up in the game's memory as soon as the rider is in the world (resteep.rider.preload_anim,
-- ReSteep's newer overlays): set at G, the search took ~2.4 s and the rider took the pose after the drone was up.
-- Again after a load (the rider gone a moment), once per world; a clip that world has not loaded is just not found.
local preloaded = false
local function preload_poses()
    local p = resteep.player()
    if not p or not p.real then preloaded = false return end
    if preloaded then return end
    preloaded = true
    if type(resteep.rider.preload_anim) ~= "function" then return end
    local done = {}
    for _, name in ipairs(IDLES) do
        local to = drone_clip(name)
        if to and not done[to] then
            done[to] = true
            pcall(resteep.rider.preload_anim, to)
        end
    end
end

resteep.on("frame", function(dt)
    if state == "off" then
        if not replay then preload_poses() end
        return
    end
    if replay then
        if not in_replay() then                    -- the replay ended (or was left): the game's camera again
            finish()
            resteep.notify("drone: the replay ended", 2)
            return
        end
        local now = resteep.time()                 -- its own clock: the replay's world may stand still
        dt, last_t = clamp(now - last_t, 0, 0.1), now
    end
    hold_input()
    local pad = resteep.input.read()
    if note and resteep.time() < note_until then resteep.text(0.5, 0.80, note, "#FFFFFF", 1.4) end
    if state ~= "landing" and not replay then watch_poses() end
    local t = resteep.time() - t0
    if state == "launch" then
        launching(t, dt)
    elseif state == "fly" then
        fly(dt, pad)
    elseif state == "landing" then
        landing(t, dt)
    end
end)

resteep.on("key", function(key)
    if key ~= setting("launch", "G") then return end
    if state == "off" then launch() else land() end
end)

resteep.on("config_change", function(key, value)
    if key == "fov" then fov = value elseif key == "camera_angle" then tilt = value end
    if key == "model" and state ~= "off" then find_model() end
end)

resteep.on("world_leave", function() if state ~= "off" then finish() end end)
resteep.log("FPV drone (acro): G launches it (stand still), G again brings it back")
