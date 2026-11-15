-- Domino playground: scripts/skydrop.json (Delay 5 s -> PlayerTeleport 400 m above the Alps' tutorial start -> Out)
-- is placed there by resteep.json's content.scripts; the game's own script engine runs it when that part of the
-- Alps loads (from a few hundred metres away). F8 starts it again (resteep.domino.start), F7 stops it.
-- Lua alone could teleport too; the point is a script graph the engine runs (docs/modding/format.md "Content: scripts").
local function mine()
    for _, s in ipairs(resteep.domino.list() or {}) do
        if s.mod then return s end
    end
end

resteep.on("key", function(key)
    if key ~= "F7" and key ~= "F8" then return end
    local s = mine()
    if not s then
        resteep.notify("domino: the script is not loaded here: go to the Alps' tutorial start (it loads near it)", 5)
        return
    end
    if key == "F8" then
        resteep.domino.start(s.id)
        resteep.notify("domino: skydrop in 5 s", 3)
    else
        resteep.domino.stop(s.id)
        resteep.notify("domino: stopped", 3)
    end
end)
resteep.log("domino playground: F8 skydrop (near the Alps' tutorial start), F7 stop")
