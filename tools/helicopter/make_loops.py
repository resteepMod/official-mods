#!/usr/bin/env python3
"""The helicopter's rotor loops from the player's recordings (sources/close.mp3, sources/far.mp3): a steady stretch of
each, its end crossfaded into its start so it loops without a seam, mono 16-bit 44.1 kHz WAV (what resteep.sound
plays), both at the same loudness. Writes ../../mods/helicopter/sounds/rotor_close.wav and rotor_far.wav.

    python3 tools/helicopter/make_loops.py          (needs ffmpeg and numpy)

close.mp3 is a steady rotor next to the helicopter (6 s from 3.0 s); far.mp3 a fly-by, quiet - loud - quiet: the
loop takes 7 s from 6.5 s, the approach (its Doppler shift steady), before the pass's loudest and most shifted part.
The stretch's slow swell (the fly-by grows ~2 dB over it) is evened out first, so the loop does not pulse; its length
is moved by up to 0.15 s so that the blade slap (~0.09 s apart in close.mp3) runs on in step across the seam.
"""
import struct
import subprocess
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "mods" / "helicopter" / "sounds"
SR = 44100
CUTS = {"close": (3.0, 6.0), "far": (6.5, 7.0)}   # start, loop length (s, about: see in_step)
FADE = 0.5                                         # s of the end crossfaded into the start
LEVEL = 0.125                                      # RMS of each loop: the same for both (close.mp3 peaks at it)


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768


def even(a: np.ndarray, window: float = 0.6) -> np.ndarray:
    """a with its slow loudness changes taken out (divided by its RMS over a sliding Hann window)."""
    k = np.hanning(int(window * SR))
    rms = np.sqrt(np.convolve(a * a, k / k.sum(), "same"))
    return a / np.maximum(rms, 1e-4) * np.median(rms)


def envelope(a: np.ndarray) -> np.ndarray:
    """|a| smoothed and taken at 200 Hz, mean 0 (the blade slap's rhythm)."""
    k = int(0.005 * SR)
    e = np.convolve(np.abs(a), np.ones(k) / k, "same")[::k]
    return e - e.mean()


def in_step(seg: np.ndarray, n: int, f: int) -> int:
    """the loop length near n whose tail's envelope best matches the head's (the slap in step across the seam)."""
    head = envelope(seg[:f])
    best, best_r = n, -2.0
    for m in range(n - int(0.15 * SR), n + int(0.15 * SR), int(0.005 * SR)):
        tail = envelope(seg[m:m + f])
        r = float(np.dot(head, tail) / (np.linalg.norm(head) * np.linalg.norm(tail) + 1e-12))
        if r > best_r:
            best, best_r = m, r
    return best


def loop(a: np.ndarray, start: float, length: float) -> np.ndarray:
    s, n, f = int(start * SR), int(length * SR), int(FADE * SR)
    pad = int(0.15 * SR) + f
    seg = a[s:s + n + pad]
    if len(seg) < n + pad:
        raise SystemExit("the recording is shorter than the cut")
    seg = even(a[max(0, s - SR):s + n + pad + SR])[s - max(0, s - SR):][:n + pad]   # evened with context around it
    n = in_step(seg, n, f)
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
        print(f"rotor_{name}.wav: {len(a) / SR:.3f} s from {start:g} s, peak {np.max(np.abs(a)):.2f}")


if __name__ == "__main__":
    main()
