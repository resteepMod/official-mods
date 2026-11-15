# Checkpoint race

Build a course where you ride, race it, compare times on the server.
F5        add a checkpoint where you are (the first is the start, the last the finish)
F6        remove the last checkpoint      Shift+F6  remove the whole course
F7        back to the start (teleport; only on the ground)
The clock starts when you leave the start and stops at the finish; every checkpoint in between must be passed
in order. Times go to the server's leaderboard for this course (each course has its own board).

A script mod (`main.lua`, ReSteep's Lua API: MODDING.md).
