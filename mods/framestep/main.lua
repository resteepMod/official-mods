-- Frame step: F10 freezes the whole world (the engine's stop mode), "." runs one simulation step, "," ten.
-- F10 again lets it run. The game cuts to its pause camera while frozen.
resteep.on("key", function(name)
    local w = resteep.world.get()
    if not w then return end
    if name == "F10" then
        resteep.world.freeze(not w.frozen)
    elseif w.frozen and name == "PERIOD" then
        resteep.world.step(1)
    elseif w.frozen and name == "COMMA" then
        resteep.world.step(10)
    end
end)

resteep.on("frame", function()
    local w = resteep.world.get()
    if w and w.frozen then resteep.text(0.5, 0.06, "FROZEN   . step   , step x10   F10 run", "#5EC8F2", 1.2) end
end)
