# Script (example)

A Domino script of the mod's own (`scripts/wait.json`: In -> Delay 600 s -> Out), placed in the Alps by
`resteep.json`'s `content.scripts` next to where a new profile's tutorial starts. The game's own script engine runs
it when that part of the map loads. `main.lua` finds it with `resteep.domino.list()` and stops or starts it on F7
(`resteep.domino.stop` / `start`; a script that reached its end runs again on start).

Swap the graph for your own (docs/modding/format.md "Content: scripts" lists the operators a mod may use) and move
`at` to where it should run. Only a mod's own scripts can be started or stopped, never the game's.
