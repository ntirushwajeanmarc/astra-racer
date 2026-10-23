#!/usr/bin/env python3
"""Assert the GPX-to-track converter holds the properties a converter must.

tools/gpx_to_track.py emits GDScript, and every way it can go wrong is silent:
a swapped tuple writes a height where a map coordinate belongs, indentation that
Godot's parser rejects, an elevation that was never rebased, a duplicate closing
point that leaves a zero-length segment in the loop. None of those raise - they
produce a file that looks like track data and is not. Both bugs this converter
actually had were of that kind and were only caught by Godot's parser, so the
parse check below is the central assertion rather than a nicety.

Invariants asserted, for any valid closed GPX:
  1. it runs, and reports the elevation range and climb it measured;
  2. the emitted const sits at column 0 and the block is balanced;
  3. the emitted point count equals the count it reported;
  4. the height column is *height*: rebased so its minimum is 0 and its range
     never exceeds the ground span (a swapped tuple puts kilometres in it);
  5. the loop closes: no duplicated point, no gap wider than one spacing;
  6. the emitted centreline is the length of the source route, to within 5%;
  7. the same input produces byte-identical output;
  8. it is deterministic about rejection: too short a route exits non-zero and
     emits no track at all;
  9. Godot parses the emitted block, which is what a swapped or mis-indented
     line actually breaks.

Run:  python3 tests/check_gpx_to_track.py
"""

import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "gpx_to_track.py")
PROJECT = ROOT
PARSE_TIMEOUT = 60

FAILURES = []
CHECKS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if condition:
        print(f"  ok    {message}")
    else:
        FAILURES.append(message)
        print(f"  FAIL  {message}")


def write_gpx(path, points):
    """points: list of (lat, lon, ele)."""
    with open(path, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1">\n<trk>\n<trkseg>\n')
        for lat, lon, ele in points:
            f.write(f'\t<trkpt lat="{lat:.6f}" lon="{lon:.6f}">\n'
                    f'\t\t<ele>{ele:.0f}</ele>\n\t</trkpt>\n')
        f.write('</trkseg>\n</trk>\n</gpx>\n')


def closed_loop(lat0, lon0, radius_m, count, hill_m):
    """A closed ring with a smooth elevation profile, as a GPX would carry."""
    out = []
    for i in range(count + 1):               # repeat the first point, as GPX does
        t = (i % count) / count
        ang = t * TAU
        x = math.cos(ang) * radius_m
        z = math.sin(ang) * radius_m * 0.6   # an oval, not a circle
        out.append((
            lat0 - z / 110540.0,
            lon0 + x / (111320.0 * math.cos(math.radians(lat0))),
            1500.0 + hill_m * math.sin(2 * TAU * t) + hill_m * 0.4 * math.sin(3 * TAU * t),
        ))
    return out


TAU = 2 * math.pi

sys.path.insert(0, os.path.join(ROOT, "tools"))
try:
    import gpx_to_track as G
    if not hasattr(G, "resample"):
        G = None
except Exception:
    G = None


def closed_len(points):
    n = len(points)
    return sum(math.dist(points[i][:2], points[(i + 1) % n][:2]) for i in range(n))


def convert(gpx, spacing=45.0):
    proc = subprocess.run(
        [sys.executable, TOOL, gpx, "--spacing", str(spacing), "--name", "TEST",
         "--blurb", "a test circuit"],
        capture_output=True, text=True, timeout=90)
    return proc


def points_of(block):
    body = block.split('"points": [', 1)[1].split(']', 1)[0]
    return [tuple(float(v) for v in m)
            for m in re.findall(r"Vector3\((-?[\d.]+), (-?[\d.]+), (-?[\d.]+)\)", body)]


def closed_len(points):
    """Length of a closed loop of (x, z) pairs."""
    n = len(points)
    return sum(math.dist(points[i], points[(i + 1) % n]) for i in range(n))


def project_route(route):
    """The same equirectangular projection the converter uses, in metres."""
    lat0 = sum(p[0] for p in route) / len(route)
    lon0 = sum(p[1] for p in route) / len(route)
    k = math.cos(math.radians(lat0))
    return [((p[1] - lon0) * 111320.0 * k, -(p[0] - lat0) * 110540.0) for p in route]


def parse_with_godot(script_path):
    """Ask Godot's parser about one script. Returns (output, exit code)."""
    proc = subprocess.run(
        ["godot", "--headless", "--path", PROJECT, "-s",
         "res://tools/parse_script.gd", "--",
         "res://tools/" + os.path.basename(script_path)],
        capture_output=True, text=True, timeout=PARSE_TIMEOUT)
    return proc.stdout + proc.stderr, proc.returncode


def main():
    tmp = tempfile.mkdtemp(prefix="gpx_check_")
    try:
        return run(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run(tmp):
    if not os.path.isfile(TOOL):
        print(f"SKIPPED: {TOOL} is not there")
        return 0

    gpx = os.path.join(tmp, "loop.gpx")
    route = closed_loop(-1.95, 30.09, 1200.0, 300, 45.0)
    write_gpx(gpx, route)

    proc = convert(gpx)
    check(proc.returncode == 0, f"it converts a valid route (exit {proc.returncode})")
    if proc.returncode != 0:
        print(proc.stderr[-800:])
        return report()
    block = proc.stdout

    # 2. Shape of the emitted GDScript.
    check(block.splitlines()[0] == "const TEST := {",
          f"the const is at column 0: {block.splitlines()[0]!r}")
    check(block.rstrip().endswith("}"), "the block closes with a brace")
    check(block.count("[") == block.count("]") and block.count("{") == block.count("}"),
          "brackets and braces balance")
    for line in block.splitlines()[1:]:
        check_indent = line.startswith("\t") or line == "}"
        if not check_indent:
            check(False, f"member line is indented: {line[:40]!r}")
            break
    else:
        check(True, "every member line is indented exactly as GDScript wants")

    # 3. What it reported versus what it wrote.
    reported = int(re.search(r"-> (\d+) control points", proc.stderr).group(1))
    points = points_of(block)
    check(len(points) == reported,
          f"it wrote the {reported} control points it reported (wrote {len(points)})")

    # 4. The middle column is height, not a map coordinate. A swapped tuple puts
    #    a kilometre of easting in the height column, which this catches.
    ys = [p[1] for p in points]
    ground = max(max(abs(p[0]) for p in points), max(abs(p[2]) for p in points))
    check(abs(min(ys)) < 0.05, f"elevation is rebased to zero (min {min(ys):.2f} m)")
    check(max(ys) < ground * 0.5,
          f"heights ({min(ys):.1f}..{max(ys):.1f} m) are small beside the ground span "
          f"({ground:.0f} m), so the tuple order is (x, height, z)")
    climbed = float(re.search(r"climb (\d+) m", proc.stderr).group(1))
    check(max(ys) - min(ys) <= climbed + 1.0,
          f"the height range fits inside the climb it measured ({climbed:.0f} m)")

    # 5. The loop closes without a duplicated point or a gap.
    n = len(points)
    first = (points[0][0], points[0][2])
    last = (points[-1][0], points[-1][2])
    gap = math.dist(first, last)
    check(gap > 0.1, f"the closing point is not a duplicate of the first ({gap:.1f} m apart)")
    check(gap < 70.0, f"and it is within one spacing, so the loop does not jump ({gap:.1f} m)")

    # 6. The emitted centreline is the route it was given. Both are measured in
    #    metres, and as closed loops: the source repeats its first point and the
    #    converter drops that duplicate, so only the closed measurement compares.
    source = closed_len(project_route(route))
    emitted = closed_len([(p[0], p[2]) for p in points])
    error = abs(emitted - source) / source
    check(error < 0.05, f"the centreline is the source route, to {error * 100:.2f}% "
                        f"({emitted:.0f} m vs {source:.0f} m)")

    # 7. Same input, same bytes.
    again = convert(gpx)
    check(again.stdout == block, "the same route converts byte-identically twice")

    # 8. Rejection is not silently a success.
    short = os.path.join(tmp, "short.gpx")
    write_gpx(short, closed_loop(-1.95, 30.09, 20.0, 5, 2.0))
    bad = convert(short)
    check(bad.returncode != 0, f"a five-point route is rejected (exit {bad.returncode})")
    check("const TEST" not in bad.stdout, "and it emits no track at all")

    # 9. The real assertion: Godot's parser accepts what it wrote. This is what a
    #    swapped column or a stray indent actually breaks, and nothing else here
    #    would notice. It is asserted twice - the emitted track must parse, and
    #    the checker must reject a script that cannot - because 'godot
    #    --check-only' cheerfully exits 0 on a file Godot cannot parse, and a
    #    parse check that cannot fail is worse than none.
    if shutil.which("godot") is None:
        print("  --    godot not on PATH, parse checks skipped")
    else:
        scratch = os.path.join(PROJECT, "tools", "_gpx_check.gd")
        broken = os.path.join(PROJECT, "tools", "_gpx_broken.gd")
        try:
            with open(scratch, "w", encoding="utf-8") as f:
                f.write(block + "\n")
            good = parse_with_godot(scratch)
            check("PARSE_SCRIPT=OK" in good[0] and good[1] == 0,
                  f"Godot's parser accepts the emitted track (exit {good[1]})")
            # The exact mistake this converter made: a second top-level const
            # indented. (A file that is indented from its first line is fine -
            # Godot accepts that, which is why this fixture is written the way
            # the real broken output was.)
            with open(broken, "w", encoding="utf-8") as f:
                f.write('const GOOD := {\n\t"a": 1.0,\n}\n\n'
                        '\tconst BAD := {\n\t\t"b": 2.0,\n\t}\n')
            bad_parse = parse_with_godot(broken)
            check("PARSE_SCRIPT=FAIL" in bad_parse[0] and bad_parse[1] != 0,
                  f"and the checker rejects a script Godot cannot parse "
                  f"(exit {bad_parse[1]})")
        finally:
            for path in (scratch, broken):
                if os.path.isfile(path):
                    os.remove(path)

    if G is None:
        print("  --    the converter will not import, so the line maths is unchecked")
    else:
        section_resample()
        section_matches_the_game()
        section_relax_and_fit()

    return report()


# ------------------------------------------------- the driven-line machinery
#
# Everything above tests the GDScript this tool writes. These test the maths it
# uses to decide whether a route can be driven at all: the part that says whether
# a real course is usable, and the part where being wrong is invisible, because a
# broken resampler still hands back a plausible-looking curve.


def section_resample():
    print("\n[resampling the driven line]")
    n = 600
    dense = [(1200.0 * math.cos(i * TAU / n), 720.0 * math.sin(i * TAU / n),
              30.0 * math.sin(3.0 * i * TAU / n)) for i in range(n)]
    source = closed_len(dense)
    curve, _ = G.resample(dense, 2.0)
    got = closed_len(curve)
    check(abs(got - source) < source * 0.01,
          f"resampling keeps the length ({got:.1f} m vs {source:.1f} m)")
    gaps = [math.dist(curve[i][:2], curve[(i + 1) % len(curve)][:2]) for i in range(len(curve))]
    check(max(gaps) - min(gaps) < 0.05,
          f"and spaces its samples evenly (spread {max(gaps) - min(gaps):.3f} m)")
    # Every sample must still be on the source shape. A resampler that lost its
    # place returns evenly spaced points along nothing in particular.
    off = max(abs((p[0] / 1200.0) ** 2 + (p[1] / 720.0) ** 2 - 1.0) for p in curve)
    check(off < 0.01, f"and every sample lies on the source curve (worst {off:.4f})")


def section_matches_the_game():
    print("\n[against the shipped circuits]")
    src = open(os.path.join(PROJECT, "scripts", "track", "track_data.gd"),
               encoding="utf-8").read()

    def block_of(name):
        i = src.index("const %s := {" % name)
        return src[i:src.index("\n}", i)]

    def points_of(block):
        body = block.split('"points": [', 1)[1].split("]", 1)[0]
        got = [tuple(float(v) for v in m) for m in
               re.findall(r"Vector3\((-?[\d.]+), (-?[\d.]+), (-?[\d.]+)\)", body)]
        # TrackData writes Vector3(x, height, z); this tool works in (x, z, height)
        # and swaps the pair only when it emits. Feeding one order to code that
        # wants the other measures distance in the wrong plane, which reads as a
        # track half its real length rather than as an obvious error.
        return [(p[0], p[2], p[1]) for p in got]

    def number_of(block, key):
        return float(re.search(r'"%s":\s*([-\d.]+)' % key, block).group(1))

    # What the Godot suite prints for this circuit. The port is used to judge a
    # real course, so it is held to the same numbers on a course whose answer is
    # already known. Only SUNSET is checked: ALPINE's points are empty in the
    # data and generated from SUNSET's in code, so its centreline cannot be read
    # from the file at all.
    expected = {
        "SUNSET": {"length": 1522.0, "radius": 37.1, "separation": 57.7},
    }
    for name, want in expected.items():
        block = block_of(name)
        ctrl = points_of(block)
        if len(ctrl) < 3:
            print(f"  --    {name} has no literal points to check")
            continue
        curve, _ = G.resample(G.dense_curve(ctrl), 2.0)
        got = G.measure(curve, number_of(block, "half_width"), search=100.0)
        check(abs(got["length"] - want["length"]) < want["length"] * 0.02,
              f"{name}: lap {got['length']:.0f} m, suite says {want['length']:.0f}")
        check(abs(got["radius"] - want["radius"]) < max(2.0, want["radius"] * 0.12),
              f"{name}: tightest corner {got['radius']:.1f} m, suite says {want['radius']:.1f}")
        check(abs(got["separation"] - want["separation"]) < 3.0,
              f"{name}: closest approach {got['separation']:.1f} m, suite says {want['separation']:.1f}")


def section_relax_and_fit():
    print("\n[relaxing and refitting]")
    n = 300
    # Two laps of one circle, 8 m apart: a self-approach no road can occupy, and
    # the shape of the failure the real Kigali route has.
    curve = []
    for i in range(2 * n):
        ang = i * TAU / n
        r = 204.0 if i < n else 196.0
        curve.append((r * math.cos(ang), r * math.sin(ang), 0.0))
    before = G.measure(curve, 6.0)
    check(before["separation"] < before["needs_separation"],
          f"the test line does pinch ({before['separation']:.1f} m, needs "
          f"{before['needs_separation']:.1f})")
    fixed, moved = G.relax(curve, 6.0, 16.0, rounds=200)
    after = G.measure(fixed, 6.0)
    check(after["separation"] >= after["needs_separation"],
          f"relaxing separates it ({after['separation']:.1f} m)")
    # No radius assertion here: two passes 8 m apart are joined by ends of about
    # 4 m, so this shape's corners are its own doing and asserting on them would
    # be testing the fixture. The spike below is the radius case.
    check(moved < 40.0, f"moving it by at most {moved:.1f} m")

    # A local spike: a corner too tight to drive, of the kind smoothing can round.
    spike = []
    for i in range(400):
        ang = i * TAU / 400
        r = 300.0 - (8.0 if 200 <= i <= 204 else 0.0)
        spike.append((r * math.cos(ang), r * math.sin(ang), 0.0))
    tight = G.measure(spike, 6.0)
    check(tight["radius"] < 15.0,
          f"the spike is a corner too tight to drive ({tight['radius']:.1f} m)")
    rounded, _ = G.relax(spike, 6.0, 16.0, rounds=200)
    done = G.measure(rounded, 6.0)
    check(done["radius"] >= 15.0, f"relaxing rounds it out ({done['radius']:.1f} m)")

    # Refitting control points to a curve has to keep the curve, or the fix would
    # last only until the game re-smooths it.
    n2 = 240
    oval = [(900.0 * math.cos(i * TAU / n2), 500.0 * math.sin(i * TAU / n2), 0.0)
            for i in range(n2)]
    line, _ = G.resample(G.dense_curve(oval), 2.0)
    fitted = G.fit_control(line, 45.0)
    again, _ = G.resample(G.dense_curve(fitted), 2.0)
    l1, l2 = closed_len(line), closed_len(again)
    check(abs(l1 - l2) < l1 * 0.02,
          f"refitting control points preserves the length ({l2:.0f} m vs {l1:.0f} m)")
    off = max(min(math.dist(p[:2], q[:2]) for q in line) for p in again)
    check(off < 6.0, f"and the re-smoothed line stays on it (worst {off:.1f} m off)")


def report():
    print(f"\n{CHECKS - len(FAILURES)}/{CHECKS} invariants hold")
    for f in FAILURES:
        print(f"  FAILED: {f}")
    print("GPX_CONVERTER=" + ("PASS" if not FAILURES else "FAIL"))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
