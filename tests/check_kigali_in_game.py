#!/usr/bin/env python3
"""Assert the game agrees with the converter about a real circuit.

The converter decides whether a course can be driven. That judgement is only
worth anything if it agrees with the engine that will drive it, and the unit
tests cannot tell you that: they check the converter against itself and against
numbers copied from a previous run. So this takes the converter's real output for
a real route, puts it into the real TrackData, and asks the real game - which
computes the same two quantities from its own code, in its own language, through
its own Catmull-Rom and its own 2 m resample.

It also pins down the *reason* Kigali cannot be raced on yet. The game must
report the same two failures the converter reports, at the same magnitudes:

  * a tightest corner far below the 15 m floor, and
  * a place where the centreline passes within a road's width of itself.

A converter that disagreed with the engine here would make every judgement about
every course worthless, so disagreement is the failure this exists to catch.

The project source is restored on the way out, whatever happens.

Run:  python3 tests/check_kigali_in_game.py [path/to/course.gpx]
"""

import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = ROOT
TRACK_DATA = os.path.join(PROJECT, "scripts", "track", "track_data.gd")
CONVERTER = os.path.join(ROOT, "tools", "gpx_to_track.py")
DEFAULT_GPX = "/tmp/kigali_local.gpx"

TOLERANCE_RADIUS = 2.5      # metres; the two pipelines resample slightly differently
TOLERANCE_SEPARATION = 2.5
TOLERANCE_LAP = 0.02

CHECKS = []
FAILURES = []


def check(condition, message):
    CHECKS.append(condition)
    if condition:
        print(f"  ok    {message}")
    else:
        FAILURES.append(message)
        print(f"  FAIL  {message}")


def convert(gpx):
    proc = subprocess.run(
        [sys.executable, CONVERTER, gpx, "--spacing", "45", "--name", "KIGALI",
         "--half-width", "6.0", "--rounds", "0"],
        capture_output=True, text=True, timeout=110)
    if proc.returncode != 0:
        raise SystemExit("the converter refused the route:\n" + proc.stderr[-600:])
    radius = float(re.search(r"radius\s+([\d.]+) m", proc.stderr).group(1))
    separation = float(re.search(r"separation\s+([\d.]+) m", proc.stderr).group(1))
    lap = float(re.search(r"lap ([\d.]+) m", proc.stderr).group(1))
    return proc.stdout, {"radius": radius, "separation": separation, "lap": lap}


def run_game():
    proc = subprocess.run(
        ["godot", "--headless", "--path", PROJECT, "scenes/test_runner.tscn"],
        capture_output=True, text=True, timeout=115)
    return proc.stdout + proc.stderr


def main():
    gpx = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_GPX
    if not os.path.isfile(gpx):
        print(f"SKIPPED: no course at {gpx}")
        return 0
    if not os.path.isfile(TRACK_DATA) or not os.path.isfile(CONVERTER):
        print("SKIPPED: the project or the converter is not where it should be")
        return 0
    if shutil.which("godot") is None:
        print("SKIPPED: godot is not on PATH")
        return 0

    block, port = convert(gpx)
    print(f"converter says: lap {port['lap']:.0f} m, tightest corner "
          f"{port['radius']:.1f} m, closest approach {port['separation']:.1f} m")

    backup = TRACK_DATA + ".assembled-check.bak"
    shutil.copyfile(TRACK_DATA, backup)
    try:
        src = open(TRACK_DATA, encoding="utf-8").read()
        anchor = "const LIST := [SUNSET, ALPINE]"
        if src.count(anchor) != 1:
            print("SKIPPED: track_data.gd is not in the shape this expects")
            return 0
        open(TRACK_DATA, "w", encoding="utf-8").write(
            src.replace(anchor, block.rstrip("\n") + "\n\n"
                        + "const LIST := [SUNSET, ALPINE, KIGALI]"))

        out = run_game()
        radius = re.search(r"KIGALI: tightest corner radius is ([\d.]+) m", out)
        approach = re.search(r"KIGALI: no pinch points \(closest approach ([\d.]+) m", out)
        lap = re.search(r"KIGALI: lap is (\d+) m", out)
        check(radius is not None and approach is not None and lap is not None,
              "the game loaded the circuit and measured it")
        if radius is None or approach is None or lap is None:
            print(out[-1200:])
            return finish()
        game = {"radius": float(radius.group(1)),
                "separation": float(approach.group(1)),
                "lap": float(lap.group(1))}
        print(f"the game says:  lap {game['lap']:.0f} m, tightest corner "
              f"{game['radius']:.1f} m, closest approach {game['separation']:.1f} m")

        check(abs(game["lap"] - port["lap"]) < port["lap"] * TOLERANCE_LAP,
              f"lap agrees ({game['lap']:.0f} vs {port['lap']:.0f} m)")
        check(abs(game["radius"] - port["radius"]) < TOLERANCE_RADIUS,
              f"tightest corner agrees ({game['radius']:.1f} vs {port['radius']:.1f} m)")
        check(abs(game["separation"] - port["separation"]) < TOLERANCE_SEPARATION,
              f"closest approach agrees ({game['separation']:.1f} vs "
              f"{port['separation']:.1f} m)")

        # And the verdict itself, from the engine's own thresholds.
        check(game["radius"] < 15.0 and game["separation"] < 19.2,
              f"the engine rejects the drawn route too: corner {game['radius']:.1f} m "
              f"against 15, approach {game['separation']:.1f} m against 19.2")
        print(f"  --    the suite as a whole says "
              f"{'PASS' if 'TESTS=PASS' in out else 'FAIL'}, which is expected "
              f"while KIGALI is in the list")
        return finish()
    finally:
        shutil.move(backup, TRACK_DATA)


def finish():
    print(f"\n{len(CHECKS) - len(FAILURES)}/{len(CHECKS)} checks hold")
    for f in FAILURES:
        print(f"  FAILED: {f}")
    print("KIGALI_IN_GAME=" + ("PASS" if not FAILURES else "FAIL"))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    code = 0
    try:
        code = main()
    finally:
        left = open(TRACK_DATA, encoding="utf-8").read().count("KIGALI")
        print(f"project restored: {left} KIGALI left in track_data.gd")
    sys.exit(code)
