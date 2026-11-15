-- Event notifications: every event ReSteep raises shows a notification (and a line in the MODS console) when it
-- fires. For checking that the events work. "frame" is left out (it fires every frame); "key" shows the key name.
-- A zone (10 m around where the rider first appears) makes zone_enter / zone_exit fire; press F4 to send a custom event.
local ZONE = "event_notify"

local function say(text, color)
    resteep.notify(text, 2.5)
    resteep.log(text)
end

resteep.on("takeoff", function() say("EVENT takeoff") end)
resteep.on("landing", function(airtime) say(string.format("EVENT landing  (air %.2f s)", airtime)) end)
resteep.on("key", function(name) say("EVENT key  " .. name) end)
resteep.on("zone_enter", function(name) say("EVENT zone_enter  " .. name) end)
resteep.on("zone_exit", function(name) say("EVENT zone_exit  " .. name) end)
resteep.on("world_enter", function() say("EVENT world_enter") end)
resteep.on("world_leave", function() say("EVENT world_leave") end)
resteep.on("sport_change", function(info)
    say(string.format("EVENT sport_change  %s (before: %s)", info.sport or "?", info.previous or "none"))
end)
resteep.on("crash", function(info)
    say(string.format("EVENT crash  %s, %.0f km/h", info.sport or "?", (info.speed or 0) * 3.6))
end)
resteep.on("crash_end", function(info)
    say(string.format("EVENT crash_end  %s, down %.1f s", info.sport or "?", info.duration or 0))
end)
resteep.on("event_notify_custom", function(value) say("EVENT custom event_notify_custom  " .. tostring(value)) end)

local zone_placed = false
resteep.on("player_found", function()
    say("EVENT player_found")
    local p = resteep.player()
    if p and not zone_placed then
        resteep.zone(ZONE, p.x, p.y, p.z, 10)
        zone_placed = true
        resteep.log(string.format("zone '%s' at %.0f %.0f %.0f, radius 10 m", ZONE, p.x, p.y, p.z))
    end
end)
resteep.on("player_lost", function() say("EVENT player_lost") end)
resteep.on("world_leave", function() zone_placed = false end)

resteep.on("key", function(name)
    if name == "F4" then resteep.emit("event_notify_custom", math.floor(resteep.time())) end
end)
