# Helicopter mode (flies by holding the rider, with the game's own helicopter around it)

A step of [TODO 10](../../docs/todo/10-helicopter.md): fly the rider like a helicopter. The first version set the
rider's velocity every frame; in the game that moved nothing (TODO 10 "Step 1's result"). This one holds the rider
(`resteep.rider.hold`: the trainer's Fly with noclip) and moves it with `resteep.rider.set_position` from a flight
model in Lua; the game's helicopter (`STP_Helico`, the Alps' intro helicopter, moved with `resteep.prop`) flies
around it, the rider seated in its open left door. Folders starting with `_` are not loaded: copy this one to
`mods/helicopter/` to try it, and name it in the client mods.

**In every map that can have one (0.7.0):** the Alps place the helicopter themselves (`STP_Helico` 0x1105920500E in
their root cell). **Alaska** gets a copy of it from this mod's world edit (`assets/helicopter_Alaska.json`), **Japan**
too (`assets/helicopter_Japan.json`; the setting **Helicopter in Japan**, `japan`, on by default, switches it off):
each copies the Alps' `STP_Helico` into the map's root cell (always loaded), parked at the origin like the original,
without its AnimComponent (`"drop"`), under the fixed id `0x2F000001000` that `main.lua` looks for after the
original's; its meshes come along from the Alps' archives (world.py apply: an add from another map, an add's `"id"`).
Built against your install at game start like every content mod (the launcher's mod build); the setting takes effect
at the next game start. Its pilot's and ski box's closest models (LOD0) stay in `DataPC_extra_chr_onboarding` (G:
loaded in every world). Mod maps (worlds of their own, such as the proving ground) get the same copy with the setting
**Helicopter on mod maps** (`custom_maps`, off by default: experimental, copies of another map's objects have crashed
a mod map on loading before; `assets/helicopter_maps.json`, a `"map": "*"` entry for the mod maps only). The WhiteRoom
is the menu world (nothing to fly in); there, and wherever the model is not loaded, the mod flies without a model
(the camera closer) and keeps looking for it every 2 s while flying.

**Why Japan crashed (2026-11-11/12) and what changed (2026-11-16, offline):** the copies of then were broken by
ReSteep's world.py, not by Japan: an add into a root cell from another cell cut the cell's prefetch list short (fixed
2026-11-13: that was the "any add into Japan's root cell crashes", the bench too), and `"drop"` cut the entity's own 48
bytes after its last component along with the AnimComponent (and left its component flag in the game state): every
dropped copy was malformed, so it crashed somewhere else every run. World.py now cuts exactly the 73-byte component, its
record and its flag, and a copy from another map's root cell (the same entry id in every map) brings its prefetch
records. Seen in the game 2026-11-16: Japan loaded with the copy and the helicopter flew there; on by default since.

## Controls

The same in both flight models, except the collective:

| | controller | keyboard |
|---|---|---|
| start (on foot and standing still: not on a board, skis or in the air) | BACK (Select on a PlayStation pad) | F8 |
| let go (the game takes the rider back; it falls from there) | B or BACK (Circle or Select) | F8 |
| cyclic: tilt (arcade) / pitch and roll (realistic) | left stick | I / K forward / back, J / L left / right (or numpad 8 5 4 6) |
| pedals: turn | right stick left / right | U / O (or numpad 7 / 9) |
| collective, arcade: up / down (released: hover thrust) | RT / LT | Y / H (or Page Up / Page Down) |
| collective, realistic: raise / lower the lever (it stays where it is set; ~2.5 s bottom to top at full trigger, slower with less) | RT / LT | Y / H (or Page Up / Page Down) |

The letters work on a keyboard without a numpad; we believe Steep's default keys leave them free (not checked: its
bindings are in the save, not STEEP.ini), so if one also does something in the game, say so. While it flies the game
gets a neutral pad (the rider ignores the controller), the game's HUD is hidden (the activity card, challenge prompts;
`resteep.hud.hide`, back when you let go or the mod stops; the mod's own flight HUD shows instead) and a chase camera
follows 24 m behind, 7 m up (`resteep.camera.set`; 14 m and 5 m where there is no helicopter model).

## Settings (MODS page)

Every setting takes effect at once, in flight too (the mod reads them at start and when one changes, never per frame).
The realistic model's sliders are factors on its terms: 100 % is 0.5.0's tuning; set one lower where it feels too
extreme, 0 % switches an effect off.

| setting (key) | range | default | |
|---|---|---|---|
| Realistic flight (`realistic`) | on / off | off | the flight model below; switches in flight too |
| Realistic: assist (`assist`) | 0-100 % | 20 % | damps the turn rates on top of the rate damping; it never levels the helicopter; 0: the bare rotor |
| Realistic: momentum (`momentum`) | 25-200 % | 100 % | the drag along the nose and sideways, inverted: lower slows down by itself (more drag, lower top speed), higher glides on |
| Realistic: rate damping (`damping`) | 25-300 % | 100 % | rotational inertia: higher, rolls / pitches / yaws stop sooner and top out lower |
| Realistic: cyclic rate (`cyclic`) | 25-200 % | 100 % | pitch and roll authority of the stick (it still follows the rotor's load) |
| Realistic: pedal rate (`pedals`) | 25-200 % | 100 % | yaw authority of the pedals |
| Realistic: stick expo (`expo`) | 0-100 % | 55 % | finer near the centre: `x * (L + (1 - L) * \|x\|)`, L = 1 - expo; 0: linear |
| Realistic: torque yaw (`torque`) | 0-200 % | 100 % | the main rotor's torque yawing the nose with the power |
| Realistic: collective lever speed (`lever_rate`) | 25-300 % | 100 % | RT / LT's lever travel; 100 %: 2.5 s end to end |
| Realistic: rotor thrust (`thrust`) | 80-200 % | 100 % | the blades' thrust at the lever's top: higher hovers lower on the lever (~50 % at 100 %), climbs harder |
| Realistic: engine power (`power`) | 80-200 % | 100 % | power for climbing and pulling g before the rotor droops; `TQ` and OVER-TORQUE are of this engine's 100 % |
| Realistic: thin air up high (`altitude`) | 0-150 % | 100 % | how much the air thins with height (thrust, power, blade stall); 0: sea-level air everywhere |
| Realistic: translational lift (`etl`) | 0-200 % | 100 % | the lift from clean air at speed |
| Realistic: ground effect (`ground_effect`) | 0-300 % | 100 % | extra thrust near the ground (+12 % on the skids at 100 %) |
| Realistic: vortex ring (`vortex_ring`) | 0-200 % | 100 % | its strength: higher reaches the full state sooner; 0: off (no lift loss, no buffet, no warning) |
| Realistic: retreating blade stall (`blade_stall`) | 0-200 % | 100 % | near VNE: pitch up, roll right, less lift; 0: off (the blades' load limit stays) |
| Realistic: low-g roll (`low_g`) | 0-200 % | 100 % | the right roll when the rotor unloads; 0: off (the LOW G warning stays) |
| Realistic: tail fin (weathervane) (`tail_fin`) | 0-200 % | 100 % | the fin turning the nose into the wind and damping the yaw at speed |
| Realistic: flare effect (`flare`) | 0-200 % | 100 % | how much more air through the tilted disc loads it at speed than in a hover (a flare's g and braking, a push's low g; translational lift follows it) |
| Arcade: top speed (`arcade_speed`) | 25-175 % | 100 % | ~160 km/h at 100 % (the drag, divided by the square) |
| Arcade: turn rate (`arcade_turn`) | 25-200 % | 100 % | ~70 deg/s at 100 % |
| Arcade: climb rate (`arcade_climb`) | 25-200 % | 100 % | ~10 m/s at 100 % |
| Rotor speed (picture) (`rotor_speed`) | 50-150 % | 100 % | 100 %: the game's drop scenes' rate |
| Rotor volume (`volume`) | 0-100 % | 60 % | |
| Rotor sound: close / far (`sound_balance`) | -100-100 % | 0 | below 0 the far loop quieter, above 0 the close one; +-100: only one |
| Hide the game's HUD (`hide_game_hud`) | on / off | on | the game's own HUD (activity card, prompts) hidden while flying; applies at once |
| Helicopter HUD (`hud`) | on / off | on | the mod's flight display (below); off: nothing drawn |
| Helicopter HUD: size (`hud_size`) | 50-200 % | 100 % | about its bottom centre |
| Helicopter HUD: opacity (`hud_opacity`) | 20-100 % | 100 % | |
| Helicopter in Japan (`japan`) | on / off | on | builds the copy into Japan (above); the next game start, not at once; Japan crashing on load: switch it off |
| Helicopter on mod maps (`custom_maps`) | on / off | off | builds the copy into every mod map that is on (experimental); the next game start; a mod map crashing on load: switch it off |

0.6.0 replaced "Stick sensitivity" (both axes) with the cyclic and pedal rates.

## The flight models

**Arcade (default):** the cyclic tilts the rotor disc up to 25 degrees (it springs back when you let go), the pedals
turn the heading, the thrust always holds the height with the collective released; ~45 m/s at full tilt, ~10 m/s
climb. It cannot tip over.

**Realistic (0.5.0: momentum and inertia, 2026-11-15):** a light single-engine helicopter, the AS350 / H125 class
the model is, flown by hand. A rigid body (the orientation kept as the helicopter's three axes, no angles, so no gimbal
lock) with:

- **The collective is a lever** (0-100 %, the HUD's `COL` bar): RT raises it, LT lowers it, at a limited rate, and it
  stays where it is set. Low in the Alps about **50 %** hovers (more in a climb, less in the ground effect near the
  ground); a little above or below and it drifts up or down. Lowered, it sinks (~10-14 m/s with the lever down).
- **Thrust is never negative**: the blades' pitch gives from ~0.1 g (lever down) to ~2 g (up) along the helicopter's
  own up axis. Tilted, part of it pushes sideways: add collective in turns. Upside down it pushes **down**, and nothing
  holds it up.
- **Momentum**: at speed little slows it (drag along the nose ~0.7 m/s² at 200 km/h): centring the stick and lowering
  the lever leaves it at ~200 km/h four seconds later. The tail fin keeps the nose in the wind (at 200 km/h full pedal
  holds only ~15 degrees of sideslip, the track hardly turns). To slow down or turn tightly at speed, tilt the rotor's
  thrust: **flare** (nose up: the air coming up through the disc loads the rotor, its thrust tilted back brakes) and
  **bank** into the turn, the lever as needed against the climb, and the nose comes round as it slows: a **J-hook**
  (from 212 km/h at ~2.3 g: 83 km/h and 94 degrees round in 4 s).
- **Rotational inertia**: the stick gives the rotor's turning moment, not a rate: rates build up while you hold it and
  go on when you centre it, until you counter (a small damping, more with the assist). At full stick ~100 degrees a
  second in pitch, ~115 in roll at speed (20 % assist; ~130 / 150 bare), less in a hover; a roll of ~60 degrees a
  second left alone halves in ~0.65 s at 20 % assist, ~1.2 s bare. **Authority follows the rotor's load**: with
  little thrust (lever down, low g) the cyclic is mushy. The stick is finer near its centre (an expo curve) for a pad.
- **Thin air up high**: the thrust and the turbine's power fall with the height (the world's z taken as metres above
  sea level): ~70 % hovers at 4000 m, ~75 % at 4800 m, where there is little power left to climb.
- **Power and torque**: the HUD's `TQ` bar is the main rotor's power (hover ~75 %, ~45-50 % at 80-120 km/h, the most
  at speed). Above 100 % it warns `OVER-TORQUE`; past 110 % (less up high, where the turbine runs out) the rotor droops
  (its sound drops a little) and gives no more thrust. Climbs are power-limited (~4 m/s straight up, more with speed).
- **Translational lift**: from ~30-40 km/h on the rotor flies in clean air and lifts more at the same lever (~+10 % at
  45 km/h; it climbs if you don't lower it a little).
- **Vortex ring state**: sinking fast (more than ~3-6 m/s) almost straight down with power on, the rotor settles into
  its own downwash: lift goes, the sink grows (`VORTEX RING`, it shakes). Out: forward cyclic for speed (the cure),
  or lower the lever (the ring breaks up, then fly out).
- **Torque**: the main rotor turns clockwise seen from above; more power yaws the nose **left**, less power right, unless
  you hold it with the pedals (right stick). The tail fin straightens it at speed.
- **Low g**: pushing over hard (or falling onto the disc) unloads the rotor: `LOW G` below 0.3 g, the cyclic goes
  mushy and it rolls right a little. No crash and no rotor strike (0.4.0's mast bumping is gone): it flies on.
- **Retreating blade stall** near VNE (80 m/s, 288 km/h; earlier with load and up high): `BLADE STALL`, the nose pitches
  up and it rolls right; too much load (beyond ~2.5 g) stalls the blades too. `VNE` warns near the top speed.
- Gravity, drag per axis (little along the nose, more sideways, most through the disc), ground effect (up to +12 %
  thrust near the ground).

**Loops and rolls** take timing: a roll at speed is full stick and then a counter-input before upright (~330 degrees
in ~4.5 s from 200 km/h, a little height lost); a loop wants ~170 km/h, back stick that keeps ~2 g with the lever at
~70 %, full back stick and the lever down to ~40 % over the top. A roll from a hover with the lever up falls while
upside down (the thrust points down): it needs height.

The rider cannot be turned (no API turns a held rider): it rides at the seat, but stays upright whatever the
helicopter does. Upside down the rider sits feet down in the inverted cabin (its head through the cabin floor),
banked it leans out of the door. Harmless, but it looks like that.

## The flight HUD

A small display at the bottom centre (`resteep.line` / `text` / `box`, the game's HUD hidden): on top a heading tape
(the number, ticks every 10 degrees, N E S W and every 30 degrees; the world's +Y taken as north); in the middle the
attitude indicator (the horizon, a pitch ladder every 10 degrees, dimmer below the horizon, the bank scale at 0 / 30 /
60 degrees with the pointer to the sky, the helicopter's symbol); left the airspeed in km/h and the vertical speed;
right the height above the sea (`ALT`, the world's z) and above the ground (`AGL`, a ray straight down); in the realistic
model also the g load, the `COL` (lever) and `TQ` (0-120 %, a mark at 100 %; amber over 100, red at the limit) bars and
the warnings in red (`OVER-TORQUE`, `LOW G`, `VORTEX RING`, `BLADE STALL`, `VNE`). The arcade model shows the attitude,
heading, speeds and heights. The setting Helicopter HUD turns it off; its size and opacity are settings too.

## Ground, rocks and crashes

With `resteep.world.raycast` (the game's own collision world, a ReSteep API in the works) the mod probes the skids,
the hull and the rotor disc against everything the game collides with (rocks, buildings, trees) with rays from the
helicopter's centre out to those points, and sweeps the frame's move so that it cannot pass through anything thin.
Without it (an older ReSteep) only the terrain counts (`resteep.world.ground`, a 4 m raster with no objects): the
helicopter flies through rocks and buildings. Arcade: it stops at what it touches and slides along. Realistic: a
landing on the skids settles level; a hit faster than 12 m/s, a blade touching anything, or the hull touching while
on its side or upside down is a **crash**: it stops where it is, upright on its skids, pushed out of what it hit, and
the rider stays seated in it (never thrown away; at most 3 m of push in a frame). Only impacts crash it: no
manoeuvre in the air does. After a crash the lever is down.

## Letting go: hovering and parking

F8 / B / BACK in the air: the first press hands it to the helicopter's pilot (the model has one) with the rider still
aboard, the second one is the jump out (the game takes the rider back; it falls from where it is). The pilot levels
out, stops drifting and holds the height where you let go, rotors and sound running, until you start again (it comes
back to you) or the mod stops; any stick or trigger takes the controls back. In the realistic model the pilot flies
it like you would (the lever at its rate, the cyclic against the rates' inertia, the pedals against the torque), so it
holds only about the height; let go upside down, it rolls it upright. **On the ground** (let go on its skids, or it
came down by itself, or crashed while hovering alone) it is parked: the rotors spin down over 8 s and the sound fades
out. Leaving the world, a crash of the rider or the mod switched off lets go as well; the mod
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

The mod's own loops (`resteep.sound`, no game audio), cut from the player's recordings of a real helicopter
(`tools/helicopter/make_loops.py` in official-mods, from `tools/helicopter/sources/close.mp3` and `far.mp3`):
`sounds/rotor_close.wav` (5.9 s next to a running rotor) and `sounds/rotor_far.wav` (6.9 s of a fly-by's approach).
Each stretch's slow swell is evened out and its length moved so that the blade slap runs on in step across the loop's
seam; both have the same loudness. Both play at the rotor's hub and are crossfaded by the camera's distance (equal
power): only the close loop within 25 m (the chase camera sits at ~25 m), only the far one beyond 120 m, half and half
at ~70 m; further away it gets softer (on top of the overlay's own falloff: the close loop is silent beyond 500 m, the
far one beyond 2 km). Pitch follows the rotor's speed (spin-up and spin-down: half pitch at rest), the load (a little
higher under power) and a drooping rotor (a little lower); volume follows the spin and the load; a Doppler shift
follows the helicopter's speed towards the camera. Rotor volume 60 % plays them a little under the earlier synthetic
layers. `sounds/rotor_loop.wav` (synthesised by ReSteep's `tools/sound/rotor_loop.py`) plays when the two loops are
missing.

The game's own helicopter sound was looked for (TODO 10 "Sounds"): the helicopter entity has no sound; the only
helicopter audio are the intro's and the drop scenes' whole soundtracks (one-shots of 25 and 12.5 s, rotor and scene
mixed, Wwise Vorbis). Using one needs a Wwise Vorbis decoder on the player's PC at build time (vgmstream; not in
ReSteep) and a loopable stretch found by ear: not done.

## Known limits

No collision with objects until `resteep.world.raycast` exists (see above), the rider keeps its heading and stays
upright while the helicopter turns, the helicopter itself has no collision for others, and Alaska and Japan have it
only with this mod's world edits built (Japan unless its setting is off); without its AnimComponent the copy may not take the
rotors' turn (G: then they stand still, the rest flies the same). The pad's sticks need the pad to reach mods (`resteep.input.read`); in the
test harness only the keyboard does.

## Tested

Offline (2026-11-16, 0.7.0, the other maps; with ReSteep's world.py fixes of that day): `world.py apply` of both edit
files on the install: Alaska and Japan each 1 cell written, 0 warnings; the copy is the Alps' entity with its ids
renumbered and its 73-byte AnimComponent, game-state record and flag gone (1686 -> 1598 bytes, 4 components), in no
data layer and no far-LOD group; the root cell's other resources byte for byte as shipped, its prefetch list whole
(Japan: 5 groups, 819 + 11 records) and every new record and every entry the copy links in the map, the shared
DataPC or the 48 entries copied along (none Alps-only). Japan and Alaska ship thousands of entities with a skeleton
and no AnimComponent (safety nets), so the copy is of a kind those maps load. The stand-in test (ReSteep's
`tests/lua/helicopter.lua`, 80 checks): the copy flown where only it is loaded, the Alps' own first, no model:
flown without it and found when it comes in, `prop.find` failing or a model refusing moves: no error.
**Not loaded in the game yet** (the test harness has no Japan; Alaska untried).

In the game (test harness, Alps, 2026-11-11): held, climbed +32 m, flew 46 km/h and rolled right with the
helicopter around the rider (screenshots); F8 off left it parked; the mod reloaded put it back at the map's place.
In the game (the player, 2026-11-15): the rotors turned (flickering: fixed since, see above); the rider stood.
In the game (the player, 2026-11-15, 0.4.0): the realistic mode flown; the rotor strike in negative g felt wrong,
turning at speed too easy, the sound poor: 0.5.0 answers those, not yet flown in the game.
Offline (2026-11-15, 0.6.0, the settings): with the defaults the same 59 checks give the same numbers as 0.5.0; 11
more: main.lua reads every key of `resteep.json` and no other, with the same defaults; none per frame (only at start
and per change); HUD size 150 % and opacity 50 % from the next frame; momentum 50 %, set at 212 km/h, loses 15 km/h in
4 s (100 %: 6), no jump; rate damping 200 % halves a roll pulse in 0.49 s (100 %: 0.73); vortex ring 0: the descent
under power that sinks deeper at 100 % stops sinking, no warning; low-g roll 0: the push-over (LOW G) rolls 0 degrees
right (100 %: 25); arcade at 50 %: 81 / 160 km/h, 34 / 69 deg/s; the sound's balance; every slider at its min, then
its max, switched in flight in both models while the sticks stir: no error, finite.
Offline (2026-11-15, 0.5.0): `luac -p`; a run of `main.lua` in plain Lua 5.4 against a stand-in `resteep` that
rebuilds the final pose from the local pose as the game does (ReSteep's `tests/lua/helicopter.lua`, 58 checks).
Arcade (unchanged): it holds its height; the rotors turn through the local pose at 1000 deg/s, with both fallbacks; the
seat covers the clips seen in the game and matches new ones by shape; hovering with the rider aboard, the jump out, the
hover and the parking after. Sound: both loops start, wind up with the rotor (pitch 0.55 -> 0.98), the close one at
the chase camera, half and half at 70 m, the far one alone at 300 m; `rotor_loop.wav` without them. HUD: lines and
texts drawn (heading, speed, heights, vertical speed; realistic: `COL`, `TQ`, g, warnings), nothing with the setting
off. Realistic, flown by a test pilot with stick and trigger values (no assist levelling): stays on its skids with the
lever down; RT raises the lever at its rate and it stays; a hover at ~50 %; the lever down sinks; 4000 m needs ~20
points more lever than 1000 m; a lever raise yaws the nose left without pedals; a fast vertical descent under power
goes into the vortex ring (the sink grows) and forward speed gets it out; a full roll from a hover with full
collective: no crash, caught upright; inverted with full collective it falls faster than gravity; a hard push-over at
speed: `LOW G`, no crash, it flies on; from 212 km/h the stick centred and the lever down: 206 km/h 4 s later, full
pedal turns the track 2 degrees in 3 s, a J-hook (flare + bank, ~2.3 g) 83 km/h and 94 degrees in 4 s; a 0.3 s roll
pulse in a hover leaves half its rate 0.7 s later and a counter-input stops it in 0.6 s; a roll at 212 km/h (330
degrees in 4.4 s), caught upright; a loop from 51 m/s at ~2 g comes back upright with positive g all the way; the pilot
holds a hover with the rider aboard and rolls it upright when let go upside down; a dive into the ground crashes onto
its skids with the rider never below the ground or moved more than 0.5 m in a frame; a slow descent lands on a slope;
with a stand-in raycast it stops at a rock in both models, never inside it; the overlay's `"local"` pose in ReSteep's
script_test.

Credits: the gravity constant (9.8100004196167) and the shape of the arcade model's horizontal drag (`-D * |v_h|^2`
along the horizontal velocity) are the paraglider's, from **steep-gameplay-research** by Sean Shmulevich
(github.com/Sean-Shmulevich/steep-gameplay-research, `docs/systems/air/CLIENT_GUIDE.txt`), used with the author's
permission; the tuning values are ours.
