#!/usr/bin/env python3
"""Assert the assembled game actually paints its minimap.

The unit suite proves the pieces: that a MiniMap handed a circuit keeps it, that
every car is on it, that the marker geometry comes from the car's heading. None
of that says the game paints any of it. A Control whose circuit never arrives
returns from _draw early and paints nothing at all - the map is simply not there,
which reads as a design choice rather than a bug.

So this runs the real race scene, the one a player reaches from the menu, and
measures the pixels where the minimap belongs. Two things make that measurable
rather than a guess:

  * the track's meshes and the cars are hidden, so the only thing behind the HUD
    is the sky. A procedural sky is a smooth gradient, so in the minimap's
    rectangle a correct-but-absent map leaves *literally* zero pixels of local
    contrast, and a drawn map leaves hundreds;
  * the frame is rendered at the project's own 1280x720, not a smaller window,
    because project.godot stretches the canvas - at a 640x360 window the HUD is
    drawn at half scale and the map moves out from under its own coordinates.

Invariants asserted:
  1. the game ran, reported no script error, and produced a frame;
  2. the minimap rectangle is not empty sky: it contains drawn strokes;
  3. the player's marker is among them - the arrow is drawn opaque in the
     player's livery red, and nothing else up there is red.

Run:  python3 tests/check_minimap_renders.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = ROOT
SHOT = os.path.join(tempfile.gettempdir(), "minimap_check.png")
WIDTH, HEIGHT = 1280, 720
FRAMES = 12

# Where hud.gd's _relayout puts the map: rect.size.x - 236, 84, size 208x150.
MAP = (WIDTH - 236, 84, 208, 150)

# Measured, not guessed: with the map drawing, this rectangle holds 245 contrast
# strokes and 38 red marker pixels; with the map drawing nothing, both counts are
# exactly 0. The thresholds sit well below the measured values and well above
# the zero the empty sky gives.
STROKE_MIN = 60
RED_MIN = 10


def have(tool):
    return shutil.which(tool) is not None


def render():
    """Run the real race scene under Xvfb, isolated to the HUD, and save a frame."""
    # --only names a track child that does not exist, which hides every track
    # mesh; the harness hides the cars with it. The environment, the sky and the
    # HUD stay, and the minimap draws from TrackInfo rather than from meshes, so
    # it is unaffected by its subject being hidden.
    cmd = ["xvfb-run", "-a", "godot", "--path", PROJECT, "--resolution",
           f"{WIDTH}x{HEIGHT}", "scenes/capture.tscn", "--",
           f"--shot={SHOT}", f"--frames={FRAMES}", "--only=__nothing__"]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=110)


def load_pixels(path):
    raw = subprocess.run(["convert", path, "-depth", "8", "rgb:-"],
                         capture_output=True, check=True).stdout
    if len(raw) != WIDTH * HEIGHT * 3:
        raise SystemExit(f"unexpected pixel count {len(raw)}")
    return raw


def main():
    for tool in ("xvfb-run", "convert"):
        if not have(tool):
            print(f"SKIPPED: {tool} is not installed")
            return 0

    proc = render()
    output = proc.stdout + proc.stderr
    failures = []
    if proc.returncode != 0:
        failures.append(f"the game exited {proc.returncode}")
    if "SCRIPT ERROR" in output:
        failures.append("the game printed a SCRIPT ERROR while running")
    if not os.path.isfile(SHOT):
        print("RENDER FAILED - no frame produced")
        print(output[-800:])
        print("MINIMAP_RENDER=FAIL")
        return 1
    print(f"rendered {SHOT} ({os.path.getsize(SHOT)} bytes)")

    raw = load_pixels(SHOT)

    def pixel(x, y):
        i = (y * WIDTH + x) * 3
        return raw[i], raw[i + 1], raw[i + 2]

    def lum(p):
        return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]

    x0, y0, w, h = MAP
    strokes = 0
    red = 0
    for y in range(y0 + 6, y0 + h - 6):
        for x in range(x0 + 6, x0 + w - 6):
            r, g, b = pixel(x, y)
            if r - g > 60 and r - b > 60:
                red += 1
            # A drawn stroke is brighter than the sky it sits on; smooth sky has
            # no such pixel anywhere.
            if lum((r, g, b)) - min(lum(pixel(x - 6, y)), lum(pixel(x + 6, y)),
                                    lum(pixel(x, y - 6)), lum(pixel(x, y + 6))) > 25:
                strokes += 1
    print(f"minimap rectangle {MAP}: {strokes} drawn strokes, {red} red marker pixels")

    if strokes < STROKE_MIN:
        failures.append(f"the minimap rectangle holds {strokes} drawn strokes, fewer "
                        f"than the {STROKE_MIN} its outline needs - it is empty sky")
    if red < RED_MIN:
        failures.append(f"the minimap rectangle holds {red} red marker pixels, fewer "
                        f"than the {RED_MIN} the player's arrow needs")

    print(f"\n{2 - len(failures)}/2 render invariants hold")
    for f in failures:
        print(f"  FAILED: {f}")
    print("MINIMAP_RENDER=" + ("PASS" if not failures else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
