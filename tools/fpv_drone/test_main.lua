-- A stub run of mods/fpv_drone/main.lua in plain Lua 5.4 (no game): a stand-in `resteep` records what the mod asks
-- for. Checks the launch / landing sequence, the d-pad's field of view and camera angle (steps, limits, the stored
-- settings), the model and sound settings, the rider's pose, the collision query when there is one, and the flight in
-- the game's replay (resteep.world.replay: no rider, the camera only, handed back on landing).
--     lua5.4 tools/fpv_drone/test_main.lua          (from the repository's root)
local MAIN = (arg and arg[1]) or "mods/fpv_drone/main.lua"

local function new_world(opts)
    opts = opts or {}
    local w = {now = 0, handlers = {}, cfg = {}, calls = {}, pad = nil, keys = {}, props = {}, sounds = {}, next_id = 1}
    local defaults = {launch = "G", throttle = "hover", mode = "2", rc_rate = 1.0, super_rate = 0.7, expo = 0,
                      deadzone = 0.05, power = 5, camera_angle = 25, fov = 90, model = "game", model_fpv = true,
                      sound = true, volume = 0.7, range = 300}
    for k, v in pairs(defaults) do w.cfg[k] = v end
    for k, v in pairs(opts.cfg or {}) do w.cfg[k] = v end
    local function log(kind, ...) w.calls[#w.calls + 1] = {kind, ...} end
    local camera = setmetatable({
        set = function(t) w.cam = t log("camera.set", t) end,
        release = function(s) w.cam = nil log("camera.release", s) end,
    }, {__call = function() return w.cam_game end})
    w.cam_game = {x = 0, y = -4, z = 102, forward = {x = 0, y = 1, z = 0}, fov = 60}
    local r = {
        on = function(ev, fn) w.handlers[ev] = w.handlers[ev] or {} table.insert(w.handlers[ev], fn) end,
        time = function() return w.now end,
        notify = function(t) log("notify", t) end,
        log = function(t) log("log", t) end,
        text = function(x, y, t) log("text", t) end,
        held = function(k) return w.keys[k] == true end,
        player = function() return {x = 0, y = 0, z = 100, real = true, air = false} end,
        world = {ground = function() return 100 end, raycast = opts.raycast,
                 replay = opts.replay and function() return w.replay end or nil},
        rider = {
            hold = function(on) log("hold", on) return true end,
            play_anim = function(from, to)
                if not from:match("^ID%d%d_PS%d%d_%a+_") then error("no clip " .. from) end
                log("play_anim", from, to) return true
            end,
            anim_seen = function() local s = w.seen or {} w.seen = nil return s end,
        },
        hud = {hide = function(on) log("hud", on) return true end},
        camera = camera,
        input = {capture = function() end, pad = function(t) w.sent_pad = t end, read = function() return w.pad end},
        config = {
            get = function(k) if w.cfg[k] == nil then error("no setting " .. k) end return w.cfg[k] end,
            set = function(k, v) w.cfg[k] = v log("config.set", k, v) return v end,
        },
        prop = {
            find = function(id)
                log("prop.find", id)
                if opts.no_models then return nil, "not loaded" end
                return id
            end,
            get = function(h)
                return {x = 0, y = 0, z = -5, matrix = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, -5, 1}}
            end,
            set = function(h, t) w.props[h] = t log("prop.set", h, t) return true end,
        },
        sound = {
            play = function(f, t)
                local id = w.next_id
                w.next_id, w.sounds[id] = id + 1, t
                log("sound.play", f, t)
                return id
            end,
            set = function(id, t) w.sounds[id] = t end,
            stop = function(id) w.sounds[id] = nil log("sound.stop", id) end,
        },
    }
    w.r = r
    function w.emit(ev, ...) for _, fn in ipairs(w.handlers[ev] or {}) do fn(...) end end
    function w.frames(n, dt)
        dt = dt or 1 / 60
        for _ = 1, n do w.now = w.now + dt w.emit("frame", dt) end
    end
    function w.count(kind, pred)
        local n = 0
        for _, c in ipairs(w.calls) do if c[1] == kind and (not pred or pred(c)) then n = n + 1 end end
        return n
    end
    function w.last(kind)
        for i = #w.calls, 1, -1 do if w.calls[i][1] == kind then return w.calls[i] end end
    end
    resteep = r
    dofile(MAIN)
    return w
end

local fails, checks = 0, 0
local function check(ok, what)
    checks = checks + 1
    if not ok then fails = fails + 1 print("FAIL: " .. what) end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function pad(buttons) return {lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0, buttons = buttons or {}} end

local function flying(opts)
    local w = new_world(opts)
    w.pad = pad()
    w.emit("key", "G")
    w.frames(60 * 4)
    return w
end

-- the launch: seen from the game's camera, the model shown, the motors spun up, then the FPV view
do
    local w = new_world()
    w.pad = pad()
    w.emit("key", "G")
    w.frames(30)
    check(w.cam and w.cam.x == 0 and w.cam.y == -4 and w.cam.z == 102, "launch: the camera stays where the game's was")
    check(w.count("prop.set", function(c) return c[2] == 0x2FD00001000 end) > 0, "launch: the game's drone model moves")
    check(w.count("sound.play") == 1, "launch: the motor sound starts")
    check(w.count("play_anim", function(c) return c[2] == "ID01_PS00_male_STAND_IDLE_LEFT_STEEP" and
                                                   c[3] == "ID01_PS00_male_STAND_IDLE_STEEP_DRONE" end) == 1,
          "launch: a ski idle gets the ski drone pose")
    check(w.count("play_anim", function(c) return c[2] == "ID00_PS04_female_STAND_IDLE_breaker_03" and
                                                   c[3] == "ID00_PS00_female_STAND_IDLE_DRONE" end) == 1,
          "launch: a snowboard breaker idle gets the drone pose")
    w.seen = {"ID03_PS00_male_STAND_IDLE_RIGHT", "ID00_PS00_male_STAND_IDLE_DRONE"}
    w.frames(1)
    check(w.count("play_anim", function(c) return c[2] == "ID03_PS00_male_STAND_IDLE_RIGHT" end) == 1,
          "launch: an idle the game looks up gets the pose")
    check(w.count("play_anim", function(c) return c[2] == "ID00_PS00_male_STAND_IDLE_DRONE" end) == 0,
          "launch: the drone pose itself is left alone")
    w.frames(60 * 4)
    check(w.cam and near(w.cam.fov, 90), "fly: the FPV camera has the fov setting")
    check(w.count("notify", function(c) return c[2]:find("drone: up", 1, true) end) == 1, "fly: up after the launch")
end

-- the d-pad: steps of 5 degrees, repeats while held, limits, stored as the settings; the game gets a neutral pad
do
    local w = flying()
    w.pad = pad({"RIGHT"})
    w.frames(1)
    check(w.cfg.fov == 95, "dpad: right -> fov 95 (" .. tostring(w.cfg.fov) .. ")")
    check(w.sent_pad and next(w.sent_pad) == nil, "dpad: the game gets a neutral pad")
    w.frames(10)
    check(w.cfg.fov == 95, "dpad: no repeat before 0.4 s")
    w.frames(60 * 3)
    check(w.cfg.fov == 150, "dpad: held right stops at 150 (" .. tostring(w.cfg.fov) .. ")")
    w.pad = pad()
    w.frames(1)
    check(w.cam and near(w.cam.fov, 150), "dpad: the camera follows the fov")
    w.pad = pad({"LEFT"})
    w.frames(60 * 4)
    check(w.cfg.fov == 60, "dpad: held left stops at 60 (" .. tostring(w.cfg.fov) .. ")")
    w.pad = pad({"UP"})
    w.frames(1)
    check(w.cfg.camera_angle == 30, "dpad: up -> camera angle 30")
    w.frames(60 * 4)
    check(w.cfg.camera_angle == 60, "dpad: held up stops at 60")
    w.pad = pad({"DOWN"})
    w.frames(60 * 4)
    check(w.cfg.camera_angle == 0, "dpad: held down stops at 0")
    check(w.count("text", function(c) return c[2]:find("CAMERA ANGLE 0", 1, true) end) > 0, "dpad: a note shows it")
    w.pad = pad()
    w.frames(1)
    w.keys.RIGHT = true                            -- the arrow keys do the same
    w.frames(1)
    w.keys.RIGHT = nil
    check(w.cfg.fov == 65, "dpad: the right arrow key -> 65")
end

-- a value between the steps goes to the next multiple of 5
do
    local w = flying({cfg = {fov = 92, camera_angle = 27}})
    w.pad = pad({"RIGHT"}) w.frames(1) w.pad = pad() w.frames(1)
    check(w.cfg.fov == 95, "dpad: 92 -> 95")
    w.pad = pad({"DOWN"}) w.frames(1)
    check(w.cfg.camera_angle == 25, "dpad: 27 -> 25")
end

-- the landing: the camera back on the rider, the drone flies back, spins down, is put away, everything released
do
    local w = flying()
    w.pad = pad({"B"})
    w.frames(1)
    w.pad = pad()
    w.frames(60 * 8)
    check(w.count("camera.release") == 1, "land: the camera goes back to the game")
    check(w.count("hold", function(c) return c[2] == false end) == 1, "land: the rider is let go")
    check(next(w.sounds) == nil, "land: the sound stops")
    local p = w.props[0x2FD00001000]
    check(p and p.matrix and p.matrix[15] == -5, "land: the model is parked under the ground again")
    check(w.count("notify", function(c) return c[2] == "drone: back" end) == 1, "land: back")
    check(w.count("play_anim", function(c) return c[3] == nil end) > 0, "land: the poses end")
end

-- settings: the model and the sound off
do
    local w = flying({cfg = {model = "off", sound = false}})
    check(w.count("prop.set") == 0 and w.count("prop.find") == 0, "model off: nothing placed")
    check(w.count("sound.play") == 0, "sound off: no sound")
end

do
    local w = flying({cfg = {model = "own"}})
    check(w.count("prop.set", function(c) return c[2] == 0x2FD00002000 end) > 0, "model own: the mod's quad flies")
    check(w.count("prop.set", function(c) return c[2] == 0x2FD00001000 end) == 0, "model own: not the game's")
end

do                                                 -- not in the FPV view: put away while flying
    local w = flying({cfg = {model_fpv = false}})
    local p = w.props[0x2FD00001000]
    check(p and p.matrix and p.matrix[13] == 3 and p.matrix[15] == -5, "model_fpv off: parked while flying")
end

do                                                 -- switched off mid-flight: parked, the sound stops
    local w = flying()
    w.cfg.model, w.cfg.sound = "off", false
    w.emit("config_change", "model", "off")
    w.frames(5)
    local p = w.props[0x2FD00001000]
    check(p and p.matrix and p.matrix[15] == -5, "model switched off: parked")
    check(next(w.sounds) == nil, "sound switched off: stopped")
end

do                                                 -- no model in this map: flies without one
    local w = flying({no_models = true})
    check(w.count("prop.set") == 0, "no model: nothing moved")
    check(w.count("log", function(c) return c[2]:find("no game model", 1, true) end) == 1, "no model: logged")
end

-- the sound follows the throttle
do
    local w = flying()
    w.pad = pad() w.pad.ly = -1                    -- arms at the bottom
    w.frames(30)
    local low = w.sounds[1] and w.sounds[1].pitch
    w.pad.ly = 1
    w.frames(30)
    local high = w.sounds[1] and w.sounds[1].pitch
    check(low and high and high > low + 0.5, "sound: pitch rises with the throttle (" .. tostring(low) .. " -> "
          .. tostring(high) .. ")")
end

-- a collision query when there is one: asked along the motion, a hard hit is a crash
do
    local asked = 0
    local w = flying({raycast = function(x1, y1, z1, x2, y2, z2)
        asked = asked + 1
        if z2 < 101.5 then return {x = x2, y = y2, z = 101.5, nx = 0, ny = 0, nz = 1, fraction = 0.5} end
    end})
    w.pad = pad() w.pad.ly = -1                    -- arm, then let it fall
    w.frames(10)
    w.pad.ly = -1
    w.frames(60)
    check(asked > 0, "collision: the raycast is asked")
    check(w.count("log", function(c) return c[2]:find("collision query failed", 1, true) end) == 0,
          "collision: no error")
end

do                                                 -- the raster: a soft touch over it is no crash
    local w = flying()
    w.pad = pad() w.pad.ly = -1
    w.frames(5)
    w.pad.ly = -0.5                                -- sinks slowly onto the snow
    w.frames(60 * 3)
    check(w.count("notify", function(c) return c[2]:find("crashed", 1, true) end) == 0, "raster: settling is no crash")
end

-- the game's replay: G starts the drone at the replay camera at once, without the rider
local function replaying(opts)
    opts = opts or {}
    opts.replay = true
    local w = new_world(opts)
    w.replay = {playing = true, paused = false, rewinding = false}
    w.pad = pad()
    w.emit("key", "G")
    w.frames(2)
    return w
end

do
    local w = replaying()
    check(w.count("hold") == 0, "replay: the rider is not held")
    check(w.count("play_anim") == 0, "replay: no launch pose")
    check(w.count("notify", function(c) return c[2]:find("up in the replay", 1, true) end) == 1, "replay: up at once")
    check(w.cam and near(w.cam.x, 0) and near(w.cam.y, -4) and near(w.cam.z, 102),
          "replay: the FPV camera starts where the replay's camera is (" .. (w.cam and string.format("%.3f %.3f %.3f",
          w.cam.x, w.cam.y, w.cam.z) or "none") .. ")")
    check(w.cam and near(w.cam.fov, 90) and w.cam.forward.y > 0.8, "replay: looking the replay camera's way, the fov")
    check(w.count("hud", function(c) return c[2] == true end) == 1, "replay: the HUD hidden")
    check(w.sent_pad and next(w.sent_pad) == nil, "replay: the replay's controls get a neutral pad")
    w.frames(60)
    check(w.cam and near(w.cam.z, 102), "replay: disarmed, it hovers where it started")
    w.replay.playing, w.replay.paused = false, true -- paused: it flies on its own clock
    w.pad.ly = -1                                  -- arm
    w.frames(5)
    local z0 = w.cam.z
    w.pad.ly = 1                                   -- full throttle: climbs
    w.frames(60)
    check(w.cam.z > z0 + 1, "replay paused: the drone still flies (" .. string.format("%.2f -> %.2f", z0, w.cam.z) .. ")")
    w.pad = pad({"B"})                             -- B: the replay's camera again, at once
    w.frames(1)
    check(w.count("camera.release") == 1 and w.cam == nil, "replay land: the camera goes back to the replay's")
    check(w.count("hold") == 0 and w.count("play_anim") == 0, "replay land: the rider never touched")
    check(w.count("hud", function(c) return c[2] == false end) == 1, "replay land: the HUD back")
    check(next(w.sounds) == nil, "replay land: the sound stops")
    local p = w.props[0x2FD00001000]
    check(p and p.matrix and p.matrix[15] == -5, "replay land: the model parked again")
    check(w.count("notify", function(c) return c[2] == "drone: back to the replay" end) == 1, "replay land: said")
    w.pad = pad()
    w.frames(30)
    check(w.cam == nil, "replay land: no camera after it")
end

do                                                 -- the collision query is asked in a replay too
    local asked = 0
    local w = replaying({raycast = function(x1, y1, z1, x2, y2, z2)
        asked = asked + 1
        if z2 < 101.5 then return {x = x2, y = y2, z = 101.5, nx = 0, ny = 0, nz = 1, fraction = 0.5} end
    end})
    w.pad.ly = -1
    w.frames(60)
    check(asked > 0, "replay collision: the raycast is asked")
    check(w.cam.z > 101.5, "replay collision: it stops on what the query hit")
end

do                                                 -- G again lands too; the replay ending ends the flight
    local w = replaying()
    w.emit("key", "G")
    check(w.count("camera.release") == 1 and w.count("hold") == 0, "replay: G hands the camera back")
    w.emit("key", "G")
    w.frames(2)
    check(w.cam ~= nil, "replay: G launches again")
    w.replay = nil
    w.frames(1)
    check(w.count("camera.release") == 2 and w.count("notify", function(c) return c[2] == "drone: the replay ended" end)
          == 1, "replay ended: the drone stops, the camera goes back")
    check(w.count("hold") == 0, "replay ended: the rider never touched")
end

do                                                 -- outside a replay (the call answers nil) the launch is as before
    local w = new_world({replay = true})
    w.replay = nil
    w.pad = pad()
    w.emit("key", "G")
    w.frames(30)
    check(w.count("hold", function(c) return c[2] == true end) == 1, "no replay: the rider is held as before")
    check(w.count("play_anim") > 0, "no replay: the launch pose as before")
    check(w.cam and w.cam.x == 0 and w.cam.y == -4 and w.cam.z == 102, "no replay: the launch's chase view")
end

print(string.format("%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
