-- The mod's own Domino script (scripts/wait.json, placed by resteep.json's content.scripts): the game runs it when
-- its part of the Alps loads. resteep.domino lists the scripts the game has loaded and starts / stops a mod's own.
local function mine()
    for _, s in ipairs(resteep.domino.list() or {}) do
        if s.mod then return s end
    end
end

resteep.on("key", function(key)
    if key ~= "F7" then return end
    local s = mine()
    if not s then resteep.log("no script of a mod loaded here") return end
    if s.running then resteep.domino.stop(s.id) else resteep.domino.start(s.id) end
    resteep.log("script " .. s.id .. (s.running and " stopped" or " started"))
end)
