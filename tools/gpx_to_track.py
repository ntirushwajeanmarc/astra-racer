#!/usr/bin/env python3
"""Turn a race-route GPX into TrackData control points for the racer.

The game builds every circuit from a list of control points: track_data.gd holds
them, TrackBuilder smooths them with Catmull-Rom and resamples them at exactly
2 m. So a real course becomes a drivable circuit by getting its centreline into
that list, in metres, closed, with the elevation rebased so the lowest point of
the lap is y = 0.

Two things about real course data drive the shape of this tool.

The elevation is smoothed before it becomes track data, because GPS altitude on
a drawn route is quantised to metres and the suite measures gradient between
samples 2 m apart: a stray metre there is a 50% slope, and the gradient has to
measure the hill rather than the noise.

And a hand-planned course is not a racing line. This one carries vertex spacing
from 1.1 m to 220 m, hairpins of about 5 m radius, and places where the line
passes within 6 m of itself four kilometres further round. None of that can be
occupied by a 12 m road with barriers down both sides, and all of it is a
property of the drawing rather than of the streets. Relaxing those is done on
the *driven* line, not on the control points: the game measures radius and
self-approach on the 2 m resample, and a spline that loops back between two
control points fails there while the control polygon looks perfectly legal.

Usage:
  python3 tools/gpx_to_track.py KIGALI.gpx --spacing 45 --name KIGALI \
      --half-width 6.0 --start-s 45 --checkpoints 14
Writes the GDScript constant to stdout; the measurements go to stderr.
"""

import argparse
import math
import sys

EARTH_LAT = 110540.0      # metres per degree of latitude
EARTH_LON = 111320.0      # metres per degree of longitude at the equator

MIN_RADIUS = 15.0         # the suite's floor, in metres


def parse_gpx(path):
    """Pull lat/lon/ele out of a GPX track, without an XML dependency."""
    pts = []
    lat = lon = ele = None
    for line in open(path, encoding="utf-8", errors="replace"):
        s = line.strip()
        if s.startswith("<trkpt"):
            lat = lon = None
            for part in s.replace("<trkpt", " ").replace(">", " ").split():
                if part.startswith("lat="):
                    lat = float(part.split('"')[1])
                elif part.startswith("lon="):
                    lon = float(part.split('"')[1])
            ele = None
        elif s.startswith("<ele>") and lat is not None:
            try:
                ele = float(s[5:].split("<")[0])
            except ValueError:
                ele = None
        elif s.startswith("</trkpt") and lat is not None:
            pts.append((lat, lon, ele if ele is not None else 0.0))
            lat = lon = None
    return pts


def project(points):
    """Lat/lon to local metres: x east, z south (so driving north is -Z)."""
    lat0 = sum(p[0] for p in points) / len(points)
    lon0 = sum(p[1] for p in points) / len(points)
    k = math.cos(math.radians(lat0))
    return [((p[1] - lon0) * EARTH_LON * k, -(p[0] - lat0) * EARTH_LAT, p[2])
            for p in points]


def flat_length(points):
    n = len(points)
    return sum(math.dist(points[i][:2], points[(i + 1) % n][:2]) for i in range(n))


def decimate(points, spacing):
    """Walk the polyline and keep a point every `spacing` metres."""
    n = len(points)
    out = [points[0]]
    walked = 0.0
    target = spacing
    for i in range(n - 1):
        a, b = points[i], points[i + 1]
        seg = math.dist(a[:2], b[:2])
        if seg < 1e-9:
            continue
        while walked + seg >= target:
            t = (target - walked) / seg
            out.append(tuple(a[k] + (b[k] - a[k]) * t for k in range(3)))
            target += spacing
        walked += seg
    return out


def smooth_elevation(points, window=5):
    """Circular moving average: a closed lap has no ends to treat specially."""
    n = len(points)
    half = window // 2
    out = []
    for i in range(n):
        total = sum(points[(i + k) % n][2] for k in range(-half, half + 1))
        out.append((points[i][0], points[i][1], total / (2 * half + 1)))
    return out


# ------------------------------------------------------- the game's own curve

def _catmull(p0, p1, p2, p3, t):
    """track_data.gd::_catmull, in three components."""
    t2 = t * t
    t3 = t2 * t
    return tuple(0.5 * ((2 * a1) + (-a0 + a2) * t + (2 * a0 - 5 * a1 + 4 * a2 - a3) * t2
                        + (-a0 + 3 * a1 - 3 * a2 + a3) * t3)
                 for a0, a1, a2, a3 in ((p0[0], p1[0], p2[0], p3[0]),
                                        (p0[1], p1[1], p2[1], p3[1]),
                                        (p0[2], p1[2], p2[2], p3[2])))


def dense_curve(points, per_segment=24):
    n = len(points)
    out = []
    for i in range(n):
        p0, p1, p2, p3 = (points[(i - 1) % n], points[i],
                          points[(i + 1) % n], points[(i + 2) % n])
        for k in range(per_segment):
            out.append(_catmull(p0, p1, p2, p3, k / per_segment))
    return out


def resample(dense, spacing):
    """Evenly spaced samples, the way the game resamples its own centreline.

    A faithful port of track_data.gd::sample_loop, counters and all: `walked` is
    the distance consumed from the start of the loop, `travelled` is the progress
    into the segment being walked. Conflating the two silently gives a curve a
    fraction of the right length, which then makes every measurement off it
    meaningless.
    """
    m = len(dense)
    segs = [math.dist(dense[i][:2], dense[(i + 1) % m][:2]) for i in range(m)]
    total = sum(segs)
    count = max(16, int(round(total / max(0.01, spacing))))
    step = total / count
    out = []
    idx = 0
    walked = 0.0
    travelled = 0.0
    target = 0.0
    guard = 0
    while len(out) < count and guard < count * 8:
        guard += 1
        remaining = segs[idx] - travelled
        if walked + remaining >= target:
            travelled += target - walked
            walked = target
            f = min(1.0, max(0.0, travelled / max(segs[idx], 0.0001)))
            a, b = dense[idx], dense[(idx + 1) % m]
            out.append(tuple(a[k] + (b[k] - a[k]) * f for k in range(3)))
            target += step
        else:
            walked += remaining
            travelled = 0.0
            idx = (idx + 1) % m
    return (out if out else dense), total


def measure(curve, half_width, exclusion=60.0, search=None):
    """The suite's two geometry verdicts, computed the way the suite computes them.

    The approach search is a grid only as wide as the requirement, because the
    question being asked is "is anything closer than a road can occupy" - a pair
    further apart than that is not a finding. So a curve with nothing wrong
    reports its separation as infinite rather than as its true closest approach.
    Pass `search` to widen the grid when the actual number matters.
    """
    m = len(curve)
    spacing = flat_length(curve) / m
    tightest = float("inf")
    for i in range(m):
        a, b, c = curve[(i - 1) % m], curve[i], curve[(i + 1) % m]
        ab = math.dist(a[:2], b[:2]); bc = math.dist(b[:2], c[:2]); ca = math.dist(c[:2], a[:2])
        ar = abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]))
        if ar > 1e-9 and ab > 1e-6 and bc > 1e-6 and ca > 1e-6:
            tightest = min(tightest, (ab * bc * ca) / (2.0 * ar))

    need = 2.0 * (half_width + 1.0 + 1.6) + 2.0
    skip = max(1, int(exclusion / spacing))
    cell = max(need, float(search) if search else 0.0, 1.0)
    grid = {}
    for i, q in enumerate(curve):
        grid.setdefault((int(q[0] // cell), int(q[1] // cell)), []).append(i)
    closest = float("inf")
    for i, q in enumerate(curve):
        cx, cy = int(q[0] // cell), int(q[1] // cell)
        for ox in (-1, 0, 1):
            for oy in (-1, 0, 1):
                for j in grid.get((cx + ox, cy + oy), ()):
                    gap = min(abs(j - i), m - abs(j - i))
                    if gap < skip:
                        continue
                    d = math.dist(q[:2], curve[j][:2])
                    if d < closest:
                        closest = d
    return {"length": m * spacing, "samples": m, "radius": tightest,
            "separation": closest, "needs_radius": MIN_RADIUS, "needs_separation": need}


def radius_of(curve, i):
    m = len(curve)
    a, b, c = curve[(i - 1) % m], curve[i], curve[(i + 1) % m]
    ab = math.dist(a[:2], b[:2]); bc = math.dist(b[:2], c[:2]); ca = math.dist(c[:2], a[:2])
    ar = abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]))
    if ar < 1e-9 or ab < 1e-6 or bc < 1e-6 or ca < 1e-6:
        return float("inf")
    return (ab * bc * ca) / (2.0 * ar)


def relax(curve, half_width, target_radius, rounds=600, trigger=2.0):
    """Relax the driven line itself until it can be driven.

    Smoothing where the curve is tighter than the target raises the corner radii;
    pushing approaching passes apart along the line between them removes the
    overlaps. Both act on the 2 m resample, which is the thing the game measures
    and the thing the car actually drives.
    """
    need = 2.0 * (half_width + 1.0 + 1.6) + 2.0 + 1.5     # a little margin
    m = len(curve)
    spacing = flat_length(curve) / m
    skip = max(1, int(60.0 / spacing))
    start = [q[:2] for q in curve]
    p = [[q[0], q[1], q[2]] for q in curve]

    for _ in range(rounds):
        tight = [i for i in range(m) if radius_of(p, i) < target_radius * trigger]
        if tight:
            smoothed = [row[:] for row in p]
            for i in tight:
                for k in range(3):
                    smoothed[i][k] = 0.7 * p[i][k] + 0.15 * (p[(i - 1) % m][k] + p[(i + 1) % m][k])
            p = smoothed
        grid = {}
        for i in range(m):
            grid.setdefault((int(p[i][0] // need), int(p[i][1] // need)), []).append(i)
        moved = False
        for i in range(m):
            cx, cy = int(p[i][0] // need), int(p[i][1] // need)
            for ox in (-1, 0, 1):
                for oy in (-1, 0, 1):
                    for j in grid.get((cx + ox, cy + oy), ()):
                        if j <= i:
                            continue
                        gap = min(j - i, m - (j - i))
                        if gap < skip:
                            continue
                        dx = p[i][0] - p[j][0]
                        dz = p[i][1] - p[j][1]
                        d = math.hypot(dx, dz)
                        if d >= need:
                            continue
                        if d < 1e-6:
                            dx, dz, d = 1.0, 0.0, 1.0
                        push = (need - d) * 0.5
                        p[i][0] += dx / d * push
                        p[i][1] += dz / d * push
                        p[j][0] -= dx / d * push
                        p[j][1] -= dz / d * push
                        moved = True
        if not moved and not tight:
            break

    worst = max(math.dist(p[i][:2], start[i]) for i in range(m))
    return [tuple(q) for q in p], worst


def fit_control(curve, spacing):
    """Evenly spaced control points along a curve, for the game to re-smooth."""
    n = len(curve)
    cum = [0.0]
    for i in range(n):
        cum.append(cum[-1] + math.dist(curve[i][:2], curve[(i + 1) % n][:2]))
    out = []
    i = 0
    for k in range(int(cum[-1] / spacing)):
        want = k * spacing
        while cum[i + 1] < want:
            i += 1
        seg = cum[i + 1] - cum[i]
        f = 0.0 if seg < 1e-9 else (want - cum[i]) / seg
        a, b = curve[i % n], curve[(i + 1) % n]
        out.append(tuple(a[c] + (b[c] - a[c]) * f for c in range(3)))
    return out


def deviation(source, curve, stride=5):
    """How far the relaxed line has moved off the route it came from, in metres.

    Measured both ways - farthest source point from the line, and farthest line
    point from the source - because either alone hides a real kind of drift, and
    the honest cost of making a drawn route drivable is this number, not the
    per-round movement.
    """
    thin = curve[::stride]
    if not thin:
        return 0.0
    outward = 0.0
    for p in source:
        best = min(math.dist(p[:2], q[:2]) for q in thin)
        outward = max(outward, best)
    inward = 0.0
    for q in thin:
        best = min(math.dist(q[:2], p[:2]) for p in source)
        inward = max(inward, best)
    return max(outward, inward)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gpx")
    ap.add_argument("--spacing", type=float, default=45.0)
    ap.add_argument("--smooth", type=int, default=5)
    ap.add_argument("--name", default="KIGALI")
    ap.add_argument("--blurb", default="")
    ap.add_argument("--half-width", type=float, default=6.0)
    ap.add_argument("--laps", type=int, default=3)
    ap.add_argument("--start-s", type=float, default=45.0)
    ap.add_argument("--checkpoints", type=int, default=14)
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--relax-rounds", type=int, default=200)
    ap.add_argument("--relax-spacing", type=float, default=6.0)
    ap.add_argument("--relax-target", type=float, default=16.0)
    # How much wider than the target a corner has to be before the softening
    # leaves it alone. Wide enough reaches the target but flattens the circuit;
    # narrow enough keeps the circuit but never gets a corner to 15 m.
    ap.add_argument("--relax-trigger", type=float, default=2.0)
    args = ap.parse_args()

    raw = parse_gpx(args.gpx)
    if len(raw) < 20:
        print(f"only {len(raw)} track points - not a course", file=sys.stderr)
        return 1

    pts = project(raw)
    if math.dist(pts[0][:2], pts[-1][:2]) < 30.0:
        pts = pts[:-1]
    raw_len = flat_length(pts)

    ctrl = smooth_elevation(decimate(pts, args.spacing), args.smooth)
    base = min(p[2] for p in ctrl)
    ctrl = [(p[0], p[1], p[2] - base) for p in ctrl]
    as_drawn = list(ctrl)

    curve, total = resample(dense_curve(ctrl), 2.0)
    was = measure(curve, args.half_width)
    print(f"# as drawn:  radius {was['radius']:6.1f} m (needs {MIN_RADIUS:.0f})   "
          f"separation {was['separation']:5.1f} m (needs {was['needs_separation']:.1f})",
          file=sys.stderr)

    moved = 0.0
    for rnd in range(args.rounds):
        if was["radius"] >= MIN_RADIUS and was["separation"] >= was["needs_separation"]:
            break
        # Relax a coarse copy. The fix is refitted to control points at `spacing`
        # and the game re-smooths those anyway, so relaxing the 2 m line spends
        # nearly all its time on detail that is about to be discarded.
        coarse, _ = resample(dense_curve(ctrl), args.relax_spacing)
        coarse, moved = relax(coarse, args.half_width, args.relax_target,
                              rounds=args.relax_rounds, trigger=args.relax_trigger)
        ctrl = fit_control(coarse, args.spacing)
        curve, total = resample(dense_curve(ctrl), 2.0)
        was = measure(curve, args.half_width)
        print(f"# round {rnd + 1}:   radius {was['radius']:6.1f} m   "
              f"separation {was['separation']:5.1f} m   "
              f"route moved by at most {moved:.1f} m", file=sys.stderr)

    grad = max(abs(curve[(i + 1) % len(curve)][2] - curve[i][2])
               / max(math.dist(curve[i][:2], curve[(i + 1) % len(curve)][:2]), 1e-6)
               for i in range(len(curve)))
    climb = sum(max(0.0, curve[(i + 1) % len(curve)][2] - curve[i][2])
                for i in range(len(curve)))
    drivable = was["radius"] >= MIN_RADIUS and was["separation"] >= was["needs_separation"]
    print(f"# {args.name}: {len(raw)} GPX points -> {len(ctrl)} control points, "
          f"lap {was['length']:.0f} m (source {raw_len:.0f} m)", file=sys.stderr)
    if moved > 0.0:
        print(f"#   the line deviates from the drawn route by up to "
              f"{deviation(as_drawn, curve):.1f} m", file=sys.stderr)
    print(f"#   climb {climb:.0f} m, steepest {grad * 100:.1f}% "
          f"({math.degrees(math.atan(grad)):.1f} deg)", file=sys.stderr)
    print(f"# DRIVABLE={drivable}", file=sys.stderr)

    out = [f"const {args.name} := {{"]
    for key, value in [
        ("name", '"%s"' % args.name),
        ("blurb", '"%s"' % args.blurb),
        ("half_width", "%.1f" % args.half_width),
        ("laps", "%d" % args.laps),
        ("start_s", "%.1f" % args.start_s),
        ("checkpoints", "%d" % args.checkpoints),
        ("sky_top", "Color(0.16, 0.30, 0.62)"),
        ("sky_horizon", "Color(0.95, 0.72, 0.42)"),
        ("sun_energy", 1.25),
        ("sun_angle", "Vector3(-32.0, 120.0, 0.0)"),
        ("fog", "Color(0.70, 0.68, 0.62)"),
    ]:
        out.append('\t"%s": %s,' % (key, value))
    out.append('\t"points": [')
    for i in range(0, len(ctrl), 4):
        out.append("\t\t" + " ".join(
            "Vector3(%.1f, %.1f, %.1f)," % (p[0], p[2], p[1]) for p in ctrl[i:i + 4]))
    out.append("\t],")
    out.append("}")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
