-- Domino showcase: scripts of the mod's own, idle until started (resteep.json content.scripts, "start": "lua").
-- Everywhere in the Alps and Japan ("anywhere": their carriers sit in the map's root cell; the kicker only in the
-- Alps, where its template is, also in the root cell). Keys (change them on the MODS page):
--   J pick the next effect (shown at the top), K run it, L stop every effect; the number row 1-8 runs one directly
--   1 tooltip "WELCOME TO STEEP!" for 6 s     2 the game's progression sounds   3 the light changes (an ambiance)
--   4 a kicker appears 15 m ahead of you for 30 s (Alps: SpawnEntity, SetEntityPosition to the player, add_local)
--   5 skydrop: 400 m above where you are (GetPlayer -> GetEntityPositionOrientation -> BasicMath Add_Vec4)
--   6 respawn after 3 s                       7 ForceStopPlayer (G: ends an activity)
--   8 the show: tooltip, sound, light, then the skydrop
-- Seen in the harness (2026-11-13): 1, 4 (spawned and removed), 5, 6 and 8 work; 3 turns the light golden (the
-- halfpipe intro's ambiance) but its later steps (night, noon) did not show; 2 posts without error (no sound in the
-- harness); 7 showed no effect on a rider who was riding.
-- Each script's id is its carrier's id block (resteep.json "id") + 0x800; the Alps' from 0x1F601000000, Japan's from
-- 0x1F602000000 (no kicker there).
local BASES = {STP_Alpes = 0x1F601000000, STP_Japan = 0x1F602000000}
local NAMES = {"tooltip", "sound", "light", "kicker", "skydrop", "respawn", "force stop", "the show"}
local picked = 1

local function base()
    local world = resteep.world.name()
    return world and BASES[world]
end

local function id_of(k) return (base() or 0) + (k - 1) * 0x1000 + 0x800 end

local function setting(key, default)
    -- the MODS page's value; the default where the session has no settings for the mod (get raises then)
    local ok, v = pcall(resteep.config.get, key)
    if not ok or v == nil then return default end
    return v
end

local function loaded()
    local out = {}
    for _, s in ipairs(resteep.domino.list() or {}) do
        local n = tonumber(s.id)
        if n then out[n] = s end
    end
    return out
end

local function run(k)
    if not base() then
        resteep.notify("domino showcase: only in the Alps and Japan", 4)
        return
    end
    local s = loaded()[id_of(k)]
    if not s then
        resteep.notify(k == 4 and "domino showcase: the kicker is only in the Alps"
            or "domino showcase: not loaded (yet): try again in a moment", 5)
        return
    end
    local ok, why = resteep.domino.start(s.id)
    resteep.notify(ok and ("domino showcase: " .. k .. " " .. NAMES[k]) or ("domino showcase: " .. tostring(why)), 3)
end

local function stop_all()
    local here = loaded()
    for k = 1, #NAMES do if here[id_of(k)] then resteep.domino.stop(here[id_of(k)].id) end end
    resteep.notify("domino showcase: stopped", 2)
end

resteep.on("key", function(key)
    if key == setting("next", "J") then
        picked = picked % #NAMES + 1
        resteep.notify(string.format("domino showcase: %d %s (%s runs it)", picked, NAMES[picked],
                                     setting("run", "K")), 3)
    elseif key == setting("run", "K") then
        run(picked)
    elseif key == setting("stop", "L") then
        stop_all()
    elseif setting("number_row", true) then
        local k = tonumber(key:match("^(%d)$") or "")
        if k and k >= 1 and k <= #NAMES then run(k) end
    end
end)
resteep.log("domino showcase: J picks, K runs, L stops (or 1-8); anywhere in the Alps and Japan")
