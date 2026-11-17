# world_editor: edit the world from the overlay menu

A **World editor** panel in the in-game overlay (N or Home, MODS page, the card's PANEL) to add objects to the
world, and to move, turn, scale and remove the ones that are there, from the panel or with a **free camera** and the
mouse. The edits are kept by the server. Steep loads its world cells from its archives, so an edit shows when the
game **reads its cell again**: with the live helper (below) the overlay makes the game read the edited cells around
the rider again at once (elsewhere: when they stream in); without the helper, at the next game start.

The mod is data and sandboxed Lua only (since 2026-11-15; until then the panel was a DLL, `src/`, see the history):
what it needs from native code is ReSteep's own, built into the overlay with a Lua API (docs/modding/api.md).

| part | file | what it does |
|---|---|---|
| client (panel, free camera) | `main.lua` (the overlay runs it: `resteep.ui`) | position, cell, nearby objects, add / move / turn / scale / remove, edit list with undo; the free camera's tool window |
| server | `mod.lua` | keeps the edit list (`/_powder/world_editor/...`, in the server's database) |
| session step | `tools/forge/worldedits.py`, run by the launcher (`resteep/session_steps.py`) | at each game start: the edits -> edited cells (`tools/forge/world.py apply`), and the panel's object index (`world.py index`) beside the game, `powder_mods/world_editor/` (main.lua reads it with `resteep.data`) |
| live helper | `tools/forge/worldlive.py` (started by the session step) | for the session: each change of the edit list -> the changed cells, in `powder_mods/world_editor/live/` |
| live edits | the overlay: `native/overlay/worldlive.cpp` | serves those cells in place of the archives' bytes as the game reads them (ntdll file hooks); main.lua shows the state (`resteep.world.live()`) |
| cell reload | the overlay: `native/overlay/cellreload.cpp` | after each new set of cells: the engine releases each changed cell it has loaded, its streamer loads it again |
| edited objects | the overlay: `native/overlay/liveobjects.cpp` | loaded objects the edits touched put where the edits say (`live/objects.tsv`, below) |
| free camera | `main.lua` | fly (`resteep.camera.set`, `input.capture`, `input.mouse`, `world.freeze`), pick objects by their boxes (`input.pointer`), carry them with the mouse |
| live preview | `main.lua` | the object itself follows G / R / S while the tool runs (`resteep.prop`: the engine's own transform update) |
| instant adds | `main.lua` | a copy of the loaded source stands where an add goes until its cell brings the real one (`resteep.prop.spawn`; a setting, experimental) |

## Enable it (Linux, powder-wrap)

```
native/build.sh overlay     # the overlay (the editor itself needs no build)
```

In Lutris' environment for Steep (then restart Lutris), or switch the tile on in the ReSteep window's Mods page:

```
POWDER_OVERLAY=1
POWDER_CLIENT_MODS=world_editor        # with other mods: comma-separated; names Lua mods too
```

Not together with `asset_trace`: both hook ntdll's file functions, and a function is hooked once (whichever loads
second gets no hooks; the panel says "live edits off: could not hook ...").

The server runs `mod.lua`; without it (mod off or not loaded) the panel cannot store edits, and a session uses the
last list it fetched. Optional:

- `WORLD_EDITOR_MAPS=Alpes,WhiteRoom` - the maps whose index is built and put beside the game (default all four).
  The first game start indexes each map once (~20 s for an open-world map, cached in `~/.cache/powder/world_editor`
  until a game update changes the archives), and outlines its placeable props (`tools/forge/outline.py`, ~15 s,
  cached the same way: `outlines/<Map>/<prop>.tsv` beside the index; each in the prop's own frame, longest edges
  first, the header the rotation of the instance an add copies), the wireframes the free camera and the ghost draw.
- `WORLD_EDITOR_ADDS=0` - leave the added objects out (keep the moves, turns, scales and removes), see below.
- `WORLD_EDITOR_LIVE=0` - no live helper: edits show from the next game start only (the overlay then hooks
  nothing).

## Use it

1. In-game press **N** or **Home**, open the **MODS** page, the card **World editor**, its **PANEL**.
2. The **map you ride in** (Alpes, Japan, Alaska, or WhiteRoom = the main menu's scene): it starts on the world the
   game is in, else on the map of your newest edit; pick another to see its edits. Its index loads over a second
   or so (`loading the <map> index...`).
3. The top shows your position and the 128 m cell you are in.
4. **Add an object (experimental)**: filter the list (`sapin` = firs, `rock`, `kick`, `bench`, ...; `*` marks
   favourites), choose one, set *metres in front* (along the direction you last rode), *height offset*, *turn* and
   *scale*, press **Add here**. With *on the ground* (on by default) it stands on the terrain there, *height
   offset* above it; without it, at your height plus the offset. Each prop is a copy of one placed instance of it,
   so it keeps that instance's tilt. While the section shows, a **ghost** (the prop's outline in cyan: the edges of
   its model, turned, scaled and tilted as the add will be, on the overlay's terrain height) stands where **Add
   here** puts it; a prop without an outline shows its box in the free camera.
5. **Objects near you**: the objects within the radius (props only; tick *also cameras, anchors, FX* for the rest -
   moving the menu's camera anchors or spawn points breaks things). Select one, then **Move** (to the position in
   the fields; *to me* / *to in front* fill them), **-90 / -15 / +15 / +90 / Turn**, **x0.8 / x1.25 / x2 / Scale**,
   or **Remove**; **Onto the ground** sets it on the terrain under it. Moved objects should stay within their cell (the panel warns): far moves are better done as
   remove + add.
6. **Free camera (edit with the mouse)** (the button under the position, or in the game the hotkey **F4**: the
   setting *Free camera edit mode: hotkey*, again or Esc leaves): the menu closes, the world holds still, and the
   keys are Blender's:
   - *View*: **middle mouse** orbits about the selection (or a point ahead), **Shift + middle** pans, the **wheel**
     zooms; the **right mouse button** held looks around and flies with **WASD**, **Q/E** down/up (Shift fast, Ctrl
     slow, wheel: speed); **Numpad .** or **F** frames the selection.
   - *Select*: the object under the pointer shows its wireframe (white); a **click** selects it (yellow). The
     wireframe is the prop's outline put where the object stands: the loaded entity's own matrix (tilt included)
     while it stands where the edits put it, else the index's turn and scale (no tilt). A running tool draws it
     (cyan) where the tool will leave it. Groups (their parts are not in the index), content mods' models and
     objects without an outline show their box instead. At most 300 lines for the selection or a tool, 150 for
     the one under the pointer (the longest edges first); a mod draws at most 512 things a frame.
   - *Tools*: **G** move, **R** rotate, **S** scale, **Shift+D** duplicate (then move), **Shift+A** place the prop
     chosen in the panel's list (its ghost follows the pointer), **End** onto the ground (the terrain under it), **X** then **X** (or Enter) within 3 s / **Delete** remove (a single X only asks: it is also the axis lock inside a tool),
     **Ctrl+Z** undo. In a tool: **X / Y / Z** lock to the map's axis, the same key again to the object's own axis, once more free; **Shift + X/Y/Z** keeps that axis out
     (move in the other two: Shift+Z moves on the ground plane); **type a number** for the amount (metres, degrees,
     factor; Backspace, - negates); **Ctrl** snaps (0.5 m, 5 degrees, 0.1); G / R / S switch tools; a **click** or
     **Enter** applies it (one edit), a **right click** or **Esc** cancels. A move without a lock follows the pointer
     in the plane facing the view; R without a lock turns about Z; scaling is uniform only. Turns about X or Y are
     `rotate` edits (tilts).
   - **Live preview**: G / R / S on one of the game's own objects move **the object itself** every frame, not only
     its box, the way the edit will place it (main.lua's `preview` math, checked against world.py's by
     `tests/test_world_editor_preview.py`); the tool's header says `(live)`. **Esc** / right
     click puts it back; a click / Enter saves the edit exactly as before (server, helper, live cells) and leaves
     the object where it is, which is where its reloaded cell puts it. The server refusing the edit (the rules),
     or undoing it (Ctrl+Z, *undo*, *Clear all*), puts the object back at once. An added object moves by the id
     its copy got (the helper's `live/adds.tsv`), a group by its member entities (the index lists them, v3), turned
     and scaled about the group's origin as world.py does. Objects it cannot move keep the drawn outline (or box)
     only, and the tool window says why: new props and models (not in a cell yet), an added object the helper has not written yet,
     what the engine does not hold as a plain entity, a cell not loaded. Once the object stands where the edit puts it,
     the mod lets it go (`resteep.prop.keep`): switching the mod off does not move it back. The engine moves objects in its
     own update, which a held world skips: with *hold the world* on, the world runs while the object follows and
     until it stands where the tool left it, then holds again. A cell reloaded during the tool ends the tool
     (start it again). Not tried in the game yet: whether every kind of prop is drawn at its new place (the
     helicopter is; static props may be drawn from their cell's instance data until it is reloaded) and whether
     its collision follows (it does once the cell is reloaded).
   - **Instant adds** (setting *Instant adds (experimental)*, off by default; 2026-11-15, **not tried in the game
     yet**): a duplicate (Shift+D), a prop placed with Shift+A or *Add here* whose source object is loaded shows at
     once: the game copies the loaded object (`resteep.prop.spawn`, the engine's SpawnEntity way: native/overlay/
     prop.cpp) and the copy stands where world.py will put the add (the source's matrix moved to the edit's
     position, turned by its yaw, scaled) while the server, the helper and the cell reload make the real one. The
     stand-in goes when the add's own copy is loaded (both stand at the same place for that moment), when the
     server refuses the add, when a later edit moves or removes it or the add is undone, after two minutes (live
     edits off: the cell is not read again) and with the world. It shows only what the source's cell loaded: a
     prop copied from far away gets no stand-in.
   - **Edits while the world is held**: the streamer loads a released cell again, and a moved object takes its
     place, in the world's update, which a held world skips. While an edit is applied (its cell queued or loading
     again, the first object passes) the overlay lets the world run, at most 10 s, and holds it again
     (`stop mode: the world runs while live edits are applied` in powder_overlay.log, which also logs each reload's
     outcome and why a listed object near the rider could not be moved).
   - **Esc** (or *Leave*, or the hotkey) gives the camera back. The camera can fly anywhere, but the world streams
     around the rider (~700 m): far away, cells are missing and edits show once the rider comes (the tool window warns).
7. **Edits**: every edit of the map, newest first (the newest 150), each with **undo** (undoing an added object
   also undoes its later moves); **Undo last**, **Clear all...** (asks once more). The status line shows the
   server's answer.
8. **See it**: under the edit list the panel says `live: N cell(s) replaced` once the helper has written the cells
   (a second or two; `live: writing the cells of edit #N...` until then). A changed cell the game has loaded is
   released and read again at once (`<map> cell N: reloaded in 0.07 s`); one that is not loaded shows when it
   streams in. *live cells* lists each cell, whether it was
   fitted into its entry ("same size") or needed the index redirected ("bigger"), and `read N time(s)` once the game
   has read it again.
9. At the next game start everything is in the session's `_patch_03` anyway: the session log
   (`$XDG_RUNTIME_DIR/powder-wrap.log`) shows `mod world_editor: session step done` and
   `asset mods: DataPC_STP_<Map>_patch_03.forge (N entries)`.

**Who may edit** (docs/todo/11-shared-world-editing.md): the in-game menu sends the player's menu ticket (the
launcher gets it for its account: `/_powder/account/menu-ticket`), so the server tells the mod who edits; every
edit keeps its author. By default only the server's admins (`[server] admins`) edit; the server's own PC without
a ticket counts as its host (an admin), except on a `[server] public` server. The rules, changed by an admin with
`POST /_powder/world_editor/rules` (and shown by `GET` with what you may do): `edit` = `admins` | `everyone` |
`off`, `undo_others` (default true: players may undo and change other players' edits), `shipped_objects` (default
true: players may change the game's own objects), `max_adds` / `max_edits` per player (0 = no limit),
`blocked_props` (parts of prop names players may not place; the server checks the name the panel sends, and
since a modified client could send another, every player's build checks the real name too: `world.py apply
--blocked`, from the list the server sends along; an admin's edit is exempt). Admins may always do everything; only they clear a
map, and remove all of one player's edits (`POST .../purge {"by": profile id}`). In the panel, the edit list names
each edit's author; admins get **Server rules (admin)** under it (who may edit, undoing others' edits, the game's
own objects, the limits; **Apply rules**) with each author's count and **remove all of theirs**; players see
whether they may edit. *Undo last* / Ctrl+Z undo your own newest edit of the map. The panel's status line shows why an edit was
refused. Players who join see the edits only from the next step of the task (sync), not yet.

Content mods' world edits (`.resteep` expansions with `content.worlds`, built by tools/forge/compose.py) come
first: the session step writes the cells of every map they change with their edits in front of the player's (so the
session's `_patch_03` and the live cells keep their objects; powder-wrap takes the session step's copy of a cell
over compose's), and the panel shows their objects (`content_edits.json`, their models' boxes in `models.tsv`
beside the indexes). They can be moved, turned and removed like added objects: the edit names them by their number
(`of` >= 1,000,000, which mod.lua accepts without finding them in its list).

## How it works

- **Stored edits** (`mod.lua`): `GET /_powder/world_editor/edits` gives `{"version": 1, "next": N, "edits": [...]}`;
  `POST .../edits` adds one (`add` with a source entity, or `move`/`turn`/`scale`/`remove` of a shipped object
  `obj = {layer, cell, id}` or of an added one `of = n`; `ground {offset}` puts it on the terrain under it, that many
  metres up (world.py apply reads the map's .tbf; a later `move` sets an explicit height again; an `add` takes
  `"ground": offset` too); `rotate {axis: x|y|z, deg, local}` turns about the
  map's axis through the object's origin, or its own; `add` may name a content mod's `model` instead of `src`),
  `POST .../undo {"n": N}`, `POST .../clear {"map": M}`.
  Checked (maps, ops, ids, finite numbers in range, at most 2000 edits) and saved with `api.save` (the server's
  SQLite database, scope `mod:world_editor`). Each session also keeps a copy in `<data>/world_editor/edits.json`.
- **Session step** (ReSteep's own, `resteep/session_steps.py`, built in for this mod id: no script of the mod runs;
  powder-wrap runs it for a named mod before it builds the asset mods, the Windows launcher at Play inside
  `resteep.build.build_all`, after compose, when the mod is switched on): `tools/forge/worldedits.py session` fetches
  the list from the running server (falls back
  to that copy), runs `world.py apply <map> edits.json` per map into the launcher's per-session folder
  (`POWDER_MOD_FORGE`; powder-wrap packs it into `<Map>_patch_03.forge`, the Windows launcher into its patches, in
  front of compose's; never into `client/`, which the server publishes to launchers), and copies the index files into
  `powder_mods/world_editor/` beside the game (removed with the session; on Windows staged and copied there once the
  launcher has deployed the menu's `powder_mods\`).
- **Live helper** (`tools/forge/worldlive.py run`, started detached by the session step when the overlay is on; stops when the
  session's runtime folder goes, when the Windows launcher ends it at the game's end, or after 3 minutes without the
  server): asks the server for the list when the panel
  pokes it (`live/poke`, after each edit the server took) and once a minute otherwise (edits made elsewhere);
  per changed map it applies the list as `world.py apply` does, in its own process on the map's archives, cells and
  prefetch blobs parsed once and kept (read right after the session starts; an edit then costs ~0.2 s on the Alps
  with 70 edits, a new `world.py apply` process ~2.5 s) and compares every cell it makes, and every cell any list
  changed before (also the session's own, which are in `_patch_03`), with what
  the game reads for that entry: the newest copy in the stack, `_patch_03` included. A cell that differs goes into
  `powder_mods/world_editor/live/` as a whole datafile, fitted to exactly the entry's size when it can be (forge.py
  `fit_datafile`: recompressed at zstd 9, 3, 19 or 22, then padded with empty zstd blocks; "same"; a cell
  unchanged since the generation before keeps its datafile), else as it is ("grow"), and into
  `manifest.tsv` (written last; its format is in worldlive.py's docstring). An undone edit makes its cell the shipped one
  again. `worldlive.py once --base A --edits B --out DIR` does one step by hand.
- **Live edits in the game** (the overlay: `native/overlay/worldlive.cpp`, started once the session step made
  `powder_mods\world_editor\`): it polls the manifest (every 0.2 s) and hooks ntdll's `NtReadFile`
  (plus `NtCreateFile`/`NtOpenFile` for the names, `NtSetInformationFile` and `NtRemoveIoCompletion[Ex]` for
  completion ports) once a helper runs. A read of an archive that overlaps a served cell is done privately, the
  cell's bytes are copied over the archive's, and the read is completed for the game as Windows would (event, APC,
  or completion packet), so the game never sees unpatched bytes. "grow" cells: the game holds each archive's index as
  one array of `{u64 offset, u64 id, u32 size, u32}` records (`tools/forge/WORLD-LIVE.md`, "The archive index in memory");
  the overlay finds the cell's record (a read-only scan, checked against its neighbours) and points it at a slot past the
  end of the archive, whose reads it answers. An add's dependencies (the copied prop's meshes, shapes, textures:
  world.py names them in the cell's prefetch blob) are loaded only if the game's prefetch row of the cell names them,
  and the game read those rows at its start: for a cell whose blob changed the helper writes a `prefetch` line and
  the blob (`<id>-<hash>.pf`), and the overlay points the cell's row (found like the record, checked by the shipped
  blob's hash) at a copy of it in memory of its own, before the cell is released (WORLD-LIVE.md "Prefetch rows in
  memory"). It writes nothing else into the game, and gives the record and the row their own values back when the
  cell no longer needs them. It logs to `powder_overlay.log` (`[world_live]`): `live: generation N`, how the
  game's reads complete (once per archive), `index record(s) found`, `index record restored`, `prefetch rows found`,
  `prefetch row pointed at the copy's dependencies`, `prefetch row restored`.
- **world.py apply** folds the list (later edits act on where earlier ones left an object), writes one cell per
  changed cell (moves and removes also update the object's proxies in the neighbouring cells), puts each added copy
  into the finest existing cell at its position (ids `0x1F0_0000_0000 + (cell << 20) + (k << 12)`, as `edit --copy`),
  and skips (with a warning) what no longer matches the archives.
- **world.py index**: every placed entity and group (id, cell, position, yaw, scale, bounding box, name, prop), one
  tab-separated line each; placeable props are the entities with a prop template (one example instance each).

By hand (outside a session): `tools/forge/worldedits.py generate --edits <edits.json> -o DIR` writes the cells to
look at with `world.py show <map> <cell> --dir <folder>`; `worldedits.py index --out DIR` builds indexes.

## What to test in-game

1. **The panel**: it appears in the Mods tab, the position changes as you ride, the cell number fits (WhiteRoom:
   the rider stands near (0, 0, -0.9), cell 27/28/35/36 around the origin; G: that the trainer's position is the
   map's coordinates). Nearby objects listed with sensible distances (the WhiteRoom's firs and rocks 20-60 m away).
2. **Remove** (no copies involved): in the WhiteRoom, remove the 36 m fir `STP_WOR_GEN_VEG_Sapin_Big_S4_01_C_001`
   (26, 63) or a rock; restart; it is gone. Then **Move** a rock next to the rider, **Turn** and **Scale** it.
   `WORLD_EDITOR_ADDS=0` keeps any added objects out of this test.
3. **Add** (experimental): add a fir (`Sapin_Medium`) 6 m in front in the WhiteRoom, restart. Copies of firs render
   (mods/world_test (removed 2026-10-27, in git history), 2026-10-27) but showed a long thin white diagonal bar across the menu scene whose cause is not
   known yet: expect it with copies until world_test's bisecting finds it.
4. **Open world**: a remove or move of a hand-placed prop (a bench, a sign, a `STP_GEN_ROCK_*` rock) in the Alps,
   ride to it after a restart; then an add of a kicker or bench, and whether you collide with it.
5. **Undo**: undo an edit, restart, it is back as shipped.

### Live edits (new 2026-10-27, not tried in-game yet)

Same setup (`POWDER_OVERLAY=1`, `POWDER_CLIENT_MODS=world_editor`, not with `asset_trace`), after
`native/build.sh overlay`. powder-wrap's log should show `world_editor: live helper started` and
`world_editor live: watching the server's edits`; the panel `live: 0 cell(s) replaced ...`.

1. **Same size, WhiteRoom** (the menu scene; nothing streams out there, so this checks the menu reload): remove a
   rock near the rider; the panel shows the cell `(same size): waiting for the game to read it`. Go into the open world
   and back to the menu (or anything that reloads the WhiteRoom). Expected: the rock is gone, *live cells* says
   `read N time(s)`.
2. **Same size, open world**: in the Alps, ride to a hand-placed prop (a bench, sign, `STP_GEN_ROCK_*` rock), **Move**
   it a few metres and **Turn** it. Ride ~500 m away (watch the panel's cell number change a few times), wait a few
   seconds, come back. Expected: it stands at the new place. Then **undo**, away and back: it is back.
3. **Bigger cell**: **Add** a kicker or bench where the cell has nothing like it (a small cell: few objects in
   *Objects near you*). *live cells* should say `(bigger: index redirected)`; `powder_overlay.log` has
   `index record(s) found in N ms` (expect 1; a few seconds for the scan). Away and back: the copy is there. Undo:
   `index record restored`, away and back, gone.

| you see | meaning |
|---|---|
| `live edits off: no session helper` | `worldlive.py` did not start: powder-wrap's log (`world_editor live:` lines), `WORLD_EDITOR_LIVE` |
| `live edits off: could not hook ...` | another mod hooks the same ntdll functions (asset_trace): load only one |
| `live: writing the cells of edit #N` for long | the helper failed on the list: powder-wrap's log, `world_editor live: error` |
| the cell never says `read N time(s)` | the game did not read that entry again (ride further; on the WhiteRoom reload the menu), or it reads it through a file the overlay does not know (report the log's `live:` lines) |
| `read N time(s)`, but no change visible | the game read the edited bytes but builds the cell from a cache, or the edit is in another copy of the cell (report the cell and the log) |
| `its new dependencies are not (shown after a restart): ...` | the cell's prefetch row was not found or written (WORLD-LIVE.md "Prefetch rows in memory"): an added prop whose meshes no loaded cell uses stays invisible until the next start; `tools/trainer/prefetchrow.py` shows the row and which of its records are loaded |
| `not redirected: its index record was not found` | the in-memory index differs from WORLD-LIVE.md's (this build?): bigger edits show at the next start only |
| the game hangs while streaming, or crashes near an edited cell | a completion the overlay gave wrongly: report the log's `patched reads complete by ...` lines; `WORLD_EDITOR_LIVE=0` turns it off |
| a bigger cell shows as a hole / is missing | the game checks offsets against the file size (redirect does not work in that form): report it |

| you see | meaning |
|---|---|
| "no index for <map>" | the session step did not run or that map was not indexed: powder-wrap's log, `WORLD_EDITOR_MAPS` |
| the card has no PANEL, or shows an error | the mod's script stopped: its error is under the card (CONSOLE has the details) |
| "not found (the server runs no mods/world_editor ...)" | mod.lua not loaded (server log: `loaded mod world_editor`) |
| "the world is edited from the server's own machine only" | the game reached the server from another address |
| an edit has no effect after a restart | the log's `world_editor:` lines: a warning names the skipped edit |
| the edit shows, but somewhere else / tilted | report the object and the panel's position (coordinates or tilt assumptions) |

**Objects the game keeps (2026-11-11):** a cell read does not always update an object the game already has: a
copied kicker in Japan kept its first place through two moves and stayed after its remove, while a bench in the Alps
followed every edit (harness, edits posted to the server, positions read with `resteep.prop`). The helper therefore also
writes `live/objects.tsv` (every object the edits touched: its matrix now, or `gone`; undone: a shipped one as
shipped, an added one gone; from `world.py apply --objects`), and the overlay (`liveobjects.cpp`; the DLL until
2026-11-15) puts each loaded object of the world the game is in there 0.3, 3 and 8 s after the list changed
(groups are not listed: plain entities only; an object the editor's live preview is moving is left to it). Gone ones are shrunk and put far under the map. Checked in the harness (2026-11-12, edits posted with `harness
http`): a copied kicker followed two moves and went under the map on its remove. The list is filtered by the world
the game is in. A copy's id comes from its edit number (the
same on every PC), so a later add never reuses a removed copy's id. **Open:** a new copy in a cell that already
holds one of these kept objects did not show after the cell was read again (harness: the re-added kicker); it
should show once the cell streams in again (ride away and back; not checked).

## Verified vs assumed

The Lua editor (2026-11-15), verified without the game: `native/bin/script_test.exe` runs this folder's main.lua on
a small index against a stand-in server half (the panel: map, cell, objects near with a moved one, props, the edit
list with its author, the admin's rules; Remove and Add here send their edits; the free camera takes the picture,
closes the menu, picks the object under the pointer, G + pointer + click sends a move, R with a typed 45 turns an
entity the overlay holds and Esc puts it back); `tests/test_world_editor_preview.py` checks its preview math
against world.py; the overlay test host draws the panel with the real Alps index; with the Alps index (24,278
objects) in a plain Lua 5.4, loading takes at most ~11 ms a frame for ~80 frames, the panel and the free camera
with picking under 2 ms a frame. Everything the DLL did in the game (below) is assumed to hold for the Lua editor
until a player tries it (the keys come from the overlay's key events now, the pointer from its own ImGui state).

Verified without the game (2026-10-27, the DLL):
- `world.py edit` writes byte-identical cells after its refactor (copy step shared with `apply`; WhiteRoom copies,
  `--source` copies, moves, scales, removes compared with the previous version).
- `world.py apply` on WhiteRoom and Alps edit lists: adds (same cell and from another cell), edits of added objects,
  moves/turns/scales/removes of shipped ones (with proxies), undone adds, malformed or out-of-range edits skipped;
  the cells pack with `forge.py build --like` (`verify --decompress`: no problems) and read back through a scratch
  stack with the objects where they should be. `world.py index`: WhiteRoom 172 objects, Alps 24,278 in 20 s.
- `mod.lua` on a scratch Rust server: every endpoint, the checks (bad map, op, id, scale, `of`, body), undo of an add
  with its dependent edits, clear, persistence across a restart.
- The panel (`world_editor.cpp`) under Wine with a fake host (ImGui without a renderer, a fake position, clicks by
  label): index loading (WhiteRoom, Alps, a missing Japan), adding, selecting, move / turn / scale / remove, undo,
  clear; the request bodies it sent were replayed to the scratch server (all accepted) and applied.
- powder-wrap's asset block with the new session step, run against a scratch game folder (symlinks to the real
  archives): both `_patch_03` archives built and listed in `.powder-assets`, the index files in
  `powder_mods/world_editor/`, the per-session folders deleted.

Live edits, verified without the game (2026-10-27, then in the DLL, the same code is the overlay's since
2026-11-15; `tests/test_world_live.py`, `--wine` for the hooks, rerun 2026-11-15 against the overlay's code):
- `forge.py pad_datafile`: real cells padded by 0..300 bytes parse to the same resources, their chunks decompress
  the same through libzstd; `fit_datafile` puts edited cells into their entry's size.
- `live.py` over a scratch game folder (links to the real WhiteRoom archives) with a session `_patch_03` built the
  way powder-wrap builds it: turn + remove, an add that fits, an add that grows (a small cell), undo of the session's
  own edit (that cell served as shipped again), move + scale, clear. After each step every served cell, read back
  through `live_patch.h` (the DLL's byte-range code) in the game's aligned chunk sizes, is exactly the cell
  `world.py apply` makes; no other cell differs from what the game reads.
- The hooks under Wine (scratch prefix) in a stand-in host (`native/overlay/livehost.cpp`, MinHook like the
  overlay): every served cell read back the same through the hooks with a synchronous handle (file pointer),
  overlapped + event, completion ports bound before the DLL (learnt from dequeued packets; also with
  FILE_SKIP_COMPLETION_PORT_ON_SUCCESS) and after it, GetQueuedCompletionStatusEx, ReadFileEx + APC; no packet
  twice or left over; the grown cell's record (a game-like 24-byte record array in the host) redirected, read from
  its slot, and restored when a later generation no longer serves it.
- `session.sh` (now `resteep/session_steps.py`) + `live.py run` against a scratch Rust server: the helper starts, follows a move, an add and an
  undo posted to `mod.lua` (each followed by a poke, as the panel does) within ~1 s, and stops when the runtime
  folder is removed.
- The in-memory index (WORLD-LIVE.md): read from the running game (`/proc/<pid>/mem`, read only).

Assumed (G), to be tested in-game: that the game builds a cell from the bytes it reads each time (not from a cache);
that pointing a record moves where the game reads (and that it does not check offsets against the file's size); how
the game's archive reads complete (the DLL handles events, APCs and completion ports, and logs which one it saw).

Assumed (G), to be tested in-game: the trainer's player position is in the map's world coordinates (Z up); the
direction of riding is a fair "in front"; edited cells load like world_test's; copies outside world_test's case
(another cell, the open world, scaled) render and collide; moved objects within their cell's square still stream.
