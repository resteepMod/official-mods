# resteep_mountains: a map with mountains of its own

The example of a generated terrain (docs/modding/format.md "A terrain of its own", tools/forge/TERRAIN.md): the
whole map is one entry in resteep.json, no images, no edits file, no game data.

```json
"terrain": {
  "generate": {"seed": 7, "low": 1200, "high": 3900, "massif": 5000, "roughness": 0.5},
  "plateaus": [{"at": [0, 0], "radius": 300}],
  "hills": [{"at": [0, 450], "height": 250, "radius": 180}]
}
```

- `generate`: a mountain range over the 16 km square from the seed, valley floors at 1200 m, the highest summit at
  3900 m. Another seed is another range; `massif` is how wide the mountains are, `roughness` how much the small
  ridges count.
- `plateaus`: level ground around the map's centre at the height the mountains have there, 180 m in radius and
  blended into them out to 300 m: the place to arrive. (`"height": 2800` would put it at 2800 m: a table mountain
  or a pit, as the ground around it says.)
- `hills`: a round hill 250 m high, 450 m north of the arrival: a first run down, and a landmark.
- `drop_zone` and `spawn` are `[0, 0]`, without a height: the build puts the rider on the ground.

Snow, rock and ice follow the slope and the height as in the Alps. The build (`cargo build --release -p powder-tbf`
once, then the launcher) takes about a minute and a half the first time; the terrain is kept in the build cache
until its keys change. The picture of the terrain the build names in its log (`preview.png`) shows the map from
above. Takes the park's world name `STP_Slopes`: enable one of resteep_park, resteep_hill, resteep_terrain_test,
this.

To make your own: copy the folder, change `id`, `title` and the seed, and move the plateau to a place you like in
the preview (x to the right, y up, 0 / 0 in the middle, 16 km across).
