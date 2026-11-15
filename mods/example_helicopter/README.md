# Helicopter mode (flies by holding the rider, with the game's own helicopter around it)

A step of [TODO 10](../../docs/todo/10-helicopter.md): fly the rider like a helicopter. The first version set the
rider's velocity every frame; in the game that moved nothing (TODO 10 "Step 1's result"). This one holds the rider
(`resteep.rider.hold`: the trainer's Fly with noclip) and moves it with `resteep.rider.set_position` from a flight
model in Lua; the game's helicopter (`STP_Helico`, the Alps' intro helicopter, moved with `resteep.prop`) flies
around it, the rider in its open left door. It stays above the ground (`resteep.world.ground`). Folders starting
with `_` are not loaded: copy this one to `mods/helicopter/` to try it, and name it in the client mods.

**Alaska and Japan (switched off 2026-11-11: the game crashed 0.6 s after loading Japan with the copy;
the edit files stay, `resteep.json` no longer names them, until the harness finds the cause):** only the Alps place
the helicopter. This mod's world edits (`resteep.json` -> `assets/
helicopter_Alaska.json`, `helicopter_Japan.json`) copy the Alps' `STP_Helico` into those worlds' root cell (always
loaded), parked at the origin like the original, under the fixed id `0x2F000001000` that `main.lua` looks for after
the original's; its meshes come along from the Alps' archives (world.py apply: an add from another map, an add's
`"id"`). Built against your install at game start like every content mod (the launcher's mod build). Its pilot's and
ski box's closest models (LOD0) stay in `DataPC_extra_chr_onboarding`, which the copy does not bring along (G: that
archive is loaded in every world).

| | controller | keyboard |
|---|---|---|
| start (on foot and standing still: not on a board, skis or in the air) | BACK (Select on a PlayStation pad) | F8 |
| let go (the game takes the rider back; it falls from there) | B or BACK (Circle or Select) | F8 |
| tilt (fly that way): cyclic | left stick | I / K forward / back, J / L left / right (or numpad 8 5 4 6) |
| turn: pedals | right stick left / right | U / O (or numpad 7 / 9) |
| up / down: collective (released: hold the height) | RT / LT | Y / H (or Page Up / Page Down) |

The letters work on a keyboard without a numpad; we believe Steep's default keys leave them free (not checked: its
bindings are in the save, not STEEP.ini), so if one also does something in the game, say so. While it runs the game gets a neutral
pad (the rider ignores the controller) and a chase camera follows 24 m behind, 7 m up (`resteep.camera.set`; 14 m and
5 m where there is no helicopter model).

How it works: a flight model in Lua (`main.lua`: thrust along the tilted disc, quadratic horizontal drag, linear
vertical damping; ~45 m/s at full tilt, ~10 m/s climb) computes a velocity every frame, adds it to the held position
and puts the rider there (`resteep.rider.set_position`); then it puts the helicopter so that its left door (`SEAT`
in main.lua, by eye) is at the rider, turned to the heading and tilted with the cyclic (`resteep.prop.set` with a
matrix). F8 / B / BACK let go: the game takes the rider back and it falls from where it is; the helicopter stays
there (a helipad) until the mod stops, then it goes back to where the map has it. Leaving the world, a crash or the
mod switched off lets go too.

**Rotors and a seated rider (2026-11-15, not seen in the game yet):** the rotors spin up when the helicopter starts
and down after it lets go, at the speeds of the game's own drop scenes (main rotor 1000 degrees a second clockwise
seen from above, tail rotor 2000; TODO 10 "The drop scenes decoded"): `resteep.prop.set_bone` turns the hub and each
blade's bones about the hub every frame. Whether the game draws those bones is the open question: the log says once
`the rotor pose written stayed` or `was put back by the game` (then the rotors look still: say so). The rider sits:
the standing idles of the rider on foot are redirected to the game's sitting idle (`ID06_PS00_male/female_SIT_IDLE`,
`resteep.rider.play_anim`) while the mod flies; for the first 10 seconds the log names every clip the held rider
plays (`helicopter: the rider plays ...`): a standing one not in `STANDING` (main.lua) needs adding there. The
rider keeps the direction it faced at the start (the API cannot turn it), so it sits facing where the camera looked.

Known limits: no wall or object check (only the terrain's height), the rider keeps its heading while the helicopter
turns, the helicopter has no collision, and Alaska and Japan have it only with this mod's world edits built (see below). The pad's sticks need the
pad to reach mods (`resteep.input.read`); in the test harness only the keyboard does.

Checked in the game (test harness, Alps, 2026-11-11): held, climbed +32 m, flew 46 km/h and rolled right with the
helicopter around the rider (screenshots); F8 off left it parked; the mod reloaded put it back at the map's place.
Checked offline: `luac -p`; the hold calls in native/overlay's script_test (hold, set_position, one mod at a time,
let go when switched off). The flight model was run against a stub `resteep` earlier (hover holds, 34 m/s after 10 s
of full forward tilt, +9.6 m/s climb at full collective).

`sounds/rotor_loop.wav` is the mod's rotor loop (2 s, seamless, synthesised by `tools/sound/rotor_loop.py`, no game
audio); it plays once mods can play their own sounds (TODO 10 step 4).

Credits: the gravity constant (9.8100004196167) and the shape of the horizontal drag (`-D * |v_h|^2` along the
horizontal velocity) are the paraglider's, from **steep-gameplay-research** by Sean Shmulevich
(github.com/Sean-Shmulevich/steep-gameplay-research, `docs/systems/air/CLIENT_GUIDE.txt`), used with the author's
permission; the tuning values are ours.
