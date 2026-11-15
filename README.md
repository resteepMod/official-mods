# official-mods

The official and example mods for [ReSteep](https://github.com/resteepMod/ReSteep). The launcher's Mods page lists them
in its **Official** tab: one click installs a mod (and the mods it needs) into your mods folder.

Every mod here holds data and sandboxed Lua only (no programs, no DLLs), like any `.resteep` package. The launcher
checks each download against the SHA-256 in `index.json` and then as it checks a mod file you add yourself.

## What is here

```
mods/<id>/          a mod's source, in the .resteep layout (manifest.json, resteep.json, README.md, main.lua, assets/...)
packages/           the packed mods, <id>-<version>.resteep (generated)
icons/<id>.png      each package's picture (generated)
index.json          what the launcher reads: id, version, description, kinds, dependencies, file, sha256, size (generated)
tools/              authors' generators that are not part of a package (e.g. tools/resteep_hill/make_hill.py)
```

**Examples** to learn from (script mods: `main.lua`; content: `resteep.json`): Speedometer, Air-time contest, Camera
effects, Crash log, Dev tools, Event notifications, Frame step, Golden hour, Markers, Boost, Checkpoint race, Hello
Config, Example Script, Example Animation, Example Helicopter, Challenge Example, Lua Hat Demo, Rider Colors, ReSteep
Boxes. **Content**: ReSteep Park, ReSteep Mountains, ReSteep Hill (Park and Hill use the same world: enable one),
Domino Playground, Domino Showcase, Physics Playground, FPV Drone, GoPro Stabilized, Master Chief Costume.

**Files a mod may not ship.** A mod can name a file the player downloads themselves (resteep.json `downloads`; e.g.
Master Chief's model, CC-BY on Sketchfab): its package holds no copy, the launcher's tile asks for the file, checks
it (data files only) and keeps it per player; ReSteep's build then fits it on the player's PC.

The docs for writing mods are in ReSteep's repository: `MODDING.md` and `docs/modding/`.

## Adding or changing a mod

1. Put the mod folder into `mods/` (its `id` in `resteep.json` is the folder name and must never change), or edit
   one. Raise `version_number` in its `manifest.json` for every change players should get: the launcher offers an
   update when the listed version is newer than the installed one.
2. Rebuild the packages and the index with a ReSteep checkout next to this repository:

   ```
   cd ../ReSteep && uv run python -m resteep index ../official-mods
   ```

   It packs every folder under `mods/` (the same files give the same bytes, so unchanged mods keep their file),
   removes packages no folder makes any more and refuses mods with code in them.
3. Commit the mod, `packages/`, `icons/` and `index.json` together. The launcher reads `index.json` from `main`.

Dependencies are Thunderstore-style (`"ReSteep-Base_Lib-1.0.0"` in `manifest.json`); the launcher installs the
listed ones first. `ReSteep-ReSteep-X.Y.Z` (the ReSteep version a mod needs) is added by `pack` from
`resteep.json`'s `"resteep"` and is never installed.

## Licence

AGPL-3.0, as ReSteep (`LICENSE`), unless a mod's `resteep.json` names another licence.
