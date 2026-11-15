-- Markers: rings in the world. A ring on you with your speed, and four rings 10 m north/south/east/west at your height.
-- Shows that resteep.marker follows the game's camera (use it with the free camera or the rider turning).
resteep.on("frame", function()
    local p = resteep.player()
    if not p then return end
    resteep.marker(p.x, p.y, p.z + 1, string.format("%.0f km/h", p.speed * 3.6), "#5EC8F2")
    resteep.marker(p.x, p.y + 10, p.z, "N", "#FFFFFF")
    resteep.marker(p.x, p.y - 10, p.z, "S", "#FFFFFF")
    resteep.marker(p.x + 10, p.y, p.z, "E", "#FFFFFF")
    resteep.marker(p.x - 10, p.y, p.z, "W", "#FFFFFF")
end)
