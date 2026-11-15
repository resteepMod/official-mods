# Challenge Example

Adds challenges to the game the way the shipped ones are: on the map, with their start marker, gates, medals and a
leaderboard of their own (docs/modding/challenges.md).

- **ReSteep: Short Downhill** (race, Alps): declared in `build.lua` with `resteep.challenge{...}`; it runs down the
  slope of Dexterity Drift through every other of its gates. The "Gold time" setting sets the medal times.
- **ReSteep: Big Air** (jump, Alps): declared in `resteep.json` (`content.challenges`); off until "Jump challenge"
  is switched on. It starts further down the same slope (Dexterity Drift's gate 17), below the race's finish,
  with its spawn set by hand: a jump has no gates the run-up could follow.

- **Music** (`content.music`): `music/theme.ogg`, an original loop made for this example, plays during the race
  (`music = "theme"` in build.lua); "Music on Butterfly" lets the shipped Butterfly challenge play it too.

The challenges are built into the session's patch when the game starts (they need `tools/forge`, a ReSteep checkout,
so far). Their save names are `RS_CHALLENGE_EXAMPLE_SHORT_DOWNHILL` and `RS_CHALLENGE_EXAMPLE_BIG_AIR`.

**Multiplayer:** must match: the challenges (their ids, gates and leaderboards), so every player on the server needs
the same mod, and the server runs it too (the server lists it; when you join, ReSteep shows it as missing or
different if yours is not the same). Its settings (the gold time, the jump challenge) change what it builds and are
not compared: on a server keep the defaults.
