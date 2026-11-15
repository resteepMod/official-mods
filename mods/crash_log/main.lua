-- Crash log: counts falls per sport, shows the last one and the sport in the top left corner, remembers the counts.
-- Uses the rider events sport_change / crash / crash_end and resteep.sport() (MODDING.md).
local saved = resteep.load() or {}
local crashes = saved.crashes or {}
local last, ragdoll_since

resteep.on("sport_change", function(info)
    resteep.notify("Sport: " .. info.sport, 2)
end)

resteep.on("crash", function(info)
    crashes[info.sport] = (crashes[info.sport] or 0) + 1
    last = string.format("%s crash at %.0f km/h", info.sport, info.speed * 3.6)
    ragdoll_since = resteep.time()
    resteep.save({crashes = crashes})
end)

resteep.on("crash_end", function(info)
    last = string.format("%s crash, down for %.1f s", info.sport, info.duration)
    ragdoll_since = nil
end)

resteep.on("frame", function()
    local sport = resteep.sport()
    if not sport then return end
    local total = 0
    for _, n in pairs(crashes) do total = total + n end
    resteep.text(0.1, 0.05, string.format("%s  |  crashes %d (%s: %d)", sport, total, sport, crashes[sport] or 0), "#FFFFFF", 1.1)
    if ragdoll_since then
        resteep.text(0.5, 0.15, string.format("OUCH %.1f s", resteep.time() - ragdoll_since), "#FF6060", 2)
    elseif last then
        resteep.text(0.1, 0.09, last, "#AAAAAA")
    end
end)
