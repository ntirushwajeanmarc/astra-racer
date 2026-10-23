#!/usr/bin/env python3
"""Assert the assembled game actually draws its road.

Every other check in this project asserts behaviour through the physics and the
data: the road's *collider* works even when its *surface* is invisible, so a
thousand passing physics assertions say nothing about whether the player can see
the track. This one renders the real game and measures the pixels.

Invariants asserted (true of any correct render of this scene at the start line):
  1. the road band under and around the player's car is asphalt: dark and
     colour-neutral (|R-G|, |G-B| small), not grass green;
  2. asphalt covers a real share of the lower half of the frame, because the
     camera sits 8.4 m behind a 12 m wide road;
  3. the frame is not blank - there is more than sky in it.

Renders under Xvfb so it needs no desktop and no GPU.

Run:  python3 tests/check_road_renders.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = ROOT
SHOT = os.path.join(tempfile.gettempdir(), "road_check.png")
WIDTH, HEIGHT = 640, 360
FRAMES = 45


def have(tool):
    return shutil.which(tool) is not None


def render():
    """Run the game under Xvfb and save one frame."""
    cmd = ["xvfb-run", "-a", "godot", "--path", PROJECT, "--resolution",
           f"{WIDTH}x{HEIGHT}", "scenes/capture.tscn", "--",
           f"--shot={SHOT}", f"--frames={FRAMES}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if not os.path.isfile(SHOT):
        print("RENDER FAILED - no frame produced")
        print((proc.stdout + proc.stderr)[-800:])
        return None
    print(f"rendered {SHOT} ({os.path.getsize(SHOT)} bytes)")
    return SHOT


def load_pixels(path):
    """Decode the PNG to raw RGB via ImageMagick, which is already a dependency
    of this project's tooling."""
    raw = subprocess.run(
        ["convert", path, "-depth", "8", "rgb:-"],
        capture_output=True, check=True,
    ).stdout
    if len(raw) != WIDTH * HEIGHT * 3:
        raise SystemExit(f"unexpected pixel count {len(raw)}")
    return raw


def pixel(raw, x, y):
    i = (y * WIDTH + x) * 3
    return raw[i], raw[i + 1], raw[i + 2]


def mean_of(raw, x0, x1, y0, y1):
    total = [0, 0, 0]
    count = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = pixel(raw, x, y)
            total[0] += r
            total[1] += g
            total[2] += b
            count += 1
    return tuple(v / count for v in total)


def is_asphalt(rgb, tolerance=18, max_luma=110):
    r, g, b = rgb
    return (max(r, g, b) < max_luma
            and abs(r - g) <= tolerance and abs(g - b) <= tolerance)


def main():
    for tool in ("xvfb-run", "convert"):
        if not have(tool):
            print(f"SKIPPED: {tool} is not installed")
            return 0
    path = render()
    if path is None:
        return 1
    raw = load_pixels(path)

    failures = []
    checks = 0

    # 1. The road right around the player's car: the band the chase camera
    #    frames between the rear of the field and the horizon.
    band = mean_of(raw, 250, 390, 296, 320)
    checks += 1
    r, g, b = band
    neutral = abs(r - g) <= 18 and abs(g - b) <= 18
    dark = (r + g + b) / 3.0 < 120
    ok = neutral and dark and is_asphalt(band)
    print(f"road band mean rgb=({r:.0f},{g:.0f},{b:.0f})  neutral={neutral} dark={dark}"
          f"  -> {'asphalt' if ok else 'NOT asphalt'}")
    if not ok:
        failures.append(
            f"the road band around the car reads rgb({r:.0f},{g:.0f},{b:.0f}), "
            "which is grass/background, not asphalt"
        )

    # 2. Asphalt has to cover a real share of the lower frame: any correct
    #    render of a 12 m road from 8.4 m behind shows a lot of it.
    lower = [(x, y) for y in range(HEIGHT // 2, HEIGHT, 3)
             for x in range(0, WIDTH, 3)]
    asphalt = sum(1 for x, y in lower if is_asphalt(pixel(raw, x, y)))
    share = asphalt / len(lower)
    checks += 1
    print(f"asphalt-like pixels in the lower half: {share * 100:.1f}%")
    if share < 0.05:
        failures.append(
            f"only {share * 100:.1f}% of the lower half is asphalt-coloured "
            "(expected the road to be a large part of it)"
        )

    # 3. Not a blank frame: something was drawn.
    overall = mean_of(raw, 0, WIDTH, 0, HEIGHT)
    sky = abs(overall[0] - overall[1]) < 4 and overall[0] > 180
    checks += 1
    print(f"frame mean rgb=({overall[0]:.0f},{overall[1]:.0f},{overall[2]:.0f}), all-sky={sky}")
    if sky:
        failures.append("the frame is nothing but sky - the world did not draw")

    print(f"\n{checks - len(failures)}/{checks} render invariants hold")
    for f in failures:
        print(f"  FAILED: {f}")
    print("ROAD_RENDER=" + ("PASS" if not failures else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
