#!/usr/bin/env python3
"""The hill of mods/resteep_hill: a smooth snow slope over the WhiteRoom valley's four cells, made from a formula.

    python3 tools/resteep_hill/make_hill.py                      mods/resteep_hill/assets/hill.glb (no game files needed)
    python3 tools/resteep_hill/make_hill.py --edits <game dir>   also assets/hill.json (needs a ReSteep checkout:
                                              $RESTEEP, default ../ReSteep next to this repository): the model placed, the valley's own ground,
                                              trees, rocks and buildings in its square removed (their ids read
                                              from the player's install; they are the same in every copy)

The surface covers x, y in -128..128 (cells 27, 28, 35, 36: the clone's ground collision is made per cell from the
model's triangles, mapgen.py --solid) on a 2 m grid: a summit plateau in the north-west corner (about 57 m), a fall
line to the south-east with three rollers, a flat run-out, banked rims along the edges so a rider stays inside.
Everything is smooth (no kinks), so the collision tiles under it meet within a few cm (the WhiteRoom's own ground,
a noisy mesh, left steps of 9 cm at the median). Coordinates are Steep's (z up), metres.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "mods", "resteep_hill")   # the mod
RESTEEP = os.environ.get("RESTEEP") or os.path.join(HERE, "..", "..", "..", "ReSteep")             # for tools/forge
HALF, STEP = 128.0, 2.0
SUMMIT = (-100.0, 100.0)                       # the drop zone stands here (resteep.json "drop_zone")
REMOVE = ("STP_WOR_GEN_VEG_", "STP_GEN_ROCK_", "STP_ALP_R01_BUI_", "STP_WHI_Ground_")  # what goes from the square


def smooth(e0: float, e1: float, x: float) -> float:
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * t * (t * (6 * t - 15) + 10)     # smootherstep: flat at both ends, no kink


def height(x: float, y: float) -> float:
    u = (-x + y) / math.sqrt(2)                    # along the fall line, + towards the summit (north-west)
    v = (x + y) / math.sqrt(2)                     # across it
    z = 2.0 + 52.0 * smooth(-70.0, 130.0, u)       # run-out at 2 m (above the outskirts' 1.2 m there), the slope
    z += 3.0 * smooth(120.0, 150.0, u)             # the summit plateau
    for at, h in ((70.0, 2.5), (25.0, 2.0), (-20.0, 1.5)):   # rollers on the way down
        z += h * math.exp(-((u - at) / 7.0) ** 2)
    z += 4.0 * (v / 128.0) ** 2                    # a shallow trough: the middle is the line
    z += 10.0 * (1.0 - smooth(0.0, 28.0, HALF - abs(x)) * smooth(0.0, 28.0, HALF - abs(y)))  # banked rims (a
    #                                              product, not the nearer edge: no crease along the corners' diagonals)
    return z


def grid() -> tuple[list, list, list, list]:
    n = int(2 * HALF / STEP) + 1
    pos, nrm, uv, idx = [], [], [], []
    for j in range(n):
        for i in range(n):
            x, y = -HALF + i * STEP, -HALF + j * STEP
            z = height(x, y)
            d = 0.5
            gx = (height(x + d, y) - height(x - d, y)) / (2 * d)
            gy = (height(x, y + d) - height(x, y - d)) / (2 * d)
            ln = math.sqrt(gx * gx + gy * gy + 1)
            pos.append((x, y, z))
            nrm.append((-gx / ln, -gy / ln, 1 / ln))
            uv.append((x / 8.0, y / 8.0))          # the snow texture every 8 m
    for j in range(n - 1):
        for i in range(n - 1):
            a, b, c, d = j * n + i, j * n + i + 1, (j + 1) * n + i, (j + 1) * n + i + 1
            idx += [a, b, d, a, d, c]              # counter-clockwise seen from above
    return pos, nrm, uv, idx


def write_glb(path: str) -> None:
    pos, nrm, uv, idx = grid()
    gl = lambda v: (v[0], v[2], -v[1])             # Steep (z up) -> glTF (y up), as gltf.to_gl
    bp = b"".join(struct.pack("<3f", *gl(p)) for p in pos)
    bn = b"".join(struct.pack("<3f", *gl(p)) for p in nrm)
    bt = b"".join(struct.pack("<2f", u, 1 - v) for u, v in uv)
    bi = struct.pack(f"<{len(idx)}I", *idx)
    views, blob = [], b""
    for part in (bp, bn, bt, bi):
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(part)})
        blob += part + b"\0" * (-len(part) % 4)
    gp = [gl(p) for p in pos]
    lo = [min(p[k] for p in gp) for k in range(3)]
    hi = [max(p[k] for p in gp) for k in range(3)]
    doc = {
        "asset": {"version": "2.0", "generator": "resteep_hill/make_hill.py"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "hill", "mesh": 0}],
        "materials": [{"name": "snow"}],
        "meshes": [{"name": "hill", "primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
                                                    "indices": 3, "material": 0}]}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(pos), "type": "VEC3", "min": lo, "max": hi},
            {"bufferView": 1, "componentType": 5126, "count": len(pos), "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": len(pos), "type": "VEC2"},
            {"bufferView": 3, "componentType": 5125, "count": len(idx), "type": "SCALAR"}],
        "bufferViews": views, "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as f:
        f.write(out)
    print(f"{path}: {len(pos)} vertices, {len(idx) // 3} triangles, z {lo[1]:.1f}..{hi[1]:.1f} m")


def write_edits(game: str, path: str) -> None:
    sys.path.insert(0, os.path.join(RESTEEP, "tools", "forge"))
    import forge
    import world
    mp = world.Map(os.path.join(game, "DataPC_STP_WhiteRoom.forge"))
    edits = [{"n": 1, "map": "WhiteRoom", "op": "add", "name": "hill", "model": "hill", "pos": [0, 0, 0]}]
    for idx in (27, 28, 35, 36):
        fg, e = mp.cells[(0, idx)]
        c = world.Cell(idx, os.path.basename(fg.path), e, forge.parse_datafile(fg.read(e)).resources, 0)
        for i in c.block.ids:
            r = c.by_id.get(i)
            if r is not None and r.type in (world.ENTITY, world.GROUP) and (r.name or "").startswith(REMOVE):
                edits.append({"n": len(edits) + 1, "map": "WhiteRoom", "op": "remove",
                              "obj": {"layer": 0, "cell": idx, "id": f"{i:#x}"}, "name": r.name})
    with open(path, "w") as f:
        f.write('{"edits": [\n' + ",\n".join(" " + json.dumps(e) for e in edits) + "\n]}\n")
    print(f"{path}: the model and {len(edits) - 1} removals")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--edits", metavar="GAME", help="also write assets/hill.json from this Steep folder")
    a = ap.parse_args()
    os.makedirs(os.path.join(HERE, "assets"), exist_ok=True)
    write_glb(os.path.join(HERE, "assets", "hill.glb"))
    if a.edits:
        write_edits(a.edits, os.path.join(HERE, "assets", "hill.json"))
    print(f"summit (drop zone): {SUMMIT[0]}, {SUMMIT[1]}, {height(*SUMMIT):.1f}")


if __name__ == "__main__":
    main()
