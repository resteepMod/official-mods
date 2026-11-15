-- Helicopter mode (docs/todo/10-helicopter.md, route A). F8 (or the pad's BACK) starts and ends it. The mod holds the
-- rider (resteep.rider.hold: the trainer's Fly + noclip, so the game's physics and collision leave it alone) and
-- moves it every frame with resteep.rider.set_position, from a small flight model in Lua (collective, cyclic,
-- pedals); the game's own helicopter (STP_Helico, the Alps' intro helicopter, moved with resteep.prop) flies with
-- the rider in its open side door; a chase camera follows; F8 / B lets go (the game takes over and the rider falls
-- from there, the helicopter stays where it was). It never goes below the ground (resteep.world.ground) plus SKIDS; walls and objects
-- are not checked. The first version set the velocity every frame instead; in the game that moved nothing (TODO 10
-- "Step 1's result"). Credits: the gravity constant and the shape of the horizontal drag are
-- the paraglider's, from steep-gameplay-research (github.com/Sean-Shmulevich/steep-gameplay-research,
-- docs/systems/air/CLIENT_GUIDE.txt, used with the author's permission); the tuning values are ours.

local G = 9.8100004196167          -- the game's gravity in the paraglider force law (steep-gameplay-research)
local MAX_TILT = math.rad(25)      -- full cyclic tilts the rotor disc this far
local TILT_TAU = 0.35              -- s, the disc follows the stick with this lag
local YAW_RATE = 1.2               -- rad/s at full pedal
local COLLECTIVE = 0.8             -- full collective: +-0.8 g on top of hover (released = hold the height)
local DRAG_H = 0.00226             -- quadratic horizontal drag, -DRAG_H * |v_h|^2 along v_h: ~45 m/s at full tilt
local DAMP_V = 0.8                 -- 1/s, linear vertical damping: ~10 m/s climb at full collective
local MAX_SPEED = 80               -- m/s (the API refuses beyond 1000; the game clamps further)
local SKIDS = 1.2                  -- m: the lowest it goes over the ground (resteep.world.ground), as if on its skids
-- STP_Helico: the Alps' root cell has it; Alaska's and Japan's get a copy with a fixed id from this mod's world edits
-- (resteep.json, assets/helicopter_*.json: built at game start; without the build: no model there)
local HELICOS = {0x1105920500E, 0x2F000001000}
local SEAT = {x = -1.25, y = 0.4, z = 0.7}   -- the rider in the left sliding door, in the helicopter's frame
                                   -- (x right, y nose, z up; metres from its origin under the skids; by eye)

local on = false
local v = {x = 0, y = 0, z = 0}    -- the model's velocity, world, Z up
local yaw, pitch, roll = 0, 0, 0   -- heading (0 = +Y, positive turns towards -X) and the disc's tilt
local pos                          -- where the mod holds the rider
local rotor                        -- the rotor loop's sound id (resteep.sound, sounds/rotor_loop.wav)
local cam                          -- the chase camera's smoothed position
local heli                         -- resteep.prop handle of the helicopter (nil: not in this world)
local start_z = 0

local held_before = {}             -- pad buttons held last frame (for presses)

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end

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
    -- U O turn, Y H up / down;
    -- the numpad and Page Up / Down do the same
    f = f + key("I") - key("K") + key("NUMPAD8") - key("NUMPAD5") - key("NUMPAD2")
    r = r + key("L") - key("J") + key("NUMPAD6") - key("NUMPAD4")
    pedal = pedal + key("O") - key("U") + key("NUMPAD9") - key("NUMPAD7")
    coll = coll + key("Y") - key("H") + key("PAGEUP") - key("PAGEDOWN")
    local function dead(x) x = clamp(x, -1, 1) return math.abs(x) < 0.12 and 0 or x end
    return dead(f), dead(r), dead(pedal), dead(coll)
end

-- the game's activities of a sport (player().activity, docs/modding/api.md): the helicopter starts only on foot and
-- standing still, else the game goes on riding the board / skis under the held rider
local ON_FOOT = 6                  -- walking (seen in the game, 2026-11-11)
local RIDING = {[0] = "snowboard", [1] = "wingsuit", [2] = "ski", [3] = "paraglider", [5] = "speed riding",
                [7] = "a crash", [9] = "sled", [10] = "rocket wingsuit", [11] = "free fall"}
local STILL = 1.0                  -- m/s: "stopped"

local function start()
    local p = resteep.player()
    if not p then resteep.notify("helicopter: no rider", 2) return end
    local riding = p.activity ~= ON_FOOT and (RIDING[p.activity] or ("activity " .. tostring(p.activity))) or nil
    if riding or p.air or (p.speed or 0) > STILL then
        resteep.log(string.format("helicopter: not started (activity %s, speed %.1f, air %s)", tostring(p.activity),
                                  p.speed or 0, tostring(p.air)))
        resteep.notify(riding and ("helicopter: get off first (" .. riding .. "): walk, stand still, then F8 / BACK")
                       or "helicopter: stop first (standing still, on the ground)", 4)
        return
    end
    resteep.log("helicopter: started on foot (activity " .. tostring(p.activity) .. ")")
    local ok, why = resteep.rider.hold(true)
    if not ok then resteep.notify("helicopter: can't hold the rider: " .. tostring(why), 4) return end
    v = {x = 0, y = 0, z = 0}
    pos = {x = p.x, y = p.y, z = p.z}
    local c = resteep.camera()
    yaw = c and math.atan(-c.forward.x, c.forward.y) or 0
    pitch, roll, cam, start_z = 0, 0, nil, p.z
    local why
    rotor, why = resteep.sound.play("sounds/rotor_loop.wav", {loop = true, volume = 0.9, range = 400,
                                                               at = {x = p.x, y = p.y, z = p.z}})
    if not rotor then resteep.log("helicopter: no rotor sound: " .. tostring(why)) end
    resteep.input.pad{}            -- puts the pad hook in, so input.read() has the real pad from now on
    for _, id in ipairs(HELICOS) do
        heli, why = resteep.prop.find(id)
        if heli then break end
    end
    if not heli then resteep.log("helicopter: no model here: " .. tostring(why)) end
    on = true
    resteep.notify("helicopter on: tilt = left stick or I J K L, turn = right stick or U O, "
                   .. "up / down = RT LT or Y H, let go = B or F8", 6)
end

local function stop(why)
    on = false
    if rotor then resteep.sound.stop(rotor) rotor = nil end
    resteep.rider.hold(false)                -- the game takes the rider back where it is
    resteep.camera.release(0.6)
    resteep.notify("helicopter off" .. (why and (": " .. why) or ""), 3)
end

-- the helicopter around the held rider: its axes from the heading and the disc's tilt (pitch forward = nose down,
-- roll right = right side down), its origin so that SEAT lands on the rider
local function place_heli()
    if not heli then return end
    local cy, sy, cp, sp, cr, sr = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch), math.cos(roll),
                                   math.sin(roll)
    local f = {-sy * cp, cy * cp, -sp}                       -- nose
    local u = {-sy * sp, cy * sp, cp}                        -- up after the pitch
    local r = {cy, sy, 0}                                    -- right
    r, u = {r[1] * cr - u[1] * sr, r[2] * cr - u[2] * sr, r[3] * cr - u[3] * sr},
           {u[1] * cr + r[1] * sr, u[2] * cr + r[2] * sr, u[3] * cr + r[3] * sr}
    local o = {}
    for i, k in ipairs({"x", "y", "z"}) do o[i] = pos[k] - (SEAT.x * r[i] + SEAT.y * f[i] + SEAT.z * u[i]) end
    local ok, why = resteep.prop.set(heli, {matrix = {r[1], r[2], r[3], 0, f[1], f[2], f[3], 0, u[1], u[2], u[3], 0,
                                                      o[1], o[2], o[3], 1}})
    if not ok then resteep.log("helicopter: the model stays behind: " .. tostring(why)) heli = nil end
end

local function fly(p, dt, pad)
    local f, r, pedal, coll = controls(pad)
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
    local h = math.sqrt(v.x * v.x + v.y * v.y)
    if h > 1e-5 then ax, ay = ax - DRAG_H * h * v.x, ay - DRAG_H * h * v.y end
    az = az - G - DAMP_V * v.z
    v.x, v.y, v.z = v.x + ax * dt, v.y + ay * dt, v.z + az * dt
    local s = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if s > MAX_SPEED then v.x, v.y, v.z = v.x / s * MAX_SPEED, v.y / s * MAX_SPEED, v.z / s * MAX_SPEED end
    pos.x, pos.y, pos.z = pos.x + v.x * dt, pos.y + v.y * dt, pos.z + v.z * dt
    local ground = resteep.world.ground(pos.x, pos.y)        -- nil where it is not known: no check there
    if ground and pos.z < ground + SKIDS then
        pos.z = ground + SKIDS
        if v.z < 0 then v.z = 0 end                          -- landed: the descent stops
    end
    local ok, why = resteep.rider.set_position(pos.x, pos.y, pos.z)
    if not ok then stop(why) return end
    place_heli()
    if rotor then                                            -- the rotor works harder with the collective and climbing
        resteep.sound.set(rotor, {loop = true, volume = 0.9, range = 400, pitch = 0.9 + 0.2 * coll + 0.01 * math.max(0, v.z),
                                  at = {x = pos.x, y = pos.y, z = pos.z}})
    end
    resteep.input.pad{}                                      -- the game gets a neutral pad meanwhile
    resteep.input.capture(true)                              -- ... and no keyboard or mouse (keys still reach us)

    -- chase camera: behind along the heading (further with the helicopter: its tail is 8.7 m long), up, smoothed
    local back, up = heli and 24 or 14, heli and 7 or 5
    local want = {x = p.x - fx * back, y = p.y - fy * back, z = p.z + up}
    cam = cam or want
    local c = math.min(1, dt / 0.25)
    for _, k in ipairs({"x", "y", "z"}) do cam[k] = cam[k] + (want[k] - cam[k]) * c end
    local lx, ly, lz = p.x - cam.x, p.y - cam.y, p.z + 1.5 - cam.z
    local l = math.sqrt(lx * lx + ly * ly + lz * lz)
    if l > 0.1 then resteep.camera.set{x = cam.x, y = cam.y, z = cam.z, forward = {x = lx / l, y = ly / l, z = lz / l},
                                       fov = 70} end

    resteep.text(0.5, 0.9, string.format("HELI  %+.0f m  %3.0f km/h  climb %+.1f m/s", pos.z - start_z, s * 3.6, v.z),
                 "#FFFFFF", 1.1)
end

resteep.on("key", function(k)
    if k == "F8" then if on then stop() else start() end end
end)

resteep.on("frame", function(dt)
    local pressed, pad = pad_presses()
    if not on then
        if pressed.BACK then start() end
        return
    end
    if pressed.BACK or pressed.B then stop("dropped") return end
    local p = resteep.player()
    if not p or p.ragdoll then stop(p and "crashed" or "no rider") return end
    if not resteep.rider.held() then stop("the rider was let go") return end
    dt = clamp(dt, 0.001, 0.05)
    fly(p, dt, pad)
end)

resteep.on("world_leave", function() if on then stop() end end)
