# Master Chief Costume

**Master Chief** as a costume of his own, next to the game's, with his name and picture, owned by every player.
Nothing of the game's is replaced.

## Credits

- **Model:** "Master Chief High Poly" by **HarrisonHag1**, licensed **CC-BY-4.0**
  (https://creativecommons.org/licenses/by/4.0/), from
  https://sketchfab.com/3d-models/master-chief-high-poly-18f5ee1d13904939971601055102c91b.
- Fitted to Steep's skeleton by ReSteep's build (`tools/forge/costume_fit.py`) on your PC: the bones are mapped and
  turned onto Steep's, the model is scaled to the rider, its maps are converted to Steep's materials. The costume's
  picture (`icon.png`) is a render of the model. This work is based on the model above.
- Master Chief and Halo are trademarks of Microsoft. This is a fan-made costume, not made, endorsed or supported by
  Microsoft or Ubisoft.

## Getting the model

The package holds no model: the fitted model is made against your own Steep install, and the model is the author's
to hand out. You download it yourself (free) and give it to the launcher:

1. Install the mod (Mods, Official tab). Its tile then says it needs a file you download.
2. On the tile, press **Get the file**, then **Open the download page**. On Sketchfab: **Download 3D Model**, then
   **glTF** (needs a free Sketchfab account). It saves `master_chief_high_poly.zip`.
3. Back in the launcher, **Choose the downloaded file** and pick that zip. The launcher checks it (data files only:
   `scene.gltf`, `scene.bin`, the textures) and keeps it for this mod, apart from the mod, so updates keep it.
4. Press Play. The first start with the mod fits the model (seconds) and builds the costume (a few minutes); later
   starts take it from the cache. The costume is in the wardrobe with the costumes.

Removing the mod removes the downloaded file too (Get the file, **Remove the file** removes only the file).

## What the mod says (resteep.json)

- `downloads`: where the model is, who made it, its licence, what to pick on the page and the files the zip holds.
- `content.costumes[0].fit`: the model's bones mapped to Steep's (`bip_upperArm_{s}` -> `{Side}Arm`; fingers by
  prefix), its materials into costume 016's (armour -> jacket, suit -> pants, helmet and visor side by side in the
  helmet's maps) and the glass hidden. `costume = STP_M_Costume_016` (and its female twin) is the costume whose slots
  it fills; the item `COSTUME_MF_POWDER_MASTER_CHIEF` is new.

**Multiplayer:** must match: the costume is an item, so every player on the server needs the same mod, and the
server runs it too (the server lists it; when you join, ReSteep shows it as missing or different if yours is not the
same). Others see it on you only with the same mod.
