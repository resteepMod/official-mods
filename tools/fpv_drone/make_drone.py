#!/usr/bin/env python3
"""The FPV drone's own model and motor sound (mods/fpv_drone), made from formulas: no game files, CC0.

    python3 tools/fpv_drone/make_drone.py          mods/fpv_drone/assets/drone.glb and sounds/motor_loop.wav

**drone.glb:** a 5-inch racing quad in Steep's frame (x right, y the nose, z up; metres; the origin is the point the
mod's flight model moves, 5 cm over the snow when it sits): X arms, a stack, the battery on top, the camera in the
nose, four motors and the props as thin discs (a static model can't spin them; a disc reads as turning props).
Two materials in this order: "frame" (everything solid) and "props". The game draws a model with the materials of the
prop it borrows (tools/forge/models.py in ReSteep: the first material fills the borrowed mesh's first submesh, ...).

**motor_loop.wav:** 2 s, 22,050 Hz, mono, 16-bit: four motors at slightly different speeds (their beating is the
quad's wobble), each a buzzy tone with its harmonics and the 3-blade pass boosted, plus filtered air noise. Every
frequency is a multiple of 0.5 Hz and the noise is filtered circularly, so the loop has no seam. The mod raises its
pitch with the throttle (resteep.sound.set).
"""

from __future__ import annotations

import json
import math
import os
import random
import struct
import wave

MOD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "mods", "fpv_drone")

# ---- the model ------------------------------------------------------------------------------------------------------

ARM = 0.078                                     # motor centres at (+-ARM, +-ARM): 220 mm diagonal, a 5-inch frame
PROP_R = 0.064


class Mesh:
    def __init__(self) -> None:
        self.parts: dict[str, list] = {}           # material -> [(p0, p1, p2, normal), ...]

    def tri(self, mat: str, a, b, c) -> None:
        u = [b[k] - a[k] for k in range(3)]
        v = [c[k] - a[k] for k in range(3)]
        n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        ln = math.sqrt(sum(x * x for x in n)) or 1.0
        self.parts.setdefault(mat, []).append((a, b, c, tuple(x / ln for x in n)))

    def quad(self, mat: str, a, b, c, d) -> None:
        self.tri(mat, a, b, c)
        self.tri(mat, a, c, d)

    def box(self, mat: str, centre, half, yaw: float = 0.0, pitch: float = 0.0) -> None:
        """A box turned by `pitch` about x (nose up), then `yaw` about z (degrees)."""
        cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))

        def at(x, y, z):
            y, z = y * cp - z * sp, y * sp + z * cp
            x, y = x * cy - y * sy, x * sy + y * cy
            return (centre[0] + x, centre[1] + y, centre[2] + z)
        hx, hy, hz = half
        p = {(i, j, k): at(i * hx, j * hy, k * hz) for i in (-1, 1) for j in (-1, 1) for k in (-1, 1)}
        self.quad(mat, p[-1, -1, 1], p[1, -1, 1], p[1, 1, 1], p[-1, 1, 1])          # top
        self.quad(mat, p[-1, -1, -1], p[-1, 1, -1], p[1, 1, -1], p[1, -1, -1])      # bottom
        self.quad(mat, p[-1, -1, -1], p[1, -1, -1], p[1, -1, 1], p[-1, -1, 1])      # back
        self.quad(mat, p[-1, 1, -1], p[-1, 1, 1], p[1, 1, 1], p[1, 1, -1])          # front
        self.quad(mat, p[-1, -1, -1], p[-1, -1, 1], p[-1, 1, 1], p[-1, 1, -1])      # left
        self.quad(mat, p[1, -1, -1], p[1, 1, -1], p[1, 1, 1], p[1, -1, 1])          # right

    def cylinder(self, mat: str, centre, r: float, z0: float, z1: float, n: int = 16, axis: str = "z") -> None:
        """Along z from z0 to z1 (relative to centre), or along y (`axis="y"`: z0..z1 are y offsets)."""
        def at(a, h):
            c, s = r * math.cos(a), r * math.sin(a)
            if axis == "y":
                return (centre[0] + c, centre[1] + h, centre[2] + s)
            return (centre[0] + c, centre[1] + s, centre[2] + h)
        def mid(h):
            return (centre[0], centre[1] + h, centre[2]) if axis == "y" else (centre[0], centre[1], centre[2] + h)
        for k in range(n):
            a0, a1 = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
            faces = [(at(a0, z0), at(a1, z0), at(a1, z1), at(a0, z1)),       # side, outwards
                     (mid(z1), at(a0, z1), at(a1, z1)), (mid(z0), at(a1, z0), at(a0, z0))]   # the caps
            for f in faces:
                if axis == "y":                     # (x, y, z) <- (c, h, s) mirrors the winding: turn it back
                    f = f[::-1]
                (self.quad if len(f) == 4 else self.tri)(mat, *f)


def drone() -> Mesh:
    m = Mesh()
    m.box("frame", (0, 0, -0.035), (0.032, 0.070, 0.003))                 # bottom plate
    for sx in (-1, 1):                                                      # the X arms
        for sy in (-1, 1):
            m.box("frame", (sx * ARM / 2, sy * ARM / 2, -0.035), (0.010, ARM * 0.72, 0.003), yaw=-45 * sx * sy)
    m.box("frame", (0, 0, -0.016), (0.019, 0.019, 0.016))                   # the electronics stack
    m.box("frame", (0, -0.004, 0.002), (0.030, 0.060, 0.002))               # top plate
    m.box("frame", (0, -0.008, 0.021), (0.017, 0.037, 0.017))               # battery
    m.box("frame", (0, 0.050, -0.012), (0.011, 0.010, 0.011), pitch=25)    # camera, tilted up
    m.cylinder("frame", (0, 0.058, -0.008), 0.0065, 0.0, 0.010, 12, axis="y")   # its lens
    m.box("frame", (0, -0.072, 0.010), (0.0015, 0.0015, 0.024), pitch=-30)  # antenna
    for sx in (-1, 1):
        for sy in (-1, 1):
            c = (sx * ARM, sy * ARM, 0.0)
            m.cylinder("frame", c, 0.0125, -0.032, -0.012, 16)              # motor
            m.cylinder("frame", c, 0.0035, -0.012, -0.002, 8)               # shaft and nut
            m.cylinder("props", c, PROP_R, -0.007, -0.0055, 28)             # the turning props
    return m


def write_glb(path: str) -> None:
    gl = lambda v: (v[0], v[2], -v[1])              # Steep (z up) -> glTF (y up), as ReSteep's gltf.to_gl
    m = drone()
    pos, nrm, uv, idx, prims = [], [], [], [], []
    for mat in ("frame", "props"):
        first = len(idx)
        for a, b, c, n in m.parts[mat]:
            for p in (a, b, c):
                idx.append(len(pos))
                pos.append(gl(p))
                nrm.append(gl(n))
                uv.append((p[0] * 4 + 0.5, p[1] * 4 + 0.5))
        prims.append((mat, first, len(idx) - first))
    bp = b"".join(struct.pack("<3f", *p) for p in pos)
    bn = b"".join(struct.pack("<3f", *n) for n in nrm)
    bt = b"".join(struct.pack("<2f", u, 1 - v) for u, v in uv)
    bi = struct.pack(f"<{len(idx)}I", *idx)
    views, blob = [], b""
    for part in (bp, bn, bt, bi):
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(part)})
        blob += part + b"\0" * (-len(part) % 4)
    lo = [min(p[k] for p in pos) for k in range(3)]
    hi = [max(p[k] for p in pos) for k in range(3)]
    accessors = [
        {"bufferView": 0, "componentType": 5126, "count": len(pos), "type": "VEC3", "min": lo, "max": hi},
        {"bufferView": 1, "componentType": 5126, "count": len(pos), "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": len(pos), "type": "VEC2"}]
    primitives = []
    for k, (mat, first, count) in enumerate(prims):
        accessors.append({"bufferView": 3, "byteOffset": first * 4, "componentType": 5125, "count": count,
                          "type": "SCALAR"})
        primitives.append({"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3 + k,
                           "material": k})
    doc = {
        "asset": {"version": "2.0", "generator": "fpv_drone/make_drone.py", "copyright": "CC0-1.0"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "fpv_drone", "mesh": 0}],
        "materials": [{"name": "frame"}, {"name": "props"}],
        "meshes": [{"name": "fpv_drone", "primitives": primitives}],
        "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)
    size = [hi[0] - lo[0], hi[2] - lo[2], hi[1] - lo[1]]
    print(f"{path}: {len(idx) // 3} triangles, {size[0]:.3f} x {size[1]:.3f} x {size[2]:.3f} m")


# ---- the sound ------------------------------------------------------------------------------------------------------

RATE, SECONDS = 22050, 2.0
MOTORS = (181.0, 184.5, 187.0, 190.5)          # Hz, multiples of 1 / SECONDS: whole cycles in the loop


def write_wav(path: str) -> None:
    n = int(RATE * SECONDS)
    rnd = random.Random(1505)
    out = [0.0] * n
    for k, f in enumerate(MOTORS):
        harm = [(h, (1.0 / h ** 0.85) * (2.2 if h % 3 == 0 else 1.0), rnd.uniform(0, 2 * math.pi))
                for h in range(1, 14) if f * h < RATE * 0.45]
        wob = 0.5 * (k + 1) / SECONDS                # each motor's slow loudness wobble, whole cycles too
        for i in range(n):
            t = i / RATE
            s = sum(a * math.sin(2 * math.pi * f * h * t + ph) for h, a, ph in harm)
            out[i] += s * (1.0 + 0.15 * math.sin(2 * math.pi * wob * t + k))
    noise = [rnd.uniform(-1, 1) for _ in range(n)]
    for a in (0.35, 0.35):                           # two one-pole low-passes, each run twice around (circular)
        y = 0.0
        for _ in range(2):
            for i in range(n):
                y += a * (noise[i] - y)
                noise[i] = y
    hp, prev_x, prev_y = 0.97, noise[-1], 0.0      # and a high-pass: a hiss of air, no rumble
    for _ in range(2):
        px = prev_x
        for i in range(n):
            x = noise[i]
            prev_y = hp * (prev_y + x - px)
            px = x
            noise[i] = prev_y
        prev_x = px
    peak_tone = max(abs(x) for x in out) or 1.0
    peak_noise = max(abs(x) for x in noise) or 1.0
    mix = [0.82 * out[i] / peak_tone + 0.30 * noise[i] / peak_noise for i in range(n)]
    peak = max(abs(x) for x in mix) or 1.0
    pcm = struct.pack(f"<{n}h", *(int(round(x / peak * 0.7 * 32767)) for x in mix))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    print(f"{path}: {SECONDS:.0f} s, {RATE} Hz mono, {len(pcm) // 1024} KB")


def main() -> None:
    write_glb(os.path.join(MOD, "assets", "drone.glb"))
    write_wav(os.path.join(MOD, "sounds", "motor_loop.wav"))


if __name__ == "__main__":
    main()
