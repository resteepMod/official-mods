-- Boost: hold F7 and the rider goes where the camera looks, at a set speed. For getting around a map quickly
-- (a test world, a mod's own terrain). PAGEUP / PAGEDOWN change the speed (10..300 m/s, 60 at the start).
-- Works on the ground only, as every change of the rider's velocity (docs/modding/api.md "Player"): in the air
-- the flight path takes over, so it follows the slopes and lifts off over a crest.
local speed, last_note = 60, -10

local function say(text) resteep.notify(text, 2) end

resteep.on("key", function(k)
    if k ~= "PAGEUP" and k ~= "PAGEDOWN" then return end
    speed = math.max(10, math.min(300, speed + (k == "PAGEUP" and 20 or -20)))
    say(string.format("Boost: %d m/s (%d km/h), hold F7", speed, math.floor(speed * 3.6 + 0.5)))
end)

resteep.on("frame", function()
    if not resteep.held("F7") then return end
    local p, cam = resteep.player(), resteep.camera()
    if not p or not cam then return end
    local fx, fy = cam.forward.x, cam.forward.y   -- level: the ground gives the slope
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.05 then return end                 -- looking straight down or up: no direction
    if not resteep.rider.set_velocity(fx / len * speed, fy / len * speed, 0) then
        local now = resteep.time()
        if now - last_note > 3 then
            last_note = now
            say("Boost: not possible here (Fly on, or another game build)")
        end
    end
end)

resteep.log("boost ready: hold F7 (PAGEUP / PAGEDOWN: speed)")
