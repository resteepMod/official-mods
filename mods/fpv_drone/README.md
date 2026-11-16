# FPV drone

Launch a drone the way Steep's own drone takes off and fly it first-person like a real FPV quad in acro (rate)
mode: the sticks set how fast it turns, nothing levels it, the motors push along its top. Stand still on the ground
and press **G**: the drone spins up in front of the rider, rises, turns away, and the camera blends into its FPV
camera. **G** or **B** brings it back: the camera returns to the rider, the drone flies
back (from out of view if it was far), lands and spins down.

## Controls

| Gamepad (mode 2) | Keyboard | |
|---|---|---|
| left stick up / down | SPACE / C | throttle (in the "hover" mode the stick's centre hovers) |
| left stick left / right | Q / E | yaw |
| right stick | W / S, A / D | pitch, roll |
| d-pad left / right | arrow left / right | field of view -5 / +5 degrees (60 to 150) |
| d-pad up / down | arrow up / down | camera angle +5 / -5 degrees (0 to 60) |
| Y | R | upright where it is (after a crash) |
| B | G | bring it back |

Arming: the throttle low (in the hover mode letting go of the stick arms it). The d-pad's values stay: they are
the settings below, so the next flight starts with them. While the drone is out the game gets no input from you
(no time-of-day or replay menus from the d-pad) and its HUD is hidden.

## In a replay

Steep's replay (the quick menu's **Replay**: your last ride with the game's replay cameras) can be flown through
too, with a ReSteep that has `resteep.world.replay`: press **G** while it plays or is paused and the drone takes the
replay camera's place at once (no launch, the replay's rider is left alone), disarmed and hovering until the throttle
arms it. It flies, collides and crashes as usual, also while the replay is paused (the world stands still, the drone
does not). **B** or **G** gives the picture back to the replay's camera; so does the replay ending. Meanwhile the
replay's own controls get no input from you and the HUD is hidden. The range counts from where it started.

## Settings

Launch key, **Take-off and landing** (off: G puts the drone up in its FPV camera at once and brings it back at once),
throttle mode (stick centre hovers, full-range stick, right trigger), stick mode 1 / 2, Betaflight rates
(RC rate, super rate, expo), stick dead zone, thrust to weight, camera tilt and field of view (also on the d-pad),
**Drone model** (the game's drone, ReSteep's quad, or off), **Drone model in the FPV view** (off: put away while
you fly first-person, in case its props show at the picture's edges), **Motor sound** and **Motor volume**, and the
range from the rider.

## The model and the sound

- The model is on every map: the Alps, Alaska, Japan and every mod map you have on.
  - The game's drone (`STP_V_Drone_001_GoPro`, the one the rider throws in the game's idle) is the game's own, with
    its own look: at the launch the mod copies its entity template from the game's global data (Game Bootstrap
    Settings, loaded on every map) with `resteep.prop.spawn` (`show = true`: the template is stored hidden), and
    takes the copy away after the landing. Nothing of it is built or shipped. The copy keeps one frame of the
    template's launch clip, so the mod places it where the drone body's rest pose comes out at the drone. A ReSteep
    without `show` makes an invisible copy: the mod sees that and flies the quad instead.
  - ReSteep's quad (`assets/drone.glb`) is placed in each map's root cell (always loaded, `"map": "*"`) when the
    game starts and parked under the ground; it is drawn with a borrowed prop's materials.
  - The quad is world content, so changing the mod's version needs a game restart, and on a server it is a synced
    mod (every player needs it).
- The motor sound (`sounds/motor_loop.wav`) plays at the drone; its pitch and volume follow the throttle.
- Both files come from `tools/fpv_drone/make_drone.py` in this repository (formulas, no game data, CC0).

## Collision

With a ReSteep that has `resteep.world.spherecast` or `resteep.world.raycast` (the game's collision world: rocks,
trees, buildings) the drone sweeps along its motion each frame; otherwise it touches only the terrain raster
(`resteep.world.ground`, about 4 m apart), and only a hard hit along the slope's normal is a crash, so grazing the
approximate raster no longer crashes it.

`tools/fpv_drone/test_main.lua` runs the script against a stand-in for the game (`lua5.4 tools/fpv_drone/test_main.lua`).
