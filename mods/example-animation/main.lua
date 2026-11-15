-- play_anim (docs/modding/animations.md): F10 turns the snowboard Melon into a Nosegrab, F10 again gives it back.
-- Both are game clips in the same sets, so the game has the Nosegrab loaded; for an animation of your own, replace
-- the donor (here the Nosegrab) with your .glb in resteep.json.
-- A grab is several clips: the reach, the hold (_LONG), and the hold while spinning or tweaked (_SPINLEFT, _TWEAK, ...);
-- every Melon clip of both riders has a Nosegrab twin, so all of them are redirected (only the reach and _LONG left the
-- tweaked/spinning hold a Melon: the player, 2026-11-10).
local VARIANTS = {"", "_LONG", "_SPINLEFT", "_SPINLEFT_LONG", "_SPINRIGHT", "_SPINRIGHT_LONG", "_TWEAK", "_TWEAK_LEFT",
                  "_TWEAK_LONG", "_TWEAK_RIGHT", "_TWEAK_SPINLEFT", "_TWEAK_SPINLEFT_LONG", "_TWEAK_SPINRIGHT",
                  "_TWEAK_SPINRIGHT_LONG"}
local GRABS = {}
for _, rider in ipairs({"male", "female"}) do
    for _, v in ipairs(VARIANTS) do
        local base = "ID00_PS00_" .. rider .. "_GRAB_"
        GRABS[#GRABS + 1] = {base .. "MELON" .. v, base .. "NOSEGRAB" .. v}
    end
end
local on = false

resteep.on("key", function(k)
    if k ~= "F10" then return end
    on = not on
    local ok = true
    for _, g in ipairs(GRABS) do ok = resteep.rider.play_anim(g[1], on and g[2] or nil) and ok end
    if not ok then
        resteep.notify("play_anim: not available in this game build", 4)
    else
        resteep.notify(on and "Melon -> Nosegrab" or "Melon as usual", 3)
    end
end)
