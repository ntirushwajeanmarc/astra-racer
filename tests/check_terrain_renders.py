#!/usr/bin/env python3
"""Assert the terrain asset renders in the engine, in the right colour.

Everything else about this asset was checked from the file: the GLB container,
the vertex and triangle counts, the heights on the right axis, the colour array
decoding, and that Godot's importer produces a scene. None of that is a frame.
A mesh can carry correct colours, import cleanly, and still be drawn white,
because whether a material *uses* those colours is a separate flag - and it is
the one Godot's glTF importer leaves off.

So this renders the terrain the way the engine meets it - the imported scene, no
material override, no special handling - against a dark background, and measures
what is actually on screen.

Invariants asserted:
  1. the game ran, rendered, and saved a frame, without a script error;
  2. the terrain fills a real part of the frame, so it is a landscape and not a
     sliver or a blank frame;
  3. the surface reads as ground: the palette is green-dominant (the hypsometric
     ramp runs valley-green to hilltop-tan, which is unambiguously greener than
     blue) and not a bare white or grey wash.

Run:  python3 tests/check_terrain_renders.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = ROOT
SHOT = os.path.join(tempfile.gettempdir(), "terrain_check.png")
WIDTH, HEIGHT = 640, 360

BACKGROUND_LUMA = 40      # the scene background is near-black by construction
TERRAIN_SHARE = 0.30      # the camera frames it to fill most of the frame
GREEN_MARGIN = 12         # mean green minus mean blue, over the terrain only


def have(tool):
    return shutil.which(tool) is not None


def render():
    cmd = ["xvfb-run", "-a", "godot", "--path", PROJECT, "--resolution",
           f"{WIDTH}x{HEIGHT}", "scenes/terrain_check.tscn", "--", f"--shot={SHOT}"]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=110)


def main():
    for tool in ("xvfb-run", "convert"):
        if not have(tool):
            print(f"SKIPPED: {tool} is not installed")
            return 0

    proc = render()
    out = proc.stdout + proc.stderr
    failures = []
    if proc.returncode != 0:
        failures.append(f"the scene exited {proc.returncode}")
    if "SCRIPT ERROR" in out:
        failures.append("the scene printed a SCRIPT ERROR")
    if not os.path.isfile(SHOT):
        print("RENDER FAILED - no frame produced")
        print(out[-900:])
        print("TERRAIN_RENDER=FAIL")
        return 1
    print(f"rendered {SHOT} ({os.path.getsize(SHOT)} bytes)")

    raw = subprocess.run(["convert", SHOT, "-depth", "8", "rgb:-"],
                         capture_output=True, check=True).stdout
    if len(raw) != WIDTH * HEIGHT * 3:
        raise SystemExit(f"unexpected pixel count {len(raw)}")

    terrain = 0
    total = [0, 0, 0]
    for i in range(0, len(raw), 3):
        r, g, b = raw[i], raw[i + 1], raw[i + 2]
        if 0.299 * r + 0.587 * g + 0.114 * b > BACKGROUND_LUMA:
            terrain += 1
            total[0] += r
            total[1] += g
            total[2] += b
    share = terrain / (WIDTH * HEIGHT)
    print(f"terrain covers {share * 100:.1f}% of the frame ({terrain} px)")

    if terrain == 0:
        failures.append("nothing was drawn at all - the whole frame is background")
        mean = (0.0, 0.0, 0.0)
    else:
        mean = tuple(v / terrain for v in total)
        print(f"terrain mean rgb = ({mean[0]:.0f}, {mean[1]:.0f}, {mean[2]:.0f})")

    if share < TERRAIN_SHARE:
        failures.append(f"the terrain covers only {share * 100:.1f}% of the frame, "
                        f"less than the {TERRAIN_SHARE * 100:.0f}% it is framed for")
    if terrain > 0:
        if mean[1] - mean[2] < GREEN_MARGIN:
            failures.append(f"the surface is not green-dominant: mean rgb "
                            f"({mean[0]:.0f}, {mean[1]:.0f}, {mean[2]:.0f}) has green "
                            f"only {mean[1] - mean[2]:.1f} above blue")
        if mean[0] > 200 and mean[1] > 200 and mean[2] > 200:
            failures.append(f"the surface is a white wash "
                            f"({mean[0]:.0f}, {mean[1]:.0f}, {mean[2]:.0f}) - the "
                            f"colours are in the mesh but the material is not using them")

    print(f"\n{3 - len(failures)}/3 render invariants hold")
    for f in failures:
        print(f"  FAILED: {f}")
    print("TERRAIN_RENDER=" + ("PASS" if not failures else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
