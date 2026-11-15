# resteep_hill: a hill of our own

A test massif in the `.resteep` layout (docs/modding/format.md "maps"): **RESTEEP HILL**, one smooth snow hill made
from a formula, to ride ground we built ourselves. It takes the park's world name (`STP_Slopes`): enable this mod or
mods/resteep_park, not both.

What it is: the menu world's valley (the WhiteRoom) cloned as `STP_Slopes`, its ground disc, firs, rocks and
buildings in the four valley cells removed (`assets/hill.json`), and in their place `assets/hill.glb`: 256 x 256 m
over x, y -128..128, a summit plateau in the north-west corner (about 57 m; the drop zone and the arrival stand
there), a fall line to the south-east with three rollers, a flat run-out at 2 m, banked rims along the edges. The
model borrows a granite rock for now (drawn with its rock material: the outskirts' snow, borrowed first, was not
drawn in the game; tools/forge/MAPS-CUSTOM.md "A hill of our own") and gets collision when the world is
built: per cell one MeshShape of the model's own triangles (`solid`, `"solid_mesh": true`; tools/forge/SHAPES.md),
as the game's snowpark pipes collide, powder snow (`ground`). Without `solid_mesh` it gets box slabs 2 m wide
(`solid_tile`), which meet within millimetres on this smooth surface (tools/forge/MAPS-CUSTOM.md "A hill of our
own"); the park's bumps came from the disc's noisy mesh.

`tools/resteep_hill/make_hill.py` (in this repository, not in the package) writes the model (`python3 tools/resteep_hill/make_hill.py`); `--edits <Steep folder>` also writes the edit list (the
removals' ids, read from the install). Change `height()` for another shape.

In the game (2026-11-06): the MeshShape collision carries the rider down the hill; with the outskirts' material
the model was not drawn, with the rock's it is (snow on top, rock cracks). The board did not sink in: the snow's
fluid profile is now copied along and the collision lies 0.3 m under the drawn surface (`solid_depth`). Open: a snow
material without rock (a prop of another map), the trails the shipped terrain shows.

**Multiplayer:** must match: it is a map, so every player on the server needs the same mod, and the server runs it
too (the server lists it; when you join, ReSteep shows it as missing or different if yours is not the same). ReSteep
Park, ReSteep Hill and ReSteep Mountains are one world (STP_Slopes): a server runs one of them, and you enable the
same one.
