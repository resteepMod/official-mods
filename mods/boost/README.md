# Boost

Hold F7 and the rider goes where the camera looks, at a set speed. For getting around a map quickly
(a test world, a mod's own terrain). PAGEUP / PAGEDOWN change the speed (10..300 m/s, 60 at the start).
Works on the ground only, as every change of the rider's velocity (docs/modding/api.md "Player"): in the air
the flight path takes over, so it follows the slopes and lifts off over a crest.

A script mod (`main.lua`, ReSteep's Lua API: MODDING.md).

**Multiplayer:** yes, only you need it; others see you race along the ground (the game sends your movement as
usual). Not for races: the game's challenge times and mod boards would count a boosted run.
