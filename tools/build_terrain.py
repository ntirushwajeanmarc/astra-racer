#!/usr/bin/env python3
"""Build the ground the circuit is actually driven on, and put the road on it.

`fetch_dem.py` pulls a real elevation model. That model and the circuit did not
agree, and could not have: the road's height came from the GPX the route was
published as, and the ground's came from SRTM, and the two are different
measurements of different things. Over the Kigali lap the terrain came out
*above* the road for 47% of its length, by as much as ten metres - a hillside
straight through the racing line - and the road floated up to nine metres above
the ground for another fifth of it.

This is the fix, and it goes in one direction only: **the road takes its height
from the ground, and then the ground is graded to meet the road.**

  1. Read the circuit's control points and sample the elevation model under each
     one. That is the ground the road runs over.
  2. Smooth that profile around the lap. Raw 30 m elevation data is a staircase,
     and a staircase is not drivable; smoothing turns it into gradients. This
     also caps the gradient, because a real road does not climb at 20%.
  3. Resample the smoothed control points exactly the way the game does, so the
     profile here and the ribbon the game builds are the same curve.
  4. **Carve** that profile into the heightmap: every pixel within the corridor
     is pulled to the road's height, tapering back to the real ground over
     `--taper` metres. That is what a road cut into a hillside is, and it is
     what stops the ground and the track from intersecting.
  5. Write the terrain as a chunked, vertex-coloured mesh with real normals,
     and hand the circuit its new control-point heights.

The carve is the whole point. Lowering the terrain everywhere would sink the
city; raising the road would leave it on stilts. Grading a corridor is what is
actually done to the ground when a road is put through it.

Output:
    <name>_heightmap.png        the carved model, replacing the raw one
    <name>_heightmap_raw.png    the original, kept so the carve is repeatable
    <name>_terrain.glb          chunked, vertex-coloured, with real normals
    <name>_terrain.json         updated georeference and carve record
    <name>_road_profile.json    the new y of every control point

Usage:
  python3 tools/build_terrain.py --out assets/terrain --name kigali \
      --write-track scripts/track/track_data.gd
"""

import argparse
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import city_textures
from build_city import (Gltf, Surface,
                        read_centreline, sample_loop, terrain_offset)

GROUND_TILE = 16.0          # metres per repeat of the ground detail texture
CHUNK_CELLS = 32            # terrain cells per chunk, per axis


# --------------------------------------------------------------- the elevation

class Heightfield:
    """The elevation model, in the terrain's own local frame.

    x east, z south, both in metres from the centre of the model; y in metres
    above the model's lowest point. Sampling is bilinear, because the carve and
    the road profile both need a height *between* pixels and nearest-neighbour
    there produces the 25 m staircase this tool exists to remove.
    """

    graded = None           # per-pixel metres to the nearest road sample

    def __init__(self, meta, values):
        self.grid = meta["grid"]
        self.lo = meta["elevation_min_m"]
        self.hi = meta["elevation_max_m"]
        self.metres_per_pixel = meta["metres_per_pixel"]
        self.half = (self.metres_per_pixel * (self.grid - 1)) / 2.0
        self.span = self.hi - self.lo
        self.values = values            # metres above the model's zero

    @classmethod
    def load(cls, meta, path):
        """The model as it is on disk.

        The grid comes from the image rather than the metadata, and the metres
        per pixel from the ground the model covers. This tool writes a *finer*
        heightmap than it reads - refine() resamples before the carve - so the
        two disagree by construction after the first run, and trusting the
        metadata here would read the raw 256-pixel model as though it were the
        511-pixel one and produce a quarter of Kigali stretched over all of it.
        What does not change is the extent: the same ground, sampled more
        finely.
        """
        from PIL import Image
        img = Image.open(path)
        raw = list(img.getdata())
        grid = img.size[0]
        extent = meta.get("extent_metres",
                          meta["metres_per_pixel"] * (meta["grid"] - 1))
        meta = dict(meta)
        meta["grid"] = grid
        meta["metres_per_pixel"] = extent / float(grid - 1)
        meta["extent_metres"] = extent
        span = meta["elevation_max_m"] - meta["elevation_min_m"]
        return cls(meta, [v / 65535.0 * span for v in raw])

    def to_pixel(self, x, z):
        return ((x + self.half) / (2 * self.half) * (self.grid - 1),
                (z + self.half) / (2 * self.half) * (self.grid - 1))

    def to_metres(self, i, j):
        return (i / (self.grid - 1) * 2 * self.half - self.half,
                j / (self.grid - 1) * 2 * self.half - self.half)

    def at(self, i, j):
        i = min(self.grid - 1, max(0, i))
        j = min(self.grid - 1, max(0, j))
        return self.values[j * self.grid + i]

    def sample(self, x, z):
        """Bilinear height at a point in the terrain's frame."""
        u, v = self.to_pixel(x, z)
        i0 = int(math.floor(u))
        j0 = int(math.floor(v))
        fu = u - i0
        fv = v - j0
        a = self.at(i0, j0)
        b = self.at(i0 + 1, j0)
        c = self.at(i0, j0 + 1)
        d = self.at(i0 + 1, j0 + 1)
        return (a * (1 - fu) * (1 - fv) + b * fu * (1 - fv)
                + c * (1 - fu) * fv + d * fu * fv)

    def sample_faceted(self, x, z):
        """Height on the *triangulated* surface, and the three corners that make
        it, with their barycentric weights.

        The mesh is two triangles per cell with the diagonal running from the
        (0,0) corner to the (1,1) one, and a triangulated quad is not its own
        bilinear interpolation: on a cell whose corners twist, the triangles
        stand above the smooth surface along that diagonal. Grading against the
        bilinear height therefore leaves the ground poking through the road on
        exactly the cells where it is most warped, which is where the road most
        needs it not to. This is the surface the car actually hits.
        """
        u, v = self.to_pixel(x, z)
        i0 = min(self.grid - 2, max(0, int(math.floor(u))))
        j0 = min(self.grid - 2, max(0, int(math.floor(v))))
        fu = min(1.0, max(0.0, u - i0))
        fv = min(1.0, max(0.0, v - j0))
        h00 = self.at(i0, j0)
        h11 = self.at(i0 + 1, j0 + 1)
        if fv >= fu:
            h01 = self.at(i0, j0 + 1)
            corners = ((i0, j0, 1.0 - fv), (i0, j0 + 1, fv - fu), (i0 + 1, j0 + 1, fu))
            height = h00 + (fv - fu) * (h01 - h00) + fu * (h11 - h00)
        else:
            h10 = self.at(i0 + 1, j0)
            corners = ((i0, j0, 1.0 - fu), (i0 + 1, j0 + 1, fv), (i0 + 1, j0, fu - fv))
            height = h00 + fv * (h11 - h00) + (fu - fv) * (h10 - h00)
        return height, corners

    def refine(self, factor, relief, verbose=False):
        """Resample onto a finer grid and give the result relief of its own.

        A 25 m elevation model is the right data and the wrong resolution to
        stand next to. It is right because it is where Kigali's hills really
        are; it is wrong because 25 m is about the size of a house, so the
        ground beside the road is one flat facet per four car-lengths and the
        car appears to be driving across a folded map.

        Two things happen here, and they are different. **Resampling** is
        Catmull-Rom through the samples, which invents no shape - it is the
        same hill, read at a finer step, and a bicubic fit through four points
        follows the slope through a sample instead of kinking at it the way
        linear interpolation does. **Relief** is fractal noise added on top,
        which does invent shape, and is the honest thing to do: the real ground
        between two SRTM samples is not the straight line between them, and a
        few octaves of the right amplitude is a better guess at it than flat.

        The amplitude leans on slope, because that is where the difference
        shows: a valley floor really is nearly flat, and a hillside really is
        gullied. And it happens *before* the carve, so the corridor the road
        runs in is graded flat through it like any other ground.
        """
        fine = (self.grid - 1) * factor + 1
        step = self.metres_per_pixel / float(factor)
        values = [0.0] * (fine * fine)
        for j in range(fine):
            v = j / float(factor)
            for i in range(fine):
                u = i / float(factor)
                values[j * fine + i] = self._catmull(u, v)

        if relief > 0.0:
            # Slope from the *coarse* model, so the relief follows the hill
            # rather than following itself.
            for j in range(fine):
                for i in range(fine):
                    x = i * step - self.half
                    z = j * step - self.half
                    index = j * fine + i
                    a = values[max(0, index - 1)]
                    b = values[min(fine * fine - 1, index + 1)]
                    c = values[max(0, index - fine)]
                    d = values[min(fine * fine - 1, index + fine)]
                    slope = math.hypot(b - a, d - c) / (2.0 * step)
                    amount = relief * (0.35 + min(1.0, slope * 2.2))
                    n = (value_noise(x, z, 140.0, 11) - 0.5) * 1.0
                    n += (value_noise(x, z, 62.0, 12) - 0.5) * 0.55
                    n += (value_noise(x, z, 27.0, 13) - 0.5) * 0.30
                    values[index] += n * amount

        self.grid = fine
        self.metres_per_pixel = step
        self.values = values
        # `half` is unchanged: the model still covers the same ground.
        if verbose:
            print("#   refined to %d x %d at %.2f m, relief up to %.1f m"
                  % (fine, fine, step, relief * 1.35), file=sys.stderr)

    def _catmull(self, u, v):
        """Catmull-Rom through the coarse samples at fractional index (u, v)."""
        i = int(math.floor(u))
        j = int(math.floor(v))
        fu = u - i
        fv = v - j

        def row(jj):
            p0 = self.at(i - 1, jj)
            p1 = self.at(i, jj)
            p2 = self.at(i + 1, jj)
            p3 = self.at(i + 2, jj)
            return _spline(p0, p1, p2, p3, fu)

        return _spline(row(j - 1), row(j), row(j + 1), row(j + 2), fv)

    def write(self, path):
        from PIL import Image
        img = Image.new("I;16", (self.grid, self.grid))
        span = max(1e-6, self.span)
        img.putdata([max(0, min(65535, int(round(v / span * 65535.0))))
                     for v in self.values])
        img.save(path)


def _spline(p0, p1, p2, p3, t):
    """One span of a Catmull-Rom curve."""
    t2 = t * t
    t3 = t2 * t
    return 0.5 * ((2.0 * p1)
                  + (-p0 + p2) * t
                  + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
                  + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


def smooth_ring(values, window):
    """Circular moving average. The lap is a loop, so the smoothing has to be."""
    n = len(values)
    if n == 0 or window < 1:
        return list(values)
    half = max(1, int(window))
    # Prefix sums over three copies, so the wrap costs nothing and is exact.
    doubled = values * 3
    prefix = [0.0]
    for v in doubled:
        prefix.append(prefix[-1] + v)
    out = []
    for i in range(n):
        centre = i + n
        lo = centre - half
        hi = centre + half + 1
        out.append((prefix[hi] - prefix[lo]) / float(hi - lo))
    return out


def limit_gradient(points, max_grade):
    """Flatten any stretch that climbs faster than a road can.

    Run forwards and backwards around the loop, each pass pulling a point down
    to what its neighbour plus the maximum gradient allows. Two passes converge
    because the constraint is one-sided in each direction, and doing it on the
    loop rather than a line is what stops a step appearing at the start line.
    """
    n = len(points)
    ys = [p[1] for p in points]
    for _ in range(2):
        for direction in (1, -1):
            for k in range(n * 2):
                i = (k * direction) % n
                j = (i + direction) % n
                run = math.dist((points[i][0], points[i][2]),
                                (points[j][0], points[j][2]))
                ceiling = ys[i] + run * max_grade
                if ys[j] > ceiling:
                    ys[j] = ceiling
    return ys


# ------------------------------------------------------------------- the carve

class Corridor:
    """Distance from a point to the road, and the road's height there.

    A bucketed grid over the resampled centreline: the carve asks this once per
    heightmap pixel, and over 65 000 pixels against 7 181 samples the brute
    force version is half a billion distance tests.
    """

    def __init__(self, loop, cell):
        self.cell = cell
        self.loop = loop
        self.grid = {}
        for i, p in enumerate(loop):
            key = (int(math.floor(p[0] / cell)), int(math.floor(p[2] / cell)))
            self.grid.setdefault(key, []).append(i)

    def nearest(self, x, z, limit):
        """(distance, road height) for the nearest centreline sample, or None."""
        best = limit * limit
        found = None
        reach = int(math.floor(limit / self.cell)) + 1
        cx = int(math.floor(x / self.cell))
        cz = int(math.floor(z / self.cell))
        for gx in range(cx - reach, cx + reach + 1):
            for gz in range(cz - reach, cz + reach + 1):
                for i in self.grid.get((gx, gz), ()):
                    p = self.loop[i]
                    dx = p[0] - x
                    dz = p[2] - z
                    d = dx * dx + dz * dz
                    if d < best:
                        best = d
                        found = p[1]
        if found is None:
            return None
        return math.sqrt(best), found


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def carve(field, loop_local, flat, taper, clearance, corridor_width, verbose):
    """Grade the heightmap into the road corridor, in two passes.

    **Grade.** Every pixel within `taper` of the road is blended towards the
    road's height there, fully inside `flat` and tapering off with a smoothstep
    beyond it. The target is the road's height less its clearance, so the ribbon
    ends up sitting a fraction of a metre proud of the ground rather than
    exactly in it - a road carved to precisely its own height z-fights with the
    ground along its whole length and its kerbs have nothing to stand on.

    **Clamp.** Then every road sample pushes down any pixel within `flat` that
    is still above it. This is the pass that handles the circuit crossing over
    itself, which a city street loop does: where two stretches at different
    heights share one 25 m elevation pixel, the grading pass only knows about
    whichever is nearer, and would bury the other. Doing it as a second pass
    that can only lower the ground keeps the climbs smooth - taking the lowest
    road within a radius in one pass instead drags every uphill stretch down to
    the height of the ground 25 m behind it, and puts half the lap on a
    three-metre embankment.
    """
    corridor = Corridor(loop_local, cell=max(32.0, taper * 0.5))
    moved = 0
    biggest = 0.0
    total = 0.0
    # How far each pixel is from the road, kept for the colouring. This used to
    # be the *grading weight* instead, which is 1.0 out to `flat` and then
    # tapers over ninety metres - so "heavily graded" reached about seventy
    # metres from the centreline and the bare-earth colour it selects painted a
    # hundred-and-forty-metre brown swathe down both sides of a city street for
    # fourteen kilometres. What the colour actually wants to know is how far
    # away the road is, in metres, so that is what is recorded.
    field.graded = [1.0e9] * (field.grid * field.grid)
    for j in range(field.grid):
        for i in range(field.grid):
            x, z = field.to_metres(i, j)
            hit = corridor.nearest(x, z, taper)
            if hit is None:
                continue
            distance, road_y = hit
            road_y -= clearance
            if distance <= flat:
                weight = 1.0
            else:
                weight = 1.0 - smoothstep((distance - flat) / (taper - flat))
            if weight <= 0.0:
                continue
            index = j * field.grid + i
            field.graded[index] = min(field.graded[index], distance)
            before = field.values[index]
            after = before + (road_y - before) * weight
            field.values[index] = after
            shift = abs(after - before)
            if shift > 0.01:
                moved += 1
                total += shift
                biggest = max(biggest, shift)

    settled, deepest = _settle(field, loop_local, clearance, corridor_width)
    if verbose:
        print("#   graded %d of %d pixels, mean %.2f m, largest %.1f m"
              % (moved, field.grid * field.grid,
                 total / max(1, moved), biggest), file=sys.stderr)
        print("#   settled %d corners to get the ground under the road and "
              "its shoulders, deepest correction %.2f m" % (settled, deepest),
              file=sys.stderr)
    return moved


def _settle(field, loop_local, clearance, corridor, passes=8):
    """Push the ground down until it is under the *whole* road everywhere.

    The grading pass works on pixels; the road runs *between* them, and its
    height there is the bilinear blend of the four around it. So a pixel can be
    correctly graded and the surface between it and its neighbour can still rise
    through the tarmac - which is what left forty places on the lap with the
    hillside poking up through the road.

    This measures the surface the car will actually hit - the triangulated one,
    not the bilinear one - and where it is too high, lowers the three corners
    that produce it by exactly enough. Spreading the correction over them in
    proportion to their own barycentric weights, divided by the sum of the
    squares of those weights, moves the surface by precisely the excess and
    moves each corner as little as possible: the ground is corrected where the
    road is and nowhere else, and no embankment is invented. A few passes,
    because neighbouring samples share corners and each correction perturbs the
    next.

    It samples **across** the road, not only down its centreline, and that is
    the whole of the difference between this working and not. Sampling the
    centreline alone leaves the edges to look after themselves, and on a 12.5 m
    elevation grid the edges are inside the same cell as the middle: where the
    Kigali lap runs back alongside itself the ground rose through the tarmac
    five metres from the centre for six hundred and fifty metres, an earth ramp
    at the road's own edge that a car could drive up and into the barrier. The
    centreline was clear the entire time, so the check that watched it was
    happy, and so was this.

    `corridor` reaches past the kerbs to the barrier line, because the strip
    between the two is where a car that runs wide ends up and it has to be
    ground rather than a wall. Past that the hillside is allowed back: a bank
    behind a barrier is a bank, and `measure_shoulders` tells the game how tall
    to build the barrier in front of it.
    """
    grid = field.grid
    settled = 0
    deepest = 0.0
    # Across the road at a metre and a half: finer than the car is wide, and
    # far finer than the elevation model, so no ridge can hide between two
    # samples.
    laterals = [0.0]
    step = 1.5
    d = step
    while d <= corridor + 0.001:
        laterals.extend((-d, d))
        d += step
    n = len(loop_local)
    for _ in range(passes):
        worst = 0.0
        for k in range(n):
            p = loop_local[k]
            q = loop_local[(k + 1) % n]
            tx, tz = q[0] - p[0], q[2] - p[2]
            length = math.hypot(tx, tz)
            if length < 1e-6:
                continue
            # The game's own right: TrackInfo builds it as (-tangent.z, 0,
            # tangent.x). Only the axis matters here, not which side is which.
            rx, rz = -tz / length, tx / length
            ceiling = p[1] - clearance
            for lateral in laterals:
                here, corners = field.sample_faceted(p[0] + rx * lateral,
                                                     p[2] + rz * lateral)
                excess = here - ceiling
                if excess <= 0.001:
                    continue
                worst = max(worst, excess)
                norm = sum(w * w for _, _, w in corners)
                if norm <= 1e-9:
                    continue
                for i, j, w in corners:
                    if w <= 0.0:
                        continue
                    index = j * grid + i
                    field.values[index] -= excess * w / norm
                    settled += 1
        deepest = max(deepest, worst)
        if worst <= 0.001:
            break
    return settled, deepest


# ------------------------------------------------------------------ the colour

# Kigali's ground. It is a green city on red earth at 1 500 m, in a climate
# with no dry season worth the name: the hills are grass, banana and eucalyptus
# almost to the top, and the red laterite shows where something has cut into
# them - a track, a quarry, a slope too steep to hold soil. Written as sRGB and
# converted on the way out, like every other palette in this project.
GROUND_LOW = (0.33, 0.44, 0.24)     # damp valley floor, the darkest green
GROUND_MID = (0.40, 0.50, 0.26)     # the hillsides, which is most of it
GROUND_HIGH = (0.47, 0.52, 0.30)    # ridge tops, a little drier and paler
GROUND_STEEP = (0.56, 0.33, 0.21)   # laterite on a slope that will not hold
GROUND_CLIFF = (0.50, 0.40, 0.33)   # rock, where even laterite is gone

GROUND_SCRUB = (0.30, 0.42, 0.22)   # the dark green of banana and eucalyptus
GROUND_DRY = (0.54, 0.51, 0.30)     # burnt-off grass and bare compound
GROUND_BARE = (0.52, 0.31, 0.21)    # the red edge of a road


def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def _hash2(i, j, seed):
    h = (i * 73856093) ^ (j * 19349663) ^ (seed * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    return ((h ^ (h >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def value_noise(x, z, scale, seed):
    """Smooth value noise at one scale. Deterministic from the coordinates, so
    the same ground comes out of every build."""
    u, v = x / scale, z / scale
    i, j = math.floor(u), math.floor(v)
    fu, fv = u - i, v - j
    su, sv = smoothstep(fu), smoothstep(fv)
    a = _hash2(i, j, seed)
    b = _hash2(i + 1, j, seed)
    c = _hash2(i, j + 1, seed)
    d = _hash2(i + 1, j + 1, seed)
    return (a * (1 - su) * (1 - sv) + b * su * (1 - sv)
            + c * (1 - su) * sv + d * su * sv)


def ground_colour(x, z, height_fraction, slope, road_distance, verge):
    """Albedo for one terrain vertex.

    Height and slope set the broad character - valley green low down, drier up
    the ridges, bare laterite where it is too steep to hold anything. On its own
    that produces a hillside of one colour, because over the few hundred metres
    you can actually see, height and slope barely change; so three octaves of
    smooth noise mix in patches of scrub and dry grass at about 420 m, 150 m and
    55 m, which is the scale real vegetation changes at.

    `road_distance` is how far this vertex is from the racing line, in metres.
    The metre or two of ground at the edge of a Kigali street is red earth and
    saying so is what stops the tarmac reading as a road laid on a lawn - but
    only the metre or two. `verge` is where that stops: past it the ground is
    whatever the hill was, which on this circuit is a city, and a city is not
    brown.
    """
    if height_fraction < 0.45:
        base = mix(GROUND_LOW, GROUND_MID, height_fraction / 0.45)
    else:
        base = mix(GROUND_MID, GROUND_HIGH, (height_fraction - 0.45) / 0.55)

    broad = value_noise(x, z, 420.0, 1)
    mid = value_noise(x, z, 150.0, 4)
    fine = value_noise(x, z, 55.0, 2)
    patch = broad * 0.45 + mid * 0.35 + fine * 0.20
    if patch > 0.55:
        base = mix(base, GROUND_SCRUB, smoothstep((patch - 0.55) / 0.28))
    elif patch < 0.42:
        base = mix(base, GROUND_DRY, smoothstep((0.42 - patch) / 0.30) * 0.75)

    # Slope wins over both, but only real slope. These thresholds started at a
    # 12 degree hillside and turned most of Kigali to bare laterite, because
    # most of Kigali *is* a 12 degree hillside - it is a city built over about
    # a thousand hills, and grass grows on all of them. Bare earth belongs on
    # the parts too steep to hold it, which here starts around 20 degrees.
    if slope > 0.38:
        base = mix(base, GROUND_STEEP, smoothstep((slope - 0.38) / 0.45) * 0.85)
    if slope > 0.95:
        base = mix(base, GROUND_CLIFF, smoothstep((slope - 0.95) / 0.5))

    # And the road's own edge: full strength at the tarmac, gone by `verge`.
    if road_distance < verge:
        edge = 1.0 - smoothstep(road_distance / verge)
        base = mix(base, GROUND_BARE, edge * 0.8)

    shade = 0.90 + value_noise(x, z, 26.0, 3) * 0.20
    return tuple(min(1.0, c * shade) for c in base)


# ------------------------------------------------------------------------ mesh

def build_mesh(field, gltf, material, verge, verbose):
    """The terrain as chunked meshes, with smooth normals and vertex colours.

    Vertices are shared inside a chunk. They used to be four per cell, which
    for a heightfield is four copies of the same point with the same normal,
    the same UV and the same colour - the mesh was four times the size it had
    any reason to be, and that size was the argument against sampling the
    elevation model any more finely than 25 m. Sharing them pays for the
    refinement and leaves the file smaller than it started.

    Chunk edges still duplicate: the last row and column of one chunk are the
    first of the next. That is the price of chunking at all, and it is the
    reason the normals below are computed from the heightfield rather than from
    the triangles - two chunks must agree exactly along a seam they each own a
    copy of, or the tiling shows as a grid over the whole valley.
    """
    grid = field.grid
    span = max(1e-6, field.span)
    step = field.metres_per_pixel

    def normal(i, j):
        dx = (field.at(i + 1, j) - field.at(i - 1, j)) / (2.0 * step)
        dz = (field.at(i, j + 1) - field.at(i, j - 1)) / (2.0 * step)
        length = math.sqrt(dx * dx + dz * dz + 1.0)
        return (-dx / length, 1.0 / length, -dz / length)

    def slope(i, j):
        n = normal(i, j)
        return math.sqrt(max(0.0, 1.0 - n[1] * n[1])) / max(0.05, n[1])

    chunks = 0
    triangles = 0
    for cj in range(0, grid - 1, CHUNK_CELLS):
        for ci in range(0, grid - 1, CHUNK_CELLS):
            i_end = min(ci + CHUNK_CELLS, grid - 1)
            j_end = min(cj + CHUNK_CELLS, grid - 1)
            wide = i_end - ci + 1
            tall = j_end - cj + 1
            surface = Surface()
            for j in range(cj, j_end + 1):
                for i in range(ci, i_end + 1):
                    x, z = field.to_metres(i, j)
                    y = field.at(i, j)
                    distance = field.graded[j * grid + i]
                    surface.pos.append((x, y, z))
                    surface.nrm.append(normal(i, j))
                    surface.uv.append((x / GROUND_TILE, z / GROUND_TILE))
                    # Straight sRGB. `Gltf.add_colours` is what converts to
                    # linear, exactly as it does for the city - converting here
                    # as well put the ground through the curve twice and sank
                    # a mid green of 0.40 to a linear 0.02, which is why the
                    # whole valley came out a flat near-black beside a city
                    # built from the same palette at the right brightness.
                    surface.col.append(
                        ground_colour(x, z, y / span, slope(i, j),
                                      distance, verge) + (1.0,))
            for j in range(tall - 1):
                for i in range(wide - 1):
                    a = j * wide + i
                    b = a + 1
                    c = a + wide
                    d = c + 1
                    # Wound so the face points up, and split along the same
                    # diagonal `sample_faceted` assumes when it decides where
                    # the surface a car will hit actually is.
                    surface.idx.extend((a, c, d, a, d, b))
            if surface.empty():
                continue
            primitives = [{
                "attributes": {
                    "POSITION": gltf.add_vec(surface.pos, "VEC3"),
                    "NORMAL": gltf.add_vec(surface.nrm, "VEC3"),
                    "TEXCOORD_0": gltf.add_vec(surface.uv, "VEC2"),
                    "COLOR_0": gltf.add_colours(surface.col),
                },
                "indices": gltf.add_indices(surface.idx),
                "material": material,
            }]
            # "-col" is Godot's own import suffix: the importer hangs a
            # StaticBody3D with a trimesh shape off each chunk and leaves the
            # mesh visible. That is what makes this the ground rather than a
            # picture of the ground - before it, the collision off the road was
            # a generated slope that ran down to one flat height for the whole
            # circuit, so a car that left the tarmac drove underneath the
            # hillside it could see.
            name = "GroundChunk_%03d_%03d-col" % (ci // CHUNK_CELLS, cj // CHUNK_CELLS)
            gltf.add_node(name, gltf.add_mesh(name, primitives))
            chunks += 1
            triangles += len(surface.idx) // 3
    if verbose:
        print("#   %d ground chunks, %d triangles" % (chunks, triangles),
              file=sys.stderr)
    return chunks, triangles


# ------------------------------------------------------------- the shoulders

def measure_shoulders(field, loop, offset, wall_lateral, probe):
    """How far the ground stands above the road just outside the barrier.

    The barrier is built at the road's own height - a ribbon 1.4 m tall
    standing on the tarmac - and that is only a barrier if the ground outside
    it is lower than its top. Where the Kigali lap runs back alongside itself,
    twenty metres away and three metres higher, it is not: the grading pass has
    to bank the ground between the two roads up to one of them, and beside the
    lower one that bank rises over its barrier at a gradient a car can simply
    drive up. It did, and came down in the oncoming road.

    Reshaping the ground cannot fix it. The elevation model's step is 12.5 m
    and the barrier stands 7.6 m from the centreline, so the whole shoulder
    fits inside one cell of it: there is no resolution there to carve a verge
    into, and trying pulls the support out from under the road itself.

    What is left is to tell the game how high that bank is, so the barrier can
    be built to stand in it rather than under it. This measures it - the
    highest the triangulated surface gets from the barrier's own line out to
    `probe` metres past it, on each side, at every sample of the lap - and
    writes it as metres above the road, which is what the track builder needs
    and is the one form that does not go wrong if the two ever disagree about
    where the road is.
    """
    n = len(loop)
    out = {"spacing": 2.0, "count": n, "wall_lateral": wall_lateral,
           "probe_metres": probe, "left": [], "right": []}
    steps = [wall_lateral + 0.5 + k for k in range(int(probe) + 1)]
    for i in range(n):
        p = loop[i]
        q = loop[(i + 1) % n]
        tx, tz = q[0] - p[0], q[2] - p[2]
        length = math.hypot(tx, tz)
        if length < 1e-6:
            out["left"].append(0.0)
            out["right"].append(0.0)
            continue
        # The game's own right: TrackInfo builds it as (-tangent.z, 0,
        # tangent.x), and the sign has to match or the two sides swap.
        rx, rz = -tz / length, tx / length
        for key, side in (("right", 1.0), ("left", -1.0)):
            tallest = 0.0
            for d in steps:
                x = p[0] + rx * side * d - offset[0]
                z = p[2] + rz * side * d - offset[2]
                here, _ = field.sample_faceted(x, z)
                tallest = max(tallest, here + offset[1] - p[1])
            out[key].append(round(tallest, 2))
    return out


# ----------------------------------------------------------- writing the track

def rewrite_track_points(path, track_name, points):
    """Put the new heights back into the circuit definition.

    Only the y of each Vector3 changes; x and z are left exactly as they were,
    because those are the route and the route is not this tool's business.
    """
    text = open(path, encoding="utf-8").read()
    start = text.find('"name": "%s"' % track_name)
    if start < 0:
        raise SystemExit("build_terrain: %s is not in %s" % (track_name, path))
    at = text.find('"points"', start)
    end = text.find("\n}", at)
    if at < 0 or end < 0:
        raise SystemExit("build_terrain: cannot find the points block")
    block = text[at:end]

    index = [0]

    def replace(match):
        i = index[0]
        index[0] += 1
        if i >= len(points):
            return match.group(0)
        return "Vector3(%s, %.1f, %s)" % (match.group(1), points[i][1], match.group(3))

    rewritten = re.sub(
        r"Vector3\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)",
        replace, block)
    if index[0] != len(points):
        raise SystemExit("build_terrain: the block has %d points, the profile has %d"
                         % (index[0], len(points)))
    open(path, "w", encoding="utf-8").write(text[:at] + rewritten + text[end:])
    return index[0]


# ------------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="assets/terrain")
    ap.add_argument("--name", default="kigali")
    ap.add_argument("--track-data", default="scripts/track/track_data.gd")
    ap.add_argument("--track-name", default="KIGALI")
    ap.add_argument("--flat", type=float, default=16.0,
                    help="metres either side of the centreline graded flat")
    ap.add_argument("--taper", type=float, default=110.0,
                    help="metres over which the grading returns to real ground")
    ap.add_argument("--smooth", type=int, default=4,
                    help="control points either side used to smooth the profile")
    ap.add_argument("--max-grade", type=float, default=0.11,
                    help="steepest the road is allowed to climb")
    ap.add_argument("--clearance", type=float, default=0.25,
                    help="metres the road sits above the graded ground")
    ap.add_argument("--detail", type=int, default=2,
                    help="how many mesh cells to put across one elevation cell")
    ap.add_argument("--relief", type=float, default=1.1,
                    help="metres of invented relief between elevation samples")
    ap.add_argument("--verge", type=float, default=17.0,
                    help="metres of bare red earth either side of the tarmac")
    ap.add_argument("--corridor", type=float, default=9.0,
                    help="metres either side kept below the road surface")
    ap.add_argument("--wall-lateral", type=float, default=7.6,
                    help="metres from the centreline the barrier stands at")
    ap.add_argument("--wall-probe", type=float, default=6.0,
                    help="metres beyond the barrier the shoulder is measured over")
    ap.add_argument("--texture-dir", default="build/city_textures")
    ap.add_argument("--no-write-track", action="store_true")
    args = ap.parse_args()

    meta_path = os.path.join(args.out, "%s_terrain.json" % args.name)
    meta = json.load(open(meta_path, encoding="utf-8"))
    raw_path = os.path.join(args.out, "%s_heightmap_raw.png" % args.name)
    live_path = os.path.join(args.out, meta["heightmap"])
    # The raw model is kept the first time the carve runs, and read every time
    # after: carving an already-carved heightmap would grade the corridor into
    # itself and slowly flatten the whole valley.
    if not os.path.exists(raw_path):
        import shutil
        shutil.copyfile(live_path, raw_path)
        print("# kept the uncarved model as %s" % raw_path, file=sys.stderr)
    field = Heightfield.load(meta, raw_path)
    # Everything from here works on the refined model. Refining before the
    # carve rather than after is what lets the corridor be graded at the
    # resolution it is actually driven at: a 16 m flat strip cut into a 25 m
    # grid is two pixels wide and comes out as a staircase, and the settle pass
    # below then spends its corrections fighting that instead of the hill.
    if args.detail > 1 or args.relief > 0.0:
        field.refine(max(1, args.detail), args.relief, True)
    offset = terrain_offset(args.track_data, args.track_name)

    control, _ = read_centreline(args.track_data, args.track_name)
    print("# %d control points, elevation model %d x %d at %.0f m"
          % (len(control), field.grid, field.grid, field.metres_per_pixel),
          file=sys.stderr)

    # 1. the ground under each control point, in circuit coordinates
    sampled = []
    for p in control:
        y = field.sample(p[0] - offset[0], p[2] - offset[2]) + offset[1]
        sampled.append((p[0], y, p[2]))
    before = [p[1] for p in control]

    # 2. smooth it, then cap the gradient
    heights = smooth_ring([p[1] for p in sampled], args.smooth)
    smoothed = [(p[0], h + args.clearance, p[2]) for p, h in zip(sampled, heights)]
    capped = limit_gradient(smoothed, args.max_grade)
    profile = [(p[0], h, p[2]) for p, h in zip(smoothed, capped)]

    climb = max(profile, key=lambda p: p[1])[1] - min(profile, key=lambda p: p[1])[1]
    shifts = sorted(abs(a - b[1]) for a, b in zip(before, profile))
    print("# road profile: %.0f m of climb, moved a median of %.1f m "
          "(largest %.1f m) from the GPX's own altitudes"
          % (climb, shifts[len(shifts) // 2], shifts[-1]), file=sys.stderr)

    # 3. the exact ribbon the game will build, in the terrain's frame
    loop = sample_loop(profile, 2.0)
    loop_local = [(p[0] - offset[0], p[1] - offset[1], p[2] - offset[2])
                  for p in loop]

    # 4. grade the ground into it
    print("# carving the corridor: flat to %.0f m, tapering to %.0f m"
          % (args.flat, args.taper), file=sys.stderr)
    carve(field, loop_local, args.flat, args.taper, args.clearance,
          args.corridor, True)
    field.write(live_path)

    # 5. how high the ground stands beside the road, for the barrier
    shoulders = measure_shoulders(field, loop, offset, args.wall_lateral,
                                  args.wall_probe)
    json.dump(shoulders,
              open(os.path.join(args.out, "%s_shoulders.json" % args.name),
                   "w", encoding="utf-8"), separators=(",", ":"))
    print("#   shoulder profile: the ground stands up to %.1f m above the road "
          "at the barrier line, over %d of %d samples"
          % (max(max(shoulders["left"]), max(shoulders["right"])),
             sum(1 for a, b in zip(shoulders["left"], shoulders["right"])
                 if max(a, b) > 0.5), shoulders["count"]), file=sys.stderr)

    # 6. the mesh
    textures = city_textures.build(args.texture_dir, prefix=args.name + "_city")
    gltf = Gltf()
    tex = gltf.add_texture(textures["ground_detail"], "ground_detail")
    # The normal map is the gradient of the same relief the albedo was shaded
    # from, so the ground reacts to the sun instead of carrying one baked-in
    # light. It is the difference between ground and a printed picture of it,
    # and it costs one more 512-pixel tile.
    nrm = gltf.add_texture(textures["ground_normal"], "ground_normal")
    material = gltf.add_material("Ground", tex, roughness=0.94, metallic=0.0,
                                 normal=nrm, normal_scale=0.85)
    chunks, triangles = build_mesh(field, gltf, material, args.verge, True)
    glb_path = os.path.join(args.out, "%s_terrain.glb" % args.name)
    size = gltf.write(glb_path, "astra-racer build_terrain.py")

    # 7. hand the circuit its new heights
    written = 0
    if not args.no_write_track:
        written = rewrite_track_points(args.track_data, args.track_name, profile)

    meta["carve"] = {
        "flat_metres": args.flat,
        "taper_metres": args.taper,
        "smooth_control_points": args.smooth,
        "max_grade": args.max_grade,
        "clearance_metres": args.clearance,
        "raw_heightmap": os.path.basename(raw_path),
        "road_climb_metres": round(climb, 1),
    }
    meta["grid"] = field.grid
    meta["metres_per_pixel"] = round(field.metres_per_pixel, 6)
    meta["extent_metres"] = round(field.half * 2.0, 3)
    meta["detail"] = args.detail
    meta["relief_metres"] = args.relief
    meta["verge_metres"] = args.verge
    meta["corridor_metres"] = args.corridor
    meta["shoulders"] = {
        "wall_lateral_metres": args.wall_lateral,
        "probe_metres": args.wall_probe,
        "file": "%s_shoulders.json" % args.name,
    }
    meta["chunks"] = chunks
    meta["triangles"] = triangles
    json.dump(meta, open(meta_path, "w", encoding="utf-8"), indent=2)

    json.dump({"frame": "circuit coordinates",
               "note": "control-point heights taken from the carved terrain",
               "points": [[round(p[0], 1), round(p[1], 1), round(p[2], 1)]
                          for p in profile]},
              open(os.path.join(args.out, "%s_road_profile.json" % args.name),
                   "w", encoding="utf-8"), indent=2)

    print("# wrote %s (%.1f MB), %d chunks, %d triangles"
          % (glb_path, size / 1e6, chunks, triangles), file=sys.stderr)
    print("# wrote the carved %s" % live_path, file=sys.stderr)
    if written:
        print("# rewrote %d control-point heights in %s"
              % (written, args.track_data), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
