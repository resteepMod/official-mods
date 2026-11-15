# Helicopter mode (flies by holding the rider, with the game's own helicopter around it)

A step of [TODO 10](../../docs/todo/10-helicopter.md): fly the rider like a helicopter. The first version set the
rider's velocity every frame; in the game that moved nothing (TODO 10 "Step 1's result"). This one holds the rider
(`resteep.rider.hold`: the trainer's Fly with noclip) and moves it with `resteep.rider.set_position` from a flight
model in Lua; the game's helicopter (`STP_Helico`, the Alps' intro helicopter, moved with `resteep.prop`) flies
around it, the rider seated in its open left door. Folders starting with `_` are not loaded: copy this one to
`mods/helicopter/` to try it, and name it in the client mods.

**Alaska and Japan (switched off 2026-11-11: the game crashed 0.6 s after loading Japan with the copy;
the edit files stay, `resteep.json` no longer names them, until the harness finds the cause):** only the Alps place
the helicopter. This mod's world edits (`resteep.json` -> `assets/
helicopter_Alaska.json`, `helicopter_Japan.json`) copy the Alps' `STP_Helico` into those worlds' root cell (always
loaded), parked at the origin like the original, under the fixed id `0x2F000001000` that `main.lua` looks for after
the original's; its meshes come along from the Alps' archives (world.py apply: an add from another map, an add's
`"id"`). Built against your install at game start like every content mod (the launcher's mod build). Its pilot's and
ski box's closest models (LOD0) stay in `DataPC_extra_chr_onboarding`, which the copy does not bring along (G: that
archive is loaded in every world).

## Controls

The same in both flight models:

| | controller | keyboard |
|---|---|---|
| start (on foot and standing still: not on a board, skis or in the air) | BACK (Select on a PlayStation pad) | F8 |
| let go (the game takes the rider back; it falls from there) | B or BACK (Circle or Select) | F8 |
| cyclic: tilt (arcade) / pitch and roll (realistic) | left stick | I / K forward / back, J / L left / right (or numpad 8 5 4 6) |
| pedals: turn | right stick left / right | U / O (or numpad 7 / 9) |
| collective: up / down (released: hover thrust) | RT / LT | Y / H (or Page Up / Page Down) |

The letters work on a keyboard without a numpad; we believe Steep's default keys leave them free (not checked: its
bindings are in the save, not STEEP.ini), so if one also does something in the game, say so. While it flies the game
gets a neutral pad (the rider ignores the controller), the game's HUD is hidden (the activity card, challenge prompts;
`resteep.hud.hide`, back when you let go or the mod stops; the mod's own `HELI` line stays) and a chase camera follows
24 m behind, 7 m up (`resteep.camera.set`; 14 m and 5 m where there is no helicopter model).

## Settings (MODS page)

| setting | default | |
|---|---|---|
| Realistic flight | off | the flight model below; switches in flight too |
| Assist (realistic) | 50 % | levels the helicopter while the cyclic stick is centred and damps its turning; 0: none |
| Stick sensitivity (realistic) | 100 % | how hard the cyclic and the pedals turn it |
| Rotor speed (picture) | 100 % | 100 %: the game's drop scenes' rate |
| Rotor volume | 90 % | |

## The flight models

**Arcade (default):** the cyclic tilts the rotor disc up to 25 degrees (it springs back when you let go), the pedals
turn the heading, the thrust always holds the height with the collective released; ~45 m/s at full tilt, ~10 m/s
climb. It cannot tip over.

**Realistic:** a rigid body. The orientation is kept as the helicopter's three axes (no angles, so no gimbal lock: it
can point anywhere), turned each step by its angular velocity. The rotor's thrust acts along the helicopter's own
up axis: released collective gives 1 g (a hover when level), full RT 2.25 g, full LT -0.25 g. Tilted, part of the
thrust pushes it sideways and less holds it up: add collective in turns. Upside down the thrust pushes it **down**
(about 1.6-2 g with the collective released; LT is the inverted pilot's friend). The cyclic and pedals are torques against
the rotor's damping (top rates at full stick about 120-150 degrees a second in pitch and roll, 80-110 in yaw, less with more assist), plus
gravity, drag per axis (little along the nose, more sideways, most through the disc), damping of climbs and sinks,
ground effect (up to +8 % thrust near the ground) and a tail fin that turns the nose into the wind. On its skids the
released collective keeps it down: pull RT to lift off. A loop: some speed, then full back stick with a little RT;
it comes over the top inverted and back. The assist (setting) levels it when the stick is centred; at 0 % it keeps
whatever attitude it has. The `HELI R` line says `INVERTED` while upside down.

The rider cannot be turned (no API turns a held rider): it rides at the seat, but stays upright whatever the
helicopter does. Upside down the rider sits feet down in the inverted cabin (its head through the cabin floor),
banked it leans out of the door. Harmless, but it looks like that.

## Ground, rocks and crashes

With `resteep.world.raycast` (the game's own collision world, a ReSteep API in the works) the mod probes the skids,
the hull and the rotor disc against everything the game collides with (rocks, buildings, trees) with rays from the
helicopter's centre out to those points, and sweeps the frame's move so that it cannot pass through anything thin.
Without it (today's ReSteep) only the terrain counts (`resteep.world.ground`, a 4 m raster with no objects): the
helicopter flies through rocks and buildings. Arcade: it stops at what it touches and slides along. Realistic: a
landing on the skids settles level; a hit faster than 12 m/s, a blade touching anything, or the hull touching while
on its side or upside down is a **crash**: it stops where it is, upright on its skids, pushed out of what it hit, and
the rider stays seated in it (never thrown away; at most 3 m of push in a frame).

## Letting go: hovering and parking

F8 / B / BACK let go: the game takes the rider back (it falls from where it is). **In the air**, the helicopter's
pilot (the model has one) takes over: it levels out (from any attitude, upside down too), stops drifting and holds
the height where you let go, rotors and sound running, until you start again (it comes back to you) or the mod
stops. **On the ground** (let go on its skids, or it came down by itself) it is parked: the rotors spin down over 8
s and the sound fades out. Leaving the world, a crash of the rider or the mod switched off lets go as well; the mod
stopping puts the helicopter back where the map has it.

## Rotors and the seated rider

The rotors spin up over 4 s, at the speeds of the game's own drop scenes (main rotor 1000 degrees a second clockwise
seen from above, tail rotor 2000; TODO 10 "The drop scenes decoded"). **2026-11-15:** in the game they turned but
flickered. The cause (read from the running game): the game rebuilds the helicopter's final pose from its local pose
every frame, putting the rotor bones back to rest, a few milliseconds before the mods' frame wrote them turned again:
each picture showed one or the other. Now the turn goes into the **local pose** (`resteep.prop.set_bone(...,
"local")`): only the hub's rotation about its own axis, and the game's own update turns the blades with it. The log
says once `the rotors turn through the local pose` (good) or `the game does not take the local pose's turn` (then the
mod writes every bone into the final pose as before, and it flickers: say so). An older ReSteep without `"local"`
gets the old way.

The rider sits: the standing idles of the rider on foot play the game's sitting idle instead (`ID06_PS00_male/
female_SIT_IDLE`, `resteep.rider.play_anim`). In the game a held rider played `ID00_PS00_male_STAND_IDLE_Breaker_01/
03`, `ID01_..._Breaker_02_LEFT_STEEP`, `ID05_PS00_male_STAND_IDLE_04` and `ID05_PS99_male_STD` (the idle it returns
to after a breaker), which the first list missed. Now all the game's standing idles of these shapes (`ID0x_PSxx_<g>_
STAND_IDLE*`, `ID0x_PSxx_<g>_STD`: 112 male and 79 female clips in the game's list) are redirected, and every clip the
game looks up while flying is matched against those shapes, so a new one sits from its second time on (logged as
`... sits from now on`). The game looks an idle up only when it starts one, so the rider may stand for the first few
seconds, until its next idle. For the first 10 seconds the log names every clip the held rider plays. The rider keeps
the direction it faced at the start (the API cannot turn it), so it sits facing where the camera looked.

## Sound

The mod's own loops (`resteep.sound`, no game audio), from the helicopter's rotor hub, heard up to 500 m away (also
while it hovers on its own): `sounds/rotor_turbine.wav` (turbine whine, tail rotor, rush) and `sounds/rotor_slap.wav`
(the main rotor's blade slap at 8.33 a second: 3 blades at the picture's 2.78 turns a second). Both wind up and down
with the rotor (pitch and volume); the slap gets louder under load (collective, turning, sinking into its own wake);
a Doppler shift follows the helicopter's speed towards the camera. `sounds/rotor_loop.wav` (both in one) plays when
the layers are missing. All three are synthesised by `tools/sound/rotor_loop.py` in ReSteep (`--layer turbine`,
`--layer slap --seconds 3.6 --blade-hz 8.3333`, no option for the single loop).

The game's own helicopter sound was looked for (TODO 10 "Sounds"): the helicopter entity has no sound; the only
helicopter audio are the intro's and the drop scenes' whole soundtracks (one-shots of 25 and 12.5 s, rotor and scene
mixed, Wwise Vorbis). Using one needs a Wwise Vorbis decoder on the player's PC at build time (vgmstream; not in
ReSteep) and a loopable stretch found by ear: not done.

## Known limits

No collision with objects until `resteep.world.raycast` exists (see above), the rider keeps its heading and stays
upright while the helicopter turns, the helicopter itself has no collision for others, and Alaska and Japan have it
only with this mod's world edits built. The pad's sticks need the pad to reach mods (`resteep.input.read`); in the
test harness only the keyboard does.

## Tested

In the game (test harness, Alps, 2026-11-11): held, climbed +32 m, flew 46 km/h and rolled right with the
helicopter around the rider (screenshots); F8 off left it parked; the mod reloaded put it back at the map's place.
In the game (the player, 2026-11-15): the rotors turned (flickering: fixed since, see above); the rider stood.
Offline (2026-11-15): `luac -p`; a run of `main.lua` in plain Lua 5.4 against a stand-in `resteep` that rebuilds the
final pose from the local pose as the game does (32 checks: the arcade model holds its height; the rotors turn
through the local pose at 1000 deg/s, with both fallbacks; the seat covers the clips seen in the game and matches new
ones by shape; realistic: stays on its skids, climbs and hovers, a loop goes through inverted and comes back
upright, inverted thrust accelerates it down at ~1.6 g, a dive into the ground crashes onto its skids with the rider
never below the ground or moved more than 0.3 m in a frame, a slow descent lands on a slope; let go in the air it
stops and holds the height (from upside down too), on the ground it parks and the rotors and sound stop; with a
stand-in raycast it stops at a rock in both models, never inside it); the overlay's `"local"` pose in ReSteep's
script_test.

Credits: the gravity constant (9.8100004196167) and the shape of the arcade model's horizontal drag (`-D * |v_h|^2`
along the horizontal velocity) are the paraglider's, from **steep-gameplay-research** by Sean Shmulevich
(github.com/Sean-Shmulevich/steep-gameplay-research, `docs/systems/air/CLIENT_GUIDE.txt`), used with the author's
permission; the tuning values are ours.
