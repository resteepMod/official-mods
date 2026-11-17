# Yard Sale

Crash on purpose and score the wreck. Ride into a tree, cartwheel down a cliff, clip a rock at speed: every hit
the game counts while your rider tumbles scores, and the banner at the end says what broke.

## Scoring

- **Hits:** each hit the game counts (ReSteep's `impact` event: the body part, how hard, the surface) scores
  10 points per unit of the game's amount. The head counts double and arms 1.2×. Trees and rocks count 1.5×,
  metal and concrete 1.4×, wood 1.3×, branches and ice 1.2×, snow 1×. The hit that starts the crash counts too.
- **Broken bones:** a body part that takes enough (amounts summed) turns bruised, then broken: +1000 per broken
  part, the skull +2000.
- **The rest:** the speed before the crash, the air time when it started in the air, how far the body tumbled and
  how long it was down.

While the rider is down, a see-through skeleton is drawn over the body: white, bruised yellow, broken red (it shows
through everything, like a marker). The running score shows at the top; each hit pops up where it happened.

When the rider gets up, the game's own red crash banner shows the score and the personal best, and the
game's notifications say each broken bone and your place on the server's board `yard_sale` (one leaderboard for
everyone). **Detailed card** adds the card with every part of the score and the board's top 5. With a ReSteep older
than 2026-11-17 (no game popups) that card shows instead of the banner.

## Settings

**See-through skeleton** (on), **Result card** (how long the banner and card show, 8 s), **Detailed card** (off),
**Send scores to the leaderboard** (on).

## Needs

A ReSteep with the `impact` event and `resteep.rider.bones` (2026-11-17). With an older one the mod says so once
and does nothing. Script only: no world content, no restart needed after an update.

The idea follows the bail-scoring modes of skateboarding games; the scoring, look and code are this mod's own.
