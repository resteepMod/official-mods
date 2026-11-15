-- Golden hour: Ctrl+G holds the light at sunset (19:30, clock paused); Ctrl+G again gives the game its clock back.
local on = false
resteep.on("key", function(key)
    if key ~= "G" or not resteep.held("CTRL") then return end   -- Ctrl+G (plain G is the game's group key)
    on = not on
    if on then
        resteep.world.set_hour(19.5)
        resteep.world.pause(true)
        resteep.notify("Golden hour", 2)
    else
        resteep.world.pause(false)
        resteep.notify("Clock runs again", 2)
    end
end)
