# butter: nose and tail butters on the snow

Hold **RB** while riding (snowboard or skis; skis can be switched off) and push the **left stick forward** to lean
onto the **nose**, **back** onto the **tail**: the further the stick, the more the board tips up and the rider's
weight goes over that end, while riding on (no braking, no pivot). Steering stays on the left stick's left / right,
the right stick is not touched. Letting go of RB ends the butter. Data and sandboxed Lua only (`main.lua`).

## How

Steep turns the sticks into four channels per axis, set in the input file `inputsettings_surfboard` (skis and
snowboard; tools/forge/HANDLING.md "The input file"; `python3 tools/forge/handling.py dump OUT`), once for slow riding
(`normalSettings`, below 7 m/s) and once for fast (`fastSettings`, above 12 m/s; blended between):

| channel | vertical axis as shipped | what it is |
|---|---|---|
| `attitude` | right stick, 0.785 rad (45 degrees) | the board's orientation target: vertical = pitch (`settings_surfboard` `attitudeSettings.pitch*`) |
| `buttering` | right stick | the game's own butters, most likely pivots on the nose / tail (clips `ID00_*_BUTTERING_{LEFT,RIGHT}_{NOSE,TAIL}`): the right stick's Y turned the rider sideways in the game when the first version of this mod sent it. The left stick never starts it (`additionalSettings.buttering.inputStickHint` = the right stick) |
| `steering` | left stick, 0.26 / 0.39 | what the left stick's Y does normally |
| `weightShift` | slow: none; fast: left and right stick, 0.785 | the rider's weight along the board (`riderSettings.legSettings` bowward / sternward offsets, up to 1 m): the forward lean at speed |

While the button is held the mod has the game parse a copy of that file (`resteep.handling.set`) in which the left
stick's Y feeds the board's pitch (*Board tilt*) and the weight shift (*Weight shift*) and no longer its steering, in
both speed bands; letting go puts the shipped file back (`resteep.handling.reset`): two parses per butter. The pad
the game gets meanwhile (`resteep.input.pad`) carries the left stick's Y shaped by the settings (dead zone, response,
invert) and scaled into 0..0.45, below the quick stop's threshold (stick back past 0.5 brakes), with the copy's remap
curves reaching the full lean at 0.45; RB itself is taken out. Each curve keeps its two samples, so the game's arrays
keep their size while the physics may read them.

A press while standing still (slower than *Start from*) or walking stays the game's: RB alone opens the sport wheel
there. In the air the left stick's Y is kept from the game (a held lean is no flip), and after letting go in the air
until the stick is back in the middle or the rider lands. After the butter the real pad is sent for 0.3 s (a mod's
pad lasts 250 ms after its last call).

**Log butters and animation clips** (setting): writes each butter and every clip the game looks up (by name,
`resteep.rider.anim_seen`) to the iSteep log (`powder_overlay.log`) and shows the lean on screen.

## Checked

Offline (2026-11-15): the native Lua host test (`native/bin/script_test.exe`) runs `main.lua` against a fake pad,
rider and input file: the copy changes the six curves in both bands, the stick is scaled, in the air there is no
lean, letting go restores the file and the pad. In memory (the player's game, read only, 2026-11-15): the free ride's
`inputsettings_surfboard` and `settings_surfboard` are loaded once each (with `settings_sledge` / `_speedriding`),
so `resteep.handling.set` reaches the file the rider uses. Not in the game yet: how far the board and rider lean.

## Open

- Whether the game's pitch target (`attitude.vertical`) shows as a pitch on the snow and how far:
  `settings_surfboard`'s `pitchAngleSpeedCurve` (0.2 standing to 1.0 from 35 km/h) and `pitchAngleImmersionCurve`
  (0.2 to 0.4) scale it, against a pitch spring of 5.5. If it is too little, those are the next knobs (a second
  `resteep.handling.set`, on the simulation file: changing it live is riskier, the mass hung the game).
- A live parse of the input file has not been seen in the game before this mod (the simulation file's has).
- The pose: which clips play while leaning (the debug log answers it). The rail presses (`GRIND_NOSEPRESS` /
  `GRIND_TAILPRESS`) bend the board's bones; whether a `play_anim` redirect fits the snow is open.
