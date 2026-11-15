-- Air-time contest: every landing after at least one second in the air counts; the longest goes to the server's
-- board "longest_air" (higher is better) and the top 3 show for a few seconds. Also shows custom events: it sends
-- "big_air" to every other mod, which can react with resteep.on("big_air", function(t) ... end).
-- A landing after a mod held the rider in the air (a helicopter, a drone) does not count: that air time was the mod's.
local best = (resteep.load() or {}).best or 0
local shown = nil
local held_at = -100         -- resteep.time() when a mod last held the rider

resteep.on("landing", function(airtime)
    if airtime < 1 then return end
    if resteep.time() - held_at <= airtime + 0.5 then return end
    resteep.emit("big_air", airtime)
    if airtime > best then
        best = airtime
        resteep.save({best = best})
        resteep.notify(string.format("New personal best: %.2f s in the air", airtime), 3)
    end
    resteep.post("/mods/board/submit", {board = "longest_air", value = airtime, lower_is_better = false, limit = 3},
        function(ok, reply)
            if not ok or type(reply) ~= "table" then return end
            local lines = {}
            for i, e in ipairs(reply.top or {}) do lines[i] = string.format("%d. %s  %.2f s", i, tostring(e.name), e.value) end
            shown = {lines = lines, until_ = resteep.time() + 5}
        end)
end)

resteep.on("frame", function()
    local p = resteep.player()
    if p and p.held then held_at = resteep.time() end
    if not shown then return end
    if resteep.time() > shown.until_ then shown = nil return end
    for i, line in ipairs(shown.lines) do resteep.text(0.85, 0.3 + 0.03 * i, line, "#FFD34E") end
end)
