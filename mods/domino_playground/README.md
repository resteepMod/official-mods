# Domino Playground

A Domino script of the mod's own in the Alps (`scripts/skydrop.json`, `content.scripts`): when that part of the Alps loads, the game's own script engine waits 5 s and drops you 400 m above the tutorial's start. F8 starts it again, F7 stops it.

**Multiplayer:** must match: its script is placed in the Alps (content.scripts), so every player on the server needs
the same mod, and the server runs it too (the server lists it; when you join, ReSteep shows it as missing or
different if yours is not the same). It drops only you; others see you fall from the sky.
