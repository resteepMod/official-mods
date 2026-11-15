# resteep_park: a fourth massif

A content mod in the `.resteep` layout (docs/modding/format.md "maps"): **RESTEEP PARK**, a small world of its own next
to the Alps, Asia and Alaska. It shows that Steep takes an additional map: it is listed in the mountain view's massif list
(hold B, then RB; D-pad to pick, A to travel) and on the progress page (Esc, E, Tab), you travel there and back
like to any massif, and the shipped massifs stay as they are. Nothing of the game's is replaced.

What it is: the menu world's valley (the WhiteRoom: chapel, hotel, chalet, mazot among the firs) cloned as the
unused world `STP_Slopes`, with Alaska's wooden in-run (`STP_ALA_ART_FUR_R04_WoodenRamp_01`, about 20 m high)
standing at the valley's east side, a kicker from the Alps (a snow ramp) on the line from its foot across the
valley, five rocks and a fir in their way removed (`assets/park.json`, the world editor's edit format), and a drop
zone on the in-run's deck that every player has, where a rider arrives (`spawn`). The valley's ground gets collision of its own when the world is
built (box slabs under the ground mesh: the WhiteRoom's ground has none, tools/forge/MAPS-CUSTOM.md "Ground collision"),
as powder snow (`ground`: `CM_SNOW_Powder_Ground`, most of the Alps' terrain).
The mod holds only that edit list and these files; the world is made from your own install at each game start
(tools/forge/compose.py -> world.py apply, mapgen.py clone and tab; about 5 s, then from compose's cache) and packed
as a new archive `DataPC_STP_Slopes.forge` for the session only.

Tested in the game (2026-10-30, `powder-launcher harness test --suites park --mods resteep_park`): the ground holds
everywhere on the valley floor, the drop zone stands on the in-run's top, a run down the in-run carries across the
valley onto the kicker's line, and the kicker catches a rider at its lip. Arriving (a session started in the park,
or travel from another massif) puts the rider on the in-run's deck (`spawn`, 2026-11-02: the world gets a transition
portal as the open worlds have, tools/forge/MAPS-CUSTOM.md "Arrival"). Known: the mountain view's camera hardly moves in so
small a world, so other places are hard to pick there; the time of day stands still. The massif's pictures are Alaska's (its list
entry is a copy of Alaska's, with its own name), and its progress page lists Alaska's challenges (a new world needs
a challenge list; an empty one crashed the page). A hill made of a tilted copy of the valley's ground did not show
(left out; tools/forge/MAPS.md).
