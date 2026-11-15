#!/usr/bin/env python3
"""The helicopter's rotor loops from the player's recordings (sources/close.mp3, sources/far.mp3): a steady stretch of
each, its end crossfaded into its start so it loops without a seam, mono 16-bit 44.1 kHz WAV (what resteep.sound
plays), both at the same loudness. Writes ../../mods/helicopter/sounds/rotor_close.wav and rotor_far.wav.

    python3 tools/helicopter/make_loops.py          (needs ffmpeg and numpy)

close.mp3 is a steady rotor next to the helicopter (the stretch from 3.1 s: the steadiest 4 s); far.mp3 a fly-by,
quiet - loud - quiet: the loop takes 9-13 s, before the pass's loudest and most Doppler-shifted part.
"""
import struct
import subprocess
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "mods" / "helicopter" / "sounds"
SR = 44100
CUTS = {"close": (3.1, 4.0), "far": (9.0, 4.0)}   # start, loop length (s)
FADE = 0.5                                         # s of the end crossfaded into the start
LEVEL = 0.18                                       # RMS of each loop (peaks stay below full scale)


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768


def loop(a: np.ndarray, start: float, length: float) -> np.ndarray:
    s, n, f = int(start * SR), int(length * SR), int(FADE * SR)
    seg = a[s:s + n + f]
    if len(seg) < n + f:
        raise SystemExit("the recording is shorter than the cut")
    out = seg[:n].copy()
    t = np.linspace(0, np.pi / 2, f)
    out[:f] = seg[n:n + f] * np.cos(t) + seg[:f] * np.sin(t)    # equal power: the tail fades into the head
    out -= out.mean()
    return out * min(LEVEL / np.sqrt(np.mean(out ** 2)), 0.89 / np.max(np.abs(out)))   # the level, or -1 dB peak


def write_wav(path: Path, a: np.ndarray) -> None:
    pcm = (np.clip(a, -1, 1) * 32767).astype("<i2").tobytes()
    path.write_bytes(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " +
                     struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)


def main() -> None:
    for name, (start, length) in CUTS.items():
        a = loop(decode(HERE / "sources" / f"{name}.mp3"), start, length)
        write_wav(OUT / f"rotor_{name}.wav", a)
        print(f"rotor_{name}.wav: {length:g} s from {start:g} s, peak {np.max(np.abs(a)):.2f}")


if __name__ == "__main__":
    main()
