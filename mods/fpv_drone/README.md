# FPV drone

Launch a drone the way Steep's own drone takes off and fly it first-person like a real FPV quad in acro (rate)
mode: the sticks set how fast it turns, nothing levels it, the motors push along its top. Stand still on the ground
and press **G**: the rider takes the drone pose, the drone spins up in front of them, rises, turns away, and the
camera blends into its FPV camera. **G** or **B** brings it back: the camera returns to the rider, the drone flies
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

## Settings

Launch key, throttle mode (stick centre hovers, full-range stick, right trigger), stick mode 1 / 2, Betaflight rates
(RC rate, super rate, expo), stick dead zone, thrust to weight, camera tilt and field of view (also on the d-pad),
**Drone model** (the game's drone, ReSteep's quad, or off), **Drone model in the FPV view** (off: put away while
you fly first-person, in case its props show at the picture's edges), **Motor sound** and **Motor volume**, and the
range from the rider.

## The model and the sound

- The model is placed in the Alps' root cell (always loaded) when the game starts and parked under the ground; the
  mod moves it with `resteep.prop`. The game's drone (`STP_V_Drone_001_GoPro`, the GoPro drone of the game's own drone
  scenes, whose rider poses this mod borrows) is rebuilt from your own install by ReSteep's build, never shipped here; ReSteep's quad is
  `assets/drone.glb`. Both are drawn with a borrowed bench's materials (the game's drone material is a character
  material, which crashed on a static model), so they look like the shape in wood and snow for now. Alaska, Japan
  and custom maps have no model yet (the drone flies without one there). The mod has world content, so changing
  its version needs a game restart, and on a server it is a synced mod (every player needs it).
- The motor sound (`sounds/motor_loop.wav`) plays at the drone; its pitch and volume follow the throttle.
- Both files come from `tools/fpv_drone/make_drone.py` in this repository (formulas, no game data, CC0).

## Collision

With a ReSteep that has `resteep.world.spherecast` or `resteep.world.raycast` (the game's collision world: rocks,
trees, buildings) the drone sweeps along its motion each frame; otherwise it touches only the terrain raster
(`resteep.world.ground`, about 4 m apart), and only a hard hit along the slope's normal is a crash, so grazing the
approximate raster no longer crashes it.

`tools/fpv_drone/test_main.lua` runs the script against a stand-in for the game (`lua5.4 tools/fpv_drone/test_main.lua`).
