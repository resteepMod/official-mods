-- Camera effects: F6 goes through wide angle, zoom, dutch angle, crane shot, orbit and back to the game's own camera.
-- The effect has to be renewed every frame (it ends 250 ms after the mod stops); the game keeps steering the camera.
local modes = {
    {name = "game camera"},
    {name = "wide angle 100",  tweak = {fov = 100}},
    {name = "zoom 35",         tweak = {fov = 35}},
    {name = "dutch angle 18",  tweak = {roll = 18}},
    {name = "crane (4 m up, looking down)", tweak = {shift = {up = 4, forward = -2}, pitch = -12}},
    {name = "orbit around the rider"},
}
local mode, angle = 1, 0

resteep.on("key", function(name)
    if name == "F7" then resteep.camera.probe() resteep.notify("camera probe: see overlay.log", 3) return end
    if name ~= "F6" then return end
    mode = mode % #modes + 1
    resteep.notify("camera: " .. modes[mode].name, 2)
end)

resteep.on("frame", function(dt)
    local m = modes[mode]
    if m.tweak then
        resteep.camera.tweak(m.tweak)
    elseif mode == 6 then
        local p = resteep.player()
        if not p then return end
        angle = angle + dt * 0.5
        local r, h = 9, 3
        local x, y, z = p.x + math.cos(angle) * r, p.y + math.sin(angle) * r, p.z + h
        local fx, fy, fz = p.x - x, p.y - y, p.z + 1 - z
        local l = math.sqrt(fx * fx + fy * fy + fz * fz)
        resteep.camera.set{x = x, y = y, z = z, forward = {x = fx / l, y = fy / l, z = fz / l}, fov = 60}
    end
end)
