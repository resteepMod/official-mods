-- Speedometer: speed and air time in the bottom right corner. The smallest useful mod.
resteep.on("frame", function()
    local p = resteep.player()
    if not p then return end
    resteep.text(0.92, 0.88, string.format("%3.0f km/h", p.speed * 3.6), "#FFFFFF", 1.4)
    if p.air then resteep.text(0.92, 0.93, string.format("AIR %.1f s", p.airtime), "#5EC8F2") end
end)
