-- FPV drone, acro (rate mode): launch a drone the way the game's own drone takes off (the rider's STAND_IDLE_DRONE
-- pose, the drone rising beside them), then fly it first-person like a real FPV quad: the sticks set how fast it
-- turns about its own axes (Betaflight rates: RC rate, super rate, expo), nothing levels it, the motors push along
-- its top, gravity and drag do the rest. The camera is tilted up like an FPV camera.
-- Gamepad, mode 2: left stick throttle (up/down) and yaw, right stick pitch and roll; Y sets it upright where it is
-- (after a crash), B brings it back. Arming: the throttle low (in the "hover" throttle mode the stick's centre
-- hovers, so letting go arms). Keyboard fallback: SPACE/C throttle, W/S pitch, A/D roll, Q/E yaw, R upright.
-- G (a setting) launches and brings it back. While flying the rider is held where it stood and the game gets no
-- input. The drone itself is not drawn yet; it collides with the terrain only (not trees, rocks or buildings).
-- Culling and level of detail follow the game's own camera (the rider): far from it things pop in.
local LAUNCH_S, BLEND_S = 2.0, 0.6
local G = 9.81
local DRAG_LIN, DRAG_QUAD = 0.05, 0.025            -- per s, per m: ~160 km/h flat out at 5:1, ~70 km/h falling
local SKID = 0.15                                  -- metres between the drone's centre and the snow
local CRASH_SPEED = 5.0                            -- m/s into the ground (or more than 60 degrees tilted on it)
local MAX_STEP = 1 / 240                           -- physics sub-step

-- the rider's standing idle -> its drone pose: snowboard (ID00) STAND_IDLE, skis (ID01) STAND_IDLE_LEFT and its
-- _STEEP variant (the names from `python -m resteep anims find STAND_IDLE`), both genders
local CLIPS = {}
for _, g in ipairs({"male", "female"}) do
    CLIPS[#CLIPS + 1] = {"ID00_PS00_" .. g .. "_STAND_IDLE", "ID00_PS00_" .. g .. "_STAND_IDLE_DRONE"}
    CLIPS[#CLIPS + 1] = {"ID01_PS00_" .. g .. "_STAND_IDLE_LEFT", "ID01_PS00_" .. g .. "_STAND_IDLE_DRONE"}
    CLIPS[#CLIPS + 1] = {"ID01_PS00_" .. g .. "_STAND_IDLE_LEFT_STEEP", "ID01_PS00_" .. g .. "_STAND_IDLE_STEEP_DRONE"}
end

-- play_anim raises for a clip this game does not have: one missing pair must not stop the mod
local function redirect(on)
    local n = 0
    for _, c in ipairs(CLIPS) do
        local ok, set = pcall(resteep.rider.play_anim, c[1], on and c[2] or nil)
        if ok and set then n = n + 1 end
    end
    return n
end

local function setting(key, default)
    local ok, v = pcall(resteep.config.get, key)
    if not ok or v == nil then return default end
    return v
end

-- vectors: {x, y, z}, Z up
local function v3(x, y, z) return {x = x, y = y, z = z} end
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

-- the drone: position p, velocity v, its axes f (nose), r (right) and u (top) with r = f x u, the motors' output
-- thr (0..1, spooled), armed (until then it stays where it is: risen after the launch, or crashed), crashed
local state = "off"                                -- off, launch, fly
local hid_hud = false                              -- the game's HUD hidden by this flight (shown again on landing)
local t0, home = 0, nil
local d = {}
local kb_thr, last_buttons, said_at = 0, {}, {}

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

local function upright()                           -- level, same heading, standing still
    local h = v3(d.f.x, d.f.y, 0)
    if len(h) < 0.05 then h = v3(d.u.x, d.u.y, 0) end   -- nose straight up or down: the top says where it was going
    d.f, d.u = unit(h), v3(0, 0, 1)
    orthonormalize()
    d.v, d.thr = v3(0, 0, 0), 0
end

local function floor_at(x, y)
    -- the terrain raster can be off where the rider stands (600 m in the Alps' tutorial start, 2026-11-13): the floor
    -- is the raster shifted by what it misses under the rider
    local g = resteep.world.ground(x, y)
    if g and home.floor then g = g + home.floor end
    return g
end

local function camera_yaw()
    local c = resteep.camera()
    if c and c.forward then return math.atan(c.forward.y, c.forward.x) end
    return 0
end

local function launch()
    local p = resteep.player()
    if not p or not p.real then resteep.notify("drone: no rider", 2) return end
    if p.air then resteep.notify("drone: land first", 2) return end
    home = {x = p.x, y = p.y, z = p.z}
    local g = resteep.world.ground(p.x, p.y)
    home.floor = g and (p.z - g) or nil
    local ok, why = resteep.rider.hold(true)
    if not ok then resteep.notify("drone: " .. tostring(why), 3) return end
    if redirect(true) == 0 then resteep.log("drone: no launch pose on this game build") end
    -- the game's HUD off while flying (the activity card, challenge markers and prompts): only the drone's view
    hid_hud = resteep.hud.hide(true) == true
    local yaw = camera_yaw()
    d.f, d.u = v3(math.cos(yaw), math.sin(yaw), 0), v3(0, 0, 1)
    orthonormalize()
    d.p = v3(p.x + d.f.x * 0.6, p.y + d.f.y * 0.6, p.z + 1.2)
    d.v, d.thr = v3(0, 0, 0), 0
    d.armed, d.crashed = false, false
    kb_thr, last_buttons = hover_throttle(), {}
    state, t0 = "launch", resteep.time()
    resteep.notify("drone: launching", 2)
end

local function land()
    if hid_hud then resteep.hud.hide(false) hid_hud = false end
    resteep.camera.release(BLEND_S)
    redirect(false)
    resteep.rider.hold(false)
    state = "off"
    resteep.notify("drone: back", 2)
end

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

local function step(h, thr, roll, pitch, yaw)
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
    if floor and d.p.z < floor + SKID then
        local speed = len(d.v)
        d.p.z = floor + SKID
        if speed > CRASH_SPEED or d.u.z < 0.5 then crash(speed) return end
        if d.v.z < 0 then d.v.z = 0 end                              -- landed: it slides to a stop
        local k = 1 - math.min(1, 4 * h)
        d.v.x, d.v.y = d.v.x * k, d.v.y * k
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

local function osd(thr, pad)
    local floor = floor_at(d.p.x, d.p.y)
    local alt = floor and math.max(0, d.p.z - floor - SKID) or 0     -- (on the snow: 0, not "-0")
    local status = d.crashed and "CRASHED (Y)" or d.armed and "ARMED"
        or (thr > hover_throttle() + 0.02 and "THROTTLE DOWN TO ARM" or "DISARMED")
    local color = d.armed and "#FFFFFF" or "#FF5050"
    resteep.text(0.5, 0.86, string.format("%s   %3d%%   %3.0f km/h   %4.0f m%s", status, math.floor(d.thr * 100 + 0.5),
                                          len(d.v) * 3.6, alt, pad and "" or "   NO GAMEPAD (keyboard)"), color, 1)
end

local function fly(dt)
    resteep.input.capture(true)
    resteep.input.pad{}                            -- the game ignores the player's controls
    local pad = resteep.input.read()
    local hit = pressed(pad)
    if hit.B then land() return end
    if hit.Y or resteep.held("R") then
        upright()
        if d.crashed then d.crashed = false end
        local floor = floor_at(d.p.x, d.p.y)
        if floor and d.p.z < floor + SKID then d.p.z = floor + SKID end
        d.armed = false
    end
    local thr, roll, pitch, yaw = sticks(pad, dt)
    if not d.armed and not d.crashed and thr <= hover_throttle() + 0.02 then
        d.armed, d.thr = true, thr                -- the motors start at the stick: no dip
        say("drone: armed", 1, "arm")
    end
    if d.armed then
        local n = math.max(1, math.ceil(math.min(dt, 0.1) / MAX_STEP))
        local h = math.min(dt, 0.1) / n
        for _ = 1, n do
            step(h, thr, roll, pitch, yaw)
            if not d.armed then break end
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
    local tilt = math.rad(setting("camera_angle", 25))                 -- the FPV camera looks up from the nose
    resteep.camera.set{x = d.p.x, y = d.p.y, z = d.p.z, forward = rotate(d.f, d.r, tilt), up = rotate(d.u, d.r, tilt),
                       fov = setting("fov", 90), duration = BLEND_S}
    osd(thr, pad)
end

resteep.on("frame", function(dt)
    if state == "launch" then
        d.p.z = d.p.z + 1.4 * dt                   -- rises beside the rider, as the game's drone intro does
        if resteep.time() - t0 >= LAUNCH_S then
            state = "fly"
            resteep.notify("drone: up (throttle low arms it; B or G brings it back)", 3)
        end
    elseif state == "fly" then
        fly(dt)
    end
end)

resteep.on("key", function(key)
    if key ~= setting("launch", "G") then return end
    if state == "off" then launch() else land() end
end)

resteep.on("world_leave", function() if state ~= "off" then land() end end)
resteep.log("FPV drone (acro): G launches it (stand still), G again brings it back")
