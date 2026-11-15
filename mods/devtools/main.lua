-- Dev tools for mod authors: F9 writes where you are (position, velocity, air) and the world state to the MODS
-- console and shows it for a moment; hold Ctrl+F9 to keep it on screen. Positions are the game's world units
-- (metres, Z up) - the numbers resteep.zone() and resteep.teleport() take.
local pinned = false

local function describe()
    local p, w = resteep.player(), resteep.world.get()
    local lines = {}
    if p then
        lines[#lines + 1] = string.format("pos %.1f %.1f %.1f   speed %.1f m/s %s", p.x, p.y, p.z, p.speed,
            p.air and string.format("(air %.1f s)", p.airtime) or "")
        lines[#lines + 1] = string.format("vel %.1f %.1f %.1f", p.velocity.x, p.velocity.y, p.velocity.z)
    else
        lines[#lines + 1] = "no rider"
    end
    if w then
        lines[#lines + 1] = string.format("hour %.2f  weather %.2f  wind %.2f  preset %s%s", w.hour, w.weather,
            w.wind, w.preset, w.paused and "  (paused)" or "")
    end
    return lines
end

resteep.on("key", function(key)
    if key ~= "F9" then return end
    if resteep.held("CTRL") then pinned = not pinned return end
    local lines = describe()
    for _, l in ipairs(lines) do resteep.log(l) end
    resteep.notify(lines[1], 4)
end)

resteep.on("frame", function()
    if not pinned then return end
    for i, l in ipairs(describe()) do resteep.text(0.5, 0.82 + 0.03 * i, l, "#B0BCC8", 0.85) end
end)
