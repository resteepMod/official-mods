# Dev tools for mod authors

F9 writes where you are (position, velocity, air) and the world state to the MODS
console and shows it for a moment; hold Ctrl+F9 to keep it on screen. Positions are the game's world units
(metres, Z up) - the numbers resteep.zone() and resteep.teleport() take.

A script mod (`main.lua`, ReSteep's Lua API: MODDING.md).

**Multiplayer:** yes, only you need it; it reads and shows, it changes nothing.
