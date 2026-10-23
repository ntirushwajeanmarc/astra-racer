#!/usr/bin/env python3
"""Synthesise the racing game's audio bank into audio/ as 22050 Hz mono WAVs.

No samples are downloaded: every sound is generated from scratch with the
standard library, which keeps the licence story clean (the whole game ships
under the Kenney CC0 art plus generated audio).

Looping sounds are built so the file length is an exact whole number of cycles
of every component frequency, so they loop seamlessly with no click.

Run:  python3 tools/make_audio.py
"""

import math
import os
import random
import struct
import wave

RATE = 22050
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio")
random.seed(20260918)


def write_wav(name, samples):
    path = os.path.join(OUT, name)
    peak = max(1e-9, max(abs(s) for s in samples))
    scaled = [s / peak * 0.92 for s in samples]
    with wave.open(path, "w") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(RATE)
        fh.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in scaled))
    print(f"  {name:22s} {len(samples) / RATE:5.2f}s  {len(samples) * 2 / 1024:6.1f} KiB")


def engine_loop(seconds=1.0):
    """A piston-engine drone: harmonic stack + amplitude growl, all frequencies
    integer cycles per second so the loop is seamless."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        v = 0.0
        for k, amp in ((1, 1.0), (2, 0.7), (3, 0.5), (4, 0.35), (6, 0.22), (8, 0.14), (10, 0.08)):
            v += amp * math.sin(2 * math.pi * 55 * k * t)
        growl = 0.75 + 0.25 * math.sin(2 * math.pi * 28 * t)
        v *= growl
        v += 0.06 * (random.random() * 2 - 1)  # combustion roughness
        out.append(v * 0.25)
    return out


def screech_loop(seconds=0.5):
    """Tyre scrub: resonant noise around 1.1 kHz plus a slipping whine."""
    n = int(RATE * seconds)
    out = []
    prev = 0.0
    for i in range(n):
        t = i / RATE
        white = random.random() * 2 - 1
        prev = prev * 0.72 + white * 0.28  # crude low-pass -> body
        band = white - prev  # high-pass residue -> the squeal edge
        whine = math.sin(2 * math.pi * 1150 * t) * 0.35 + math.sin(2 * math.pi * 1720 * t) * 0.18
        amp = 0.8 + 0.2 * math.sin(2 * math.pi * 4 * t)
        out.append((band * 0.5 + whine) * amp * 0.5)
    fade = int(RATE * 0.05)  # crossfade the ends for a click-free loop
    for i in range(fade):
        k = i / fade
        out[i] = out[i] * k + out[n - fade + i] * (1 - k)
    return out[: n - fade]


def impact(seconds=0.45):
    """Bodywork hit: noise burst with a fast attack and a low thud tail."""
    n = int(RATE * seconds)
    out = []
    low = 0.0
    for i in range(n):
        t = i / RATE
        env = math.exp(-9 * t)
        white = random.random() * 2 - 1
        low = low * 0.94 + white * 0.06
        thud = math.sin(2 * math.pi * 90 * t) * math.exp(-7 * t)
        out.append((white * 1.4 + thud * 2.2 + low * 3.0) * env)
    return out


def tone(freq, seconds, decay=0.0, harmonics=((1, 1.0),)):
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        env = math.exp(-decay * t) if decay > 0 else 1.0
        v = sum(a * math.sin(2 * math.pi * freq * k * t) for k, a in harmonics)
        out.append(v * env)
    return out


def noise_hit(seconds=0.06):
    n = int(RATE * seconds)
    return [(random.random() * 2 - 1) * math.exp(-60 * i / RATE) for i in range(n)]


def main():
    os.makedirs(OUT, exist_ok=True)
    print(f"writing audio bank to {OUT}")
    write_wav("engine_loop.wav", engine_loop())
    write_wav("screech_loop.wav", screech_loop())
    write_wav("impact.wav", impact())
    write_wav("beep_low.wav", tone(440.0, 0.18, decay=5.0, harmonics=((1, 1.0), (3, 0.2))))
    write_wav("beep_high.wav", tone(880.0, 0.55, decay=3.0, harmonics=((1, 1.0), (2, 0.35))))
    write_wav("chime.wav", tone(1318.5, 0.7, decay=6.0, harmonics=((1, 1.0), (2, 0.3), (3, 0.15))))
    write_wav("click.wav", noise_hit())


if __name__ == "__main__":
    main()
