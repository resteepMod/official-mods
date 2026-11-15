# Air-time contest

Every landing after at least one second in the air counts; the longest goes to the server's
board "longest_air" (higher is better) and the top 3 show for a few seconds. Also shows custom events: it sends
"big_air" to every other mod, which can react with resteep.on("big_air", function(t) ... end).

A script mod (`main.lua`, ReSteep's Lua API: MODDING.md).

**Multiplayer:** yes, only you need it. Your best air time goes to the board of the server you play on (each server
keeps its own), next to the others who run the mod there. A landing after a mod held the rider in the air (a
helicopter, a drone) does not count. The server takes the values as the mod sends them.
