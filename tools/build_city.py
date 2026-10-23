#!/usr/bin/env python3
"""Build Kigali - the whole city, not a sample of it - as a game asset.

`fetch_buildings.py` gets the footprints. This turns them into something you can
drive past at 250 km/h and believe: real heights, real roofs, real materials,
collision where collision can matter, and none of it standing in the road.

What "real" means here, concretely:

**All of them.** The Overpass cache holds 28 716 footprints. The old asset took
the first 6 000 in whatever order the API returned them, which is not a sixth of
Kigali - it is the *whole* of Kigali with five out of six buildings missing, so
every street had gaps in it. This takes the lot.

**Real heights.** 22 footprints carry a `height` tag and 2 950 carry
`building:levels`; the other 25 744 carry neither, and giving all of them the
same 7 m produces a city with a dead flat skyline. Those fall back to a height
drawn from what the building *is* - a shop is not a warehouse is not a block of
flats - jittered by a hash of the way id so a terrace is not a single extrusion.

**Real roofs.** 2 314 footprints say what shape their roof is, and this builds
it: gabled, hipped, pyramidal, skillion. The rest are inferred - a small
rectangular building in Kigali has a pitched metal roof, and a flat grey lid on
all of them is the single thing that most gives an OSM city away from the air.
A roof is only pitched when the footprint is close enough to its own bounding
rectangle to carry one; everything else gets a flat roof with a parapet.

**Real materials.** `building:material` on 1 020, then an inference from height
and use: plastered masonry and brick low down, concrete frames in the middle,
curtain wall on the towers. Four wall textures and three roof textures, tinted
per building from a seeded palette, which is how 28 716 buildings come out of
seven materials.

**Solid.** Every building within `--collide` metres of the racing line is
emitted a second time as collision-only geometry, so leaving the road into a
wall stops the car. Buildings out of reach of the track are not given collision,
because collision you cannot touch is cost with no gameplay.

**Out of the road.** The circuit is a real bike route relaxed onto real streets,
and it does not miss every building OSM knows about. Anything whose footprint
reaches the road surface - or that the centreline runs straight through - is
dropped, because a building in the racing line is worse than a missing one.

Output:
  <name>_city.glb              chunked, textured, vertex-tinted, with
                               `-colonly` collision chunks near the track
  <name>_city_landmarks.json   the named buildings, in circuit coordinates
  <name>_city.json             what was built, for the tests to check

Usage:
  python3 tools/build_city.py --terrain assets/terrain/kigali_terrain.json \
      --out assets/terrain --name kigali
"""

import argparse
import hashlib
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import city_textures

EARTH_LAT = 110540.0
EARTH_LON = 111320.0

METRES_PER_LEVEL = 3.2
TILE_METRES = 12.8              # one texture tile: 4 bays by 4 floors
CHUNK_METRES = 500.0
EAVE = 0.35                     # roof overhang past the wall
PARAPET = 0.45                  # upstand around a flat roof

# Vertex colours ship as normalised unsigned bytes, a quarter of the size of
# floats over a million vertices. A byte cannot hold a value above 1.0, so if a
# palette ever needs to go brighter than white this is the headroom, factored
# out into the material's own baseColorFactor and multiplied back in by glTF.
#
# It is 1.0 because no palette here needs it any more. The first version of
# these tables was written to multiply the textures back up to full brightness
# and ran to 1.18, which - once the sRGB conversion below was also fixed - made
# every wall in Kigali brighter than white paint and the whole city blew out
# under its own sunlight. The tints are now the albedos real materials have.
TINT_SCALE = 1.0

# glTF vertex colours are *linear*, and the textures they multiply are sRGB.
# The palettes below are written the way a person reads a colour - as sRGB - so
# they are converted on the way out. Skipping this is not a subtle error: it
# raises every tint towards white (0.5 sRGB is 0.21 linear) and the whole city
# comes out bleached, which is exactly what the first build of it looked like.

def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


# ----------------------------------------------------------------- the circuit
#
# The road has to be known here, in Python, to keep buildings out of it. These
# two functions are ports of `TrackData.sample_loop` and `TrackData._catmull`,
# and the test suite asserts they agree with the GDScript to the millimetre -
# a centreline that drifts from the game's own would cull the wrong buildings.

def catmull(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return tuple(
        0.5 * ((2.0 * b)
               + (-a + c) * t
               + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
               + (-a + 3.0 * b - 3.0 * c + d) * t3)
        for a, b, c, d in zip(p0, p1, p2, p3))


def sample_loop(control, spacing):
    n = len(control)
    if n < 3:
        return list(control)
    dense = []
    per_segment = 24
    for i in range(n):
        p0 = control[(i - 1 + n) % n]
        p1 = control[i]
        p2 = control[(i + 1) % n]
        p3 = control[(i + 2) % n]
        for k in range(per_segment):
            dense.append(catmull(p0, p1, p2, p3, k / per_segment))

    segments, total = [], 0.0
    for i in range(len(dense)):
        a, b = dense[i], dense[(i + 1) % len(dense)]
        length = math.dist(a, b)
        segments.append(length)
        total += length

    count = max(16, int(round(total / max(0.01, spacing))))
    step = total / count
    out, index, walked, travelled, target, guard = [], 0, 0.0, 0.0, 0.0, 0
    while len(out) < count and guard < count * 8:
        guard += 1
        remaining = segments[index] - travelled
        if walked + remaining >= target:
            travelled += target - walked
            walked = target
            t = min(1.0, max(0.0, travelled / max(segments[index], 0.0001)))
            a, b = dense[index], dense[(index + 1) % len(dense)]
            out.append(tuple(x + (y - x) * t for x, y in zip(a, b)))
            target += step
        else:
            walked += remaining
            travelled = 0.0
            index = (index + 1) % len(dense)
    return out or dense


def read_centreline(gd_path, track_name, spacing=2.0):
    """Pull one circuit's control points straight out of `track_data.gd`.

    Parsed from the GDScript rather than duplicated into a data file on purpose:
    two copies of a circuit is one circuit and one lie waiting to happen, and the
    points are edited in the .gd.
    """
    import re
    text = open(gd_path, encoding="utf-8").read()
    start = text.find('"name": "%s"' % track_name)
    if start < 0:
        raise SystemExit("build_city: %s is not in %s" % (track_name, gd_path))
    block = text[start:]
    end = block.find("\n}")
    points_at = block.find('"points"')
    body = block[points_at:end if end > points_at else len(block)]
    out = []
    for m in re.finditer(r"Vector3\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)", body):
        out.append(tuple(float(g) for g in m.groups()))
    if len(out) < 3:
        raise SystemExit("build_city: found %d control points for %s" % (len(out), track_name))
    return out, sample_loop(out, spacing)


class NearTrack:
    """Distance from a point to the racing line, without 186 000 x 7 181 work.

    The centreline samples go into a grid of `cell`-metre buckets; a query only
    looks at the buckets that a circle of the search radius can touch. That turns
    the cull from half an hour into under a second.
    """

    def __init__(self, samples, cell=48.0):
        self.cell = cell
        self.samples = samples
        self.grid = {}
        for i, p in enumerate(samples):
            self.grid.setdefault((int(math.floor(p[0] / cell)),
                                  int(math.floor(p[2] / cell))), []).append(i)

    def distance(self, x, z, limit):
        """Planar distance to the nearest centreline sample, or `limit` if the
        nearest one is further away than that."""
        best = limit
        reach = int(math.floor(limit / self.cell)) + 1
        cx, cz = int(math.floor(x / self.cell)), int(math.floor(z / self.cell))
        for gx in range(cx - reach, cx + reach + 1):
            for gz in range(cz - reach, cz + reach + 1):
                for i in self.grid.get((gx, gz), ()):
                    p = self.samples[i]
                    d = math.hypot(p[0] - x, p[2] - z)
                    if d < best:
                        best = d
        return best

    def samples_inside(self, poly, pad=0.0):
        """True if any centreline sample falls inside `poly` - the case where a
        building is big enough that the road passes through it without ever
        coming near one of its corners."""
        xs = [p[0] for p in poly]
        zs = [p[1] for p in poly]
        x0, x1 = min(xs) - pad, max(xs) + pad
        z0, z1 = min(zs) - pad, max(zs) + pad
        reach = 1
        for gx in range(int(math.floor(x0 / self.cell)) - reach,
                        int(math.floor(x1 / self.cell)) + reach + 1):
            for gz in range(int(math.floor(z0 / self.cell)) - reach,
                            int(math.floor(z1 / self.cell)) + reach + 1):
                for i in self.grid.get((gx, gz), ()):
                    p = self.samples[i]
                    if x0 <= p[0] <= x1 and z0 <= p[2] <= z1 and point_in_poly(p[0], p[2], poly):
                        return True
        return False


def point_in_poly(x, z, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        ax, az = poly[i]
        bx, bz = poly[(i + 1) % n]
        if (az > z) != (bz > z):
            t = (z - az) / (bz - az)
            if x < ax + t * (bx - ax):
                inside = not inside
    return inside


# ------------------------------------------------------------------- polygons

def signed_area(poly):
    a = 0.0
    n = len(poly)
    for i in range(n):
        x0, z0 = poly[i]
        x1, z1 = poly[(i + 1) % n]
        a += x0 * z1 - x1 * z0
    return a * 0.5


def clean_ring(ring):
    """Drop the repeated closing vertex and any point that sits on top of its
    neighbour, then orient the ring so its signed area is positive.

    Positive area fixes the meaning of "outside": the outward normal of the edge
    (dx, dz) is then (dz, -dx), which is what every wall in this file is wound
    from. Doing it once here is why nothing downstream has to think about it.
    """
    out = []
    for p in ring:
        if not out or math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) > 0.05:
            out.append((float(p[0]), float(p[1])))
    while len(out) > 1 and math.hypot(out[0][0] - out[-1][0], out[0][1] - out[-1][1]) <= 0.05:
        out.pop()
    if len(out) < 3:
        return None
    if signed_area(out) < 0.0:
        out.reverse()
    return out


def is_simple(poly):
    """True if no two non-adjacent edges of the ring cross.

    Winding is what tells this file which side of a wall is outside, and for a
    polygon that crosses itself there is no answer: the signed area can come out
    either sign and the walls are then built inside out - visible as a building
    you can see straight through, and solid from the wrong side. OSM has a
    handful of these, so they are found here and dropped rather than shipped.
    """
    n = len(poly)
    if n < 4:
        return True
    for i in range(n):
        a0, a1 = poly[i], poly[(i + 1) % n]
        for j in range(i + 1, n):
            if j == i or (j + 1) % n == i or j == (i + 1) % n:
                continue
            if _segments_cross(a0, a1, poly[j], poly[(j + 1) % n]):
                return False
    return True


def _orient(a, b, c):
    v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if v > 1e-9:
        return 1
    return -1 if v < -1e-9 else 0


def _segments_cross(a, b, c, d):
    d1, d2 = _orient(c, d, a), _orient(c, d, b)
    d3, d4 = _orient(a, b, c), _orient(a, b, d)
    return d1 != d2 and d3 != d4 and d1 != 0 and d2 != 0 and d3 != 0 and d4 != 0


def ear_clip(poly):
    """Triangulate a simple polygon. Returns index triples into `poly`.

    Plain ear clipping: O(n^2) on a footprint that averages five vertices, which
    is free, and unlike a convex decomposition it is exactly right on the L- and
    U-shaped plots that a real city is full of.
    """
    n = len(poly)
    if n < 3:
        return []
    if n == 3:
        return [(0, 1, 2)]
    idx = list(range(n))
    tris = []
    guard = 0
    while len(idx) > 3 and guard < n * n + 32:
        guard += 1
        clipped = False
        for k in range(len(idx)):
            i0 = idx[(k - 1) % len(idx)]
            i1 = idx[k]
            i2 = idx[(k + 1) % len(idx)]
            ax, az = poly[i0]
            bx, bz = poly[i1]
            cx, cz = poly[i2]
            cross = (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
            if cross <= 1e-9:
                continue                      # reflex, or degenerate
            blocked = False
            for j in idx:
                if j in (i0, i1, i2):
                    continue
                px, pz = poly[j]
                if _in_triangle(px, pz, ax, az, bx, bz, cx, cz):
                    blocked = True
                    break
            if blocked:
                continue
            tris.append((i0, i1, i2))
            idx.pop(k)
            clipped = True
            break
        if not clipped:
            break                             # self-intersecting: take what we have
    if len(idx) == 3:
        tris.append((idx[0], idx[1], idx[2]))
    return tris


def _in_triangle(px, pz, ax, az, bx, bz, cx, cz):
    d1 = (px - bx) * (az - bz) - (ax - bx) * (pz - bz)
    d2 = (px - cx) * (bz - cz) - (bx - cx) * (pz - cz)
    d3 = (px - ax) * (cz - az) - (cx - ax) * (pz - az)
    neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (neg and pos)


def min_area_rect(poly):
    """Smallest enclosing rectangle, by rotating calipers over the edges.

    A roof needs an axis to run its ridge along, and the footprint's own longest
    edge is the wrong answer on anything but a perfect rectangle. Returns
    (centre, axis_u, axis_v, half_u, half_v, area).
    """
    best = None
    n = len(poly)
    for i in range(n):
        ax, az = poly[i]
        bx, bz = poly[(i + 1) % n]
        ex, ez = bx - ax, bz - az
        length = math.hypot(ex, ez)
        if length < 1e-6:
            continue
        ux, uz = ex / length, ez / length
        vx, vz = -uz, ux
        us = [p[0] * ux + p[1] * uz for p in poly]
        vs = [p[0] * vx + p[1] * vz for p in poly]
        area = (max(us) - min(us)) * (max(vs) - min(vs))
        if best is None or area < best[0]:
            cu = (max(us) + min(us)) * 0.5
            cv = (max(vs) + min(vs)) * 0.5
            best = (area,
                    (cu * ux + cv * vx, cu * uz + cv * vz),
                    (ux, uz), (vx, vz),
                    (max(us) - min(us)) * 0.5, (max(vs) - min(vs)) * 0.5)
    if best is None:
        return None
    area, centre, u, v, hu, hv = best
    if hu < hv:                                # u is always the long axis
        u, v, hu, hv = v, (-u[0], -u[1]), hv, hu
    return centre, u, v, hu, hv, area


# ------------------------------------------------------- what a building is

WALL_STYLES = ["plaster", "brick", "concrete", "glass"]
ROOF_STYLES = ["metal", "tile", "flat"]

# Tints multiply the grey textures. Values above 1 lift the result back up,
# because the textures are drawn at about 0.8 so a tint can go either way.
WALL_TINTS = {
    # Weighted the way a Kigali street actually is: mostly cream, white and
    # ochre render, with the occasional painted one. An even spread across the
    # whole hue circle was the first version and it came out looking like a
    # seaside town - too many pastel pinks and blues for a city of plastered
    # concrete block.
    "plaster": [(0.80, 0.79, 0.76), (0.78, 0.77, 0.71), (0.81, 0.74, 0.62),
                (0.77, 0.71, 0.60), (0.83, 0.70, 0.52), (0.74, 0.69, 0.59),
                (0.80, 0.78, 0.73), (0.76, 0.74, 0.69), (0.71, 0.77, 0.70),
                (0.81, 0.70, 0.67), (0.67, 0.74, 0.80), (0.73, 0.67, 0.57)],
    "brick":   [(0.70, 0.50, 0.39), (0.62, 0.45, 0.35), (0.66, 0.53, 0.43),
                (0.57, 0.43, 0.36), (0.63, 0.49, 0.41)],
    "concrete": [(0.71, 0.71, 0.69), (0.67, 0.66, 0.64), (0.76, 0.73, 0.69),
                 (0.64, 0.65, 0.66)],
    "glass":   [(0.60, 0.67, 0.74), (0.64, 0.71, 0.71), (0.56, 0.63, 0.71),
                (0.67, 0.69, 0.66)],
}
# Roofs are the largest surface a city shows from a hillside, and the first
# version of this table was far too bright: a silver corrugated sheet at full
# value turns every roof in Kigali white and the whole city reads as snow. Real
# sheet metal is weathered, half of it to rust, so the metal entries sit low and
# lean warm.
ROOF_TINTS = {
    "metal": [(0.62, 0.64, 0.66), (0.72, 0.52, 0.40), (0.52, 0.55, 0.58),
              (0.68, 0.68, 0.64), (0.56, 0.44, 0.36), (0.78, 0.76, 0.70),
              (0.46, 0.48, 0.52)],
    "tile":  [(0.88, 0.50, 0.36), (0.74, 0.42, 0.32), (0.82, 0.46, 0.34),
              (0.64, 0.38, 0.30)],
    "flat":  [(0.72, 0.72, 0.70), (0.62, 0.62, 0.60), (0.78, 0.77, 0.73),
              (0.56, 0.57, 0.58)],
}

# A building with no height and no levels still has a use, and a use has a size.
# Levels, not metres, so the jitter below lands on whole floors.
TYPE_LEVELS = {
    "apartments": 4, "residential": 1, "house": 1, "detached": 1, "hut": 1,
    "shed": 1, "garage": 1, "garages": 1, "roof": 1, "toilets": 1,
    "commercial": 2, "retail": 2, "office": 4, "hotel": 6, "school": 2,
    "university": 3, "college": 3, "hospital": 4, "public": 3, "civic": 3,
    "government": 4, "church": 2, "mosque": 2, "industrial": 1,
    "warehouse": 1, "supermarket": 1, "construction": 2, "service": 1,
    "bank": 4, "clinic": 2, "restaurant": 1, "mall": 3, "yes": 1,
}
# Buildings that are one tall storey rather than n normal ones.
TALL_SINGLE = {"industrial", "warehouse", "supermarket", "church", "mosque",
               "stadium", "sports_centre", "arena", "hangar", "grandstand"}

# `building=yes` is on 25 920 of the 28 716 footprints and says nothing at all.
# When that is all there is, the building's *use* is usually tagged somewhere
# else, and a hotel tagged `tourism=hotel` is still a hotel. Without this, the
# Radisson comes out a single storey high.
USE_KEYS = ("tourism", "amenity", "office", "shop", "leisure", "healthcare",
            "government", "craft", "industrial")
USE_TO_KIND = {
    "hotel": "hotel", "motel": "hotel", "guest_house": "hotel", "hostel": "hotel",
    "hospital": "hospital", "clinic": "clinic", "doctors": "clinic",
    "school": "school", "college": "college", "university": "university",
    "kindergarten": "school", "bank": "bank", "restaurant": "restaurant",
    "cafe": "restaurant", "bar": "restaurant", "fast_food": "restaurant",
    "place_of_worship": "church", "marketplace": "retail", "mall": "mall",
    "supermarket": "supermarket", "stadium": "stadium", "arena": "stadium",
    "sports_centre": "sports_centre", "pitch": "sports_centre",
    "townhall": "government", "embassy": "government", "police": "public",
    "courthouse": "government", "library": "public", "museum": "public",
    "cinema": "public", "theatre": "public", "conference_centre": "public",
    "fuel": "service", "parking": "service", "car_wash": "service",
}

# Above about 400 m2 a footprint stops being a house, and how far above tells
# you roughly how many floors are over it: nobody puts 6 000 m2 of ground floor
# under a single storey in a city centre. These are (area, extra levels) steps,
# applied to buildings whose only tag is that they exist.
AREA_LEVELS = [(400.0, 1), (900.0, 2), (1800.0, 3), (3500.0, 4), (7000.0, 5)]

MATERIAL_TO_STYLE = {
    "brick": "brick", "clay_brick": "brick", "burnt_brick": "brick",
    "concrete": "concrete", "cement": "concrete", "reinforced_concrete": "concrete",
    "concrete_block": "concrete", "cement_block": "concrete", "stone": "concrete",
    "glass": "glass", "mirror": "glass",
    "plaster": "plaster", "render": "plaster", "cement_plaster": "plaster",
    "mud": "plaster", "clay": "plaster", "adobe": "plaster", "wood": "plaster",
    "timber_framing": "plaster", "metal": "concrete", "tin": "concrete",
}

ROOF_SHAPE_MAP = {
    "flat": "flat", "gabled": "gabled", "hipped": "hipped",
    "pyramidal": "pyramidal", "skillion": "skillion", "lean_to": "skillion",
    "half-hipped": "hipped", "gambrel": "gabled", "mansard": "hipped",
    "round": "flat", "dome": "flat", "onion": "pyramidal", "conical": "pyramidal",
    "sawtooth": "flat", "double_saltbox": "gabled", "saltbox": "gabled",
    "cross_gabled": "gabled", "side_hipped": "hipped",
}

ROOF_MATERIAL_MAP = {
    "metal": "metal", "metal_sheet": "metal", "corrugated_iron": "metal",
    "roof_tiles": "tile", "tiles": "tile", "tile": "tile", "clay_tiles": "tile",
    "concrete": "flat", "concrete_slab": "flat", "tar_paper": "flat",
    "gravel": "flat", "asphalt": "flat", "thatch": "tile", "slate": "tile",
}

NOTABLE = ("stadium", "hotel", "hospital", "university", "college", "school",
           "mall", "convention", "arena", "museum", "church", "cathedral",
           "mosque", "tower", "centre", "center", "bank", "ministry")


def seeded(way_id, salt):
    """A stable pseudo-random float in [0, 1) for one building.

    Hashed rather than drawn from a stream so the city is identical whatever
    order Overpass returns, and so re-running after an edit moves only the
    buildings that changed.
    """
    h = hashlib.blake2b(("%d/%s" % (way_id, salt)).encode(), digest_size=8).digest()
    return struct.unpack("<Q", h)[0] / float(1 << 64)


def building_kind(tags):
    """What the building is, looking past `building=yes` to its use tags."""
    kind = str(tags.get("building", "yes")).lower()
    if kind in ("yes", "", "construction", "roof"):
        for key in USE_KEYS:
            mapped = USE_TO_KIND.get(str(tags.get(key, "")).lower())
            if mapped:
                return mapped
        if tags.get("building:use"):
            return str(tags["building:use"]).lower()
    return kind


def classify(way_id, tags, area):
    """Decide a building's height, wall style, roof shape and roof material."""
    kind = building_kind(tags)

    explicit_height = None
    if "height" in tags:
        try:
            explicit_height = float(str(tags["height"]).split()[0].replace("m", "").strip())
        except ValueError:
            explicit_height = None
    levels = None
    if "building:levels" in tags:
        try:
            levels = int(float(str(tags["building:levels"]).split(";")[0]))
        except ValueError:
            levels = None

    if explicit_height is not None:
        height = explicit_height
    elif levels is not None and levels > 0:
        height = levels * METRES_PER_LEVEL
    else:
        base = TYPE_LEVELS.get(kind, 1)
        r = seeded(way_id, "levels")
        if kind in TALL_SINGLE:
            # One tall volume rather than n floors, and the bigger the shed the
            # taller it is: an 11 000 m2 arena is not a 6 m one.
            height = 6.0 + r * 3.0 + min(16.0, math.sqrt(area) * 0.22)
        else:
            # Footprint area carries most of the signal for an untagged
            # building, and a hash-driven extra floor breaks up the rest: a
            # terrace of identical heights is the tell that a city was extruded
            # rather than built.
            for threshold, step in AREA_LEVELS:
                if area >= threshold:
                    base = max(base, 1 + step)
            extra = 1 if r > (0.82 if base == 1 else 0.62) else 0
            height = (base + extra) * METRES_PER_LEVEL
            height += (seeded(way_id, "jitter") - 0.5) * 0.7
    height = max(2.8, min(120.0, height))

    material = str(tags.get("building:material", "")).lower()
    style = MATERIAL_TO_STYLE.get(material)
    if style is None:
        if height >= 22.0:
            style = "glass"
        elif height >= 11.0:
            style = "concrete"
        elif kind in ("office", "commercial", "retail", "hotel", "public",
                      "government", "civic", "supermarket") and height >= 7.0:
            style = "concrete"
        else:
            style = "brick" if seeded(way_id, "wall") > 0.72 else "plaster"
    # The plaster texture has a shopfront on its ground floor and repeats every
    # four floors, so it is only honest on a building of four floors or fewer.
    if style == "plaster" and height > 4.2 * METRES_PER_LEVEL:
        style = "concrete"

    shape = ROOF_SHAPE_MAP.get(str(tags.get("roof:shape", "")).lower())
    if shape is None:
        # Kigali's ordinary building is a small rectangle under a pitched sheet
        # of metal. Flat lids on all of it is what makes an OSM city look fake.
        if height <= 12.0:
            r = seeded(way_id, "roof")
            shape = "hipped" if r > 0.55 else ("gabled" if r > 0.12 else "flat")
        else:
            shape = "flat"

    roof_material = ROOF_MATERIAL_MAP.get(str(tags.get("roof:material", "")).lower())
    if roof_material is None:
        if shape == "flat":
            roof_material = "flat"
        else:
            roof_material = "tile" if seeded(way_id, "roofmat") > 0.78 else "metal"
    elif shape == "flat" and roof_material != "flat":
        roof_material = "flat"

    roof_levels = 0
    if "roof:levels" in tags:
        try:
            roof_levels = int(float(str(tags["roof:levels"]).split(";")[0]))
        except ValueError:
            roof_levels = 0

    return {
        "kind": kind, "height": height, "wall": style, "roof_shape": shape,
        "roof_material": roof_material, "roof_levels": roof_levels,
        "tagged_height": explicit_height is not None or levels is not None,
    }


def is_landmark(tags, height):
    name = tags.get("name") or tags.get("name:en") or tags.get("name:fr")
    if not name:
        return None
    lowered = name.lower()
    if height >= 20.0 or any(w in lowered for w in NOTABLE):
        return name
    for key in ("amenity", "tourism", "office", "shop", "leisure", "government"):
        if key in tags:
            return name
    return None


# ------------------------------------------------------------------- geometry

class Surface:
    """One material's vertex soup inside one chunk."""

    __slots__ = ("pos", "nrm", "uv", "col", "idx")

    def __init__(self):
        self.pos, self.nrm, self.uv, self.col, self.idx = [], [], [], [], []

    def add(self, verts, normal, uvs, colour):
        """Append a fan over `verts` (3 or 4 of them), already wound outward."""
        base = len(self.pos)
        for v, t in zip(verts, uvs):
            self.pos.append(v)
            self.nrm.append(normal)
            self.uv.append(t)
            self.col.append(colour)
        for k in range(1, len(verts) - 1):
            self.idx.extend((base, base + k, base + k + 1))

    def empty(self):
        return not self.idx


def normalise(v):
    length = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if length < 1e-9:
        return (0.0, 1.0, 0.0)
    return (v[0] / length, v[1] / length, v[2] / length)


def face_normal(a, b, c):
    u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    v = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
    return normalise((u[1] * v[2] - u[2] * v[1],
                      u[2] * v[0] - u[0] * v[2],
                      u[0] * v[1] - u[1] * v[0]))


def add_wall_ring(surface, ring, y0, y1, colour, u_offset=0.0, v_at_base=1.0):
    """The vertical faces of a prism over `ring`, wound so they face outward.

    `ring` has positive signed area, so the outward normal of an edge (dx, dz)
    is (dz, -dx). The winding below follows from that and is the reason nothing
    in this city needs a double-sided material: a wall you can see through from
    outside is a wall wound the other way.

    V runs *downward* from `v_at_base` so the texture's ground floor lands on
    the ground rather than four floors up.
    """
    n = len(ring)
    height = y1 - y0
    if height <= 0.01:
        return
    run = u_offset
    for i in range(n):
        x0, z0 = ring[i]
        x1, z1 = ring[(i + 1) % n]
        dx, dz = x1 - x0, z1 - z0
        length = math.hypot(dx, dz)
        if length < 0.02:
            continue
        a = (x0, y0, z0)
        b = (x1, y0, z1)
        c = (x1, y1, z1)
        d = (x0, y1, z0)
        normal = normalise((dz, 0.0, -dx))
        u0 = run / TILE_METRES
        u1 = (run + length) / TILE_METRES
        v0 = v_at_base
        v1 = v_at_base - height / TILE_METRES
        # (a, d, c, b) is the outward winding for a positive-area ring.
        surface.add([a, d, c, b], normal,
                    [(u0, v0), (u0, v1), (u1, v1), (u1, v0)], colour)
        run += length


def add_cap(surface, ring, tris, y, colour, flip=False, uv_scale=1.0 / TILE_METRES):
    """A horizontal lid over an already-triangulated ring.

    A positive-area ring walked in order is clockwise seen from above, so the
    triangles come out facing down and have to be reversed to point at the sky.
    """
    normal = (0.0, -1.0, 0.0) if flip else (0.0, 1.0, 0.0)
    for i0, i1, i2 in tris:
        p0 = (ring[i0][0], y, ring[i0][1])
        p1 = (ring[i1][0], y, ring[i1][1])
        p2 = (ring[i2][0], y, ring[i2][1])
        order = (p0, p1, p2) if flip else (p0, p2, p1)
        uvs = [(p[0] * uv_scale, p[2] * uv_scale) for p in order]
        surface.add(list(order), normal, uvs, colour)


def add_quad(surface, a, b, c, d, colour, uvs):
    """A quad wound a, b, c, d - the normal is taken from the winding."""
    surface.add([a, b, c, d], face_normal(a, b, c), uvs, colour)


def add_tri(surface, a, b, c, colour, uvs):
    surface.add([a, b, c], face_normal(a, b, c), uvs, colour)


def offset_rect(centre, u, v, hu, hv, grow):
    """The four corners of a rectangle, grown by `grow` on every side."""
    cu, cv = centre
    hu, hv = hu + grow, hv + grow
    return [
        (cu - u[0] * hu - v[0] * hv, cv - u[1] * hu - v[1] * hv),
        (cu + u[0] * hu - v[0] * hv, cv + u[1] * hu - v[1] * hv),
        (cu + u[0] * hu + v[0] * hv, cv + u[1] * hu + v[1] * hv),
        (cu - u[0] * hu + v[0] * hv, cv - u[1] * hu + v[1] * hv),
    ]


def roof_rise(spec, rect, total_height):
    """How far a pitched roof stands above its eaves.

    `roof:levels` when OSM says so, otherwise a pitch off the building's short
    half-width - a roof's slope is set by how far it has to span, which is why
    this comes from the footprint rather than from a constant. Capped at 45% of
    the building so a bungalow does not turn into a tent.
    """
    if spec["roof_levels"]:
        rise = spec["roof_levels"] * METRES_PER_LEVEL
    elif rect is None:
        rise = 1.4
    else:
        rise = min(3.0, max(0.8, rect[4] * 0.75))
    return min(rise, total_height * 0.45)


def build_roof(walls, roofs, ring, tris, top, spec, rect, wall_colour, roof_colour):
    """Put a roof on the walls, and return the height it reaches.

    A pitched roof is built on the footprint's minimum-area rectangle, not on
    the footprint, which is why `classify_roof_fit` refuses to pitch anything
    whose footprint is not nearly that rectangle already: a hip built over an
    L-shaped plot floats over one of its own wings.
    """
    shape = spec["roof_shape"]
    if shape == "flat" or rect is None:
        add_cap(roofs, ring, tris, top, roof_colour)
        if spec["height"] >= 5.5:
            # A parapet: the low upstand that stops a flat roof reading as a lid
            # dropped on a box. It is two rings of quads and it is worth it.
            add_wall_ring(walls, ring, top, top + PARAPET, wall_colour,
                          v_at_base=1.0 - (top - 0.0) / TILE_METRES)
            add_cap(roofs, ring, tris, top + PARAPET, roof_colour)
            return top + PARAPET
        return top

    centre, u, v, hu, hv, _ = rect
    rise = roof_rise(spec, rect, spec["height"])
    eaves = top
    corners = offset_rect(centre, u, v, hu, hv, EAVE)
    c0, c1, c2, c3 = [(p[0], eaves, p[1]) for p in corners]
    # c0..c3 run -u-v, +u-v, +u+v, -u+v. The ridge runs along u.
    span = (hv + EAVE) * 2.0
    length = (hu + EAVE) * 2.0
    slope_len = math.hypot(span * 0.5, rise)
    apex = eaves + rise

    def mid(p, q, t=0.5):
        return tuple(a + (b - a) * t for a, b in zip(p, q))

    if shape == "skillion":
        h0 = (c0[0], apex, c0[2])
        h1 = (c1[0], apex, c1[2])
        add_quad(roofs, h0, h1, c2, c3, roof_colour,
                 [(0, 0), (length / TILE_METRES, 0),
                  (length / TILE_METRES, slope_len / TILE_METRES),
                  (0, slope_len / TILE_METRES)])
        add_tri(walls, c0, h0, c3, wall_colour, [(0, 1), (0, 0), (span / TILE_METRES, 1)])
        add_tri(walls, c1, c2, h1, wall_colour, [(0, 1), (span / TILE_METRES, 1), (0, 0)])
        return apex

    if shape == "pyramidal":
        peak = (centre[0], apex, centre[1])
        quad = [c0, c1, c2, c3]
        for i in range(4):
            a, b = quad[i], quad[(i + 1) % 4]
            edge = math.dist(a, b)
            add_tri(roofs, a, b, peak, roof_colour,
                    [(0, 0), (edge / TILE_METRES, 0),
                     (edge / (2 * TILE_METRES), slope_len / TILE_METRES)])
        return apex

    # Gabled and hipped share a ridge along u; the hip pulls its ends in.
    inset = (hv + EAVE) if shape == "hipped" else 0.0
    inset = min(inset, (hu + EAVE) * 0.9)
    r0 = (centre[0] - u[0] * (hu + EAVE - inset), apex, centre[1] - u[1] * (hu + EAVE - inset))
    r1 = (centre[0] + u[0] * (hu + EAVE - inset), apex, centre[1] + u[1] * (hu + EAVE - inset))
    ul = length / TILE_METRES
    vs = slope_len / TILE_METRES
    # The two long slopes.
    add_quad(roofs, c0, c1, r1, r0, roof_colour,
             [(0, 0), (ul, 0), (ul - inset / TILE_METRES, vs), (inset / TILE_METRES, vs)])
    add_quad(roofs, c2, c3, r0, r1, roof_colour,
             [(0, 0), (ul, 0), (ul - inset / TILE_METRES, vs), (inset / TILE_METRES, vs)])
    if shape == "hipped":
        add_tri(roofs, c3, c0, r0, roof_colour,
                [(0, 0), (span / TILE_METRES, 0), (span / (2 * TILE_METRES), vs)])
        add_tri(roofs, c1, c2, r1, roof_colour,
                [(0, 0), (span / TILE_METRES, 0), (span / (2 * TILE_METRES), vs)])
    else:
        # Gable ends are wall, not roof - they are the wall carried up to the ridge.
        add_tri(walls, c0, r0, c3, wall_colour,
                [(0, 1), (span / (2 * TILE_METRES), 1 - rise / TILE_METRES),
                 (span / TILE_METRES, 1)])
        add_tri(walls, c2, r1, c1, wall_colour,
                [(0, 1), (span / (2 * TILE_METRES), 1 - rise / TILE_METRES),
                 (span / TILE_METRES, 1)])
    return apex


# -------------------------------------------------------------- glTF assembly

COMPONENT_FLOAT = 5126
COMPONENT_UINT = 5125
COMPONENT_USHORT = 5123
TARGET_ARRAY = 34962
TARGET_ELEMENT = 34963


class Gltf:
    """A minimal glTF 2.0 writer: meshes, PBR materials and embedded PNGs.

    Written by hand rather than through Blender so that building the city is one
    `python3 tools/build_city.py` with no 3D package in the loop, and so the
    chunk names - which are what carry the collision suffixes and the LOD
    grouping into Godot - are exactly what this file says they are.
    """

    def __init__(self):
        self.blob = bytearray()
        self.buffer_views = []
        self.accessors = []
        self.meshes = []
        self.nodes = []
        self.materials = []
        self.images = []
        self.textures = []
        self.samplers = [{"wrapS": 10497, "wrapT": 10497,
                          "magFilter": 9729, "minFilter": 9987}]

    def _align(self, boundary=4):
        while len(self.blob) % boundary:
            self.blob.append(0)

    def _view(self, data, target=None):
        self._align()
        offset = len(self.blob)
        self.blob.extend(data)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        self.buffer_views.append(view)
        return len(self.buffer_views) - 1

    def add_vec(self, values, kind):
        """A float accessor. `kind` is VEC2, VEC3 or VEC4."""
        size = {"VEC2": 2, "VEC3": 3, "VEC4": 4}[kind]
        packed = struct.pack("<%df" % (len(values) * size),
                             *[c for v in values for c in v])
        view = self._view(packed, TARGET_ARRAY)
        lo = [min(v[i] for v in values) for i in range(size)]
        hi = [max(v[i] for v in values) for i in range(size)]
        self.accessors.append({"bufferView": view, "componentType": COMPONENT_FLOAT,
                               "count": len(values), "type": kind,
                               "min": lo, "max": hi})
        return len(self.accessors) - 1

    def add_colours(self, values):
        """COLOR_0 as normalised unsigned bytes. See TINT_SCALE."""
        flat = []
        for c in values:
            for k in range(4):
                v = srgb_to_linear(c[k]) / TINT_SCALE if k < 3 else c[k]
                flat.append(max(0, min(255, int(round(v * 255.0)))))
        view = self._view(struct.pack("<%dB" % len(flat), *flat), TARGET_ARRAY)
        self.accessors.append({"bufferView": view, "componentType": 5121,
                               "normalized": True, "count": len(values),
                               "type": "VEC4"})
        return len(self.accessors) - 1

    def add_indices(self, values):
        # Sixteen-bit indices whenever the primitive is small enough to use
        # them, which every chunk in this project is: chunks exist so that the
        # far half of the model costs nothing, and a chunk that needed more
        # than 65 536 vertices would be too big to cull usefully anyway. It
        # halves the index buffer, on disk and in memory.
        top = max(values)
        if top < 65536:
            packed = struct.pack("<%dH" % len(values), *values)
            component = COMPONENT_USHORT
        else:
            packed = struct.pack("<%dI" % len(values), *values)
            component = COMPONENT_UINT
        view = self._view(packed, TARGET_ELEMENT)
        self.accessors.append({"bufferView": view, "componentType": component,
                               "count": len(values), "type": "SCALAR",
                               "min": [min(values)], "max": [top]})
        return len(self.accessors) - 1

    def add_texture(self, path, name):
        # Godot extracts embedded images to "<glb stem>_<image name>.png", so
        # the name here is the bare style: "wall_brick" becomes
        # kigali_city_wall_brick.png rather than kigali_city_kigali_city_....
        view = self._view(open(path, "rb").read())
        self.images.append({"bufferView": view, "mimeType": "image/png",
                            "name": name})
        self.textures.append({"sampler": 0, "source": len(self.images) - 1})
        return len(self.textures) - 1

    def add_material(self, name, texture, roughness=0.9, metallic=0.0,
                     normal=None, normal_scale=1.0):
        material = {
            "name": name,
            "doubleSided": False,
            "pbrMetallicRoughness": {
                "baseColorTexture": {"index": texture},
                "baseColorFactor": [TINT_SCALE, TINT_SCALE, TINT_SCALE, 1.0],
                "metallicFactor": metallic,
                "roughnessFactor": roughness,
            },
        }
        if normal is not None:
            material["normalTexture"] = {"index": normal, "scale": normal_scale}
        self.materials.append(material)
        return len(self.materials) - 1

    def add_mesh(self, name, primitives):
        self.meshes.append({"name": name, "primitives": primitives})
        return len(self.meshes) - 1

    def add_node(self, name, mesh):
        self.nodes.append({"name": name, "mesh": mesh})
        return len(self.nodes) - 1

    def write(self, path, generator):
        doc = {
            "asset": {"version": "2.0", "generator": generator},
            "scene": 0,
            "scenes": [{"nodes": list(range(len(self.nodes)))}],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "materials": self.materials,
            "textures": self.textures,
            "images": self.images,
            "samplers": self.samplers,
            "accessors": self.accessors,
            "bufferViews": self.buffer_views,
            "buffers": [{"byteLength": len(self.blob)}],
        }
        js = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        js += b" " * ((4 - len(js) % 4) % 4)
        bin_blob = bytes(self.blob)
        bin_blob += b"\0" * ((4 - len(bin_blob) % 4) % 4)
        total = 12 + 8 + len(js) + 8 + len(bin_blob)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A))
            f.write(js)
            f.write(struct.pack("<II", len(bin_blob), 0x004E4942))
            f.write(bin_blob)
        return total


# ------------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--terrain", default="assets/terrain/kigali_terrain.json")
    ap.add_argument("--out", default="assets/terrain")
    ap.add_argument("--name", default="kigali")
    ap.add_argument("--track-data", default="scripts/track/track_data.gd")
    ap.add_argument("--track-name", default="KIGALI")
    ap.add_argument("--half-width", type=float, default=5.0,
                    help="road half width, from the circuit definition")
    ap.add_argument("--clear", type=float, default=11.0,
                    help="metres from the centreline a building may not enter")
    ap.add_argument("--collide", type=float, default=90.0,
                    help="metres from the centreline within which buildings are solid")
    ap.add_argument("--max", type=int, default=0, help="0 means all of them")
    ap.add_argument("--texture-dir", default="build/city_textures",
                    help="where the generated textures are written before being "
                         "embedded in the glb - deliberately outside the Godot "
                         "project, because Godot extracts its own copies out of "
                         "the glb on import and a second set in res:// is just "
                         "two more textures to import and keep in step")
    ap.add_argument("--cache", default=os.path.join(
        os.path.expanduser("~"), ".cache", "astra_racer_buildings.json"))
    args = ap.parse_args()

    if not os.path.exists(args.cache):
        print("build_city: no Overpass cache at %s - run tools/fetch_buildings.py first"
              % args.cache, file=sys.stderr)
        return 1

    from PIL import Image

    meta = json.load(open(args.terrain, encoding="utf-8"))
    lat0, lon0 = meta["centre"]["lat"], meta["centre"]["lon"]
    k = math.cos(math.radians(lat0))
    lo, hi = meta["elevation_min_m"], meta["elevation_max_m"]
    grid = meta["grid"]
    half = (meta["metres_per_pixel"] * (grid - 1)) / 2.0
    heights = list(Image.open(os.path.join(args.out, meta["heightmap"])).getdata())

    def ground(x, z):
        i = int(round((x + half) / (2 * half) * (grid - 1)))
        j = int(round((z + half) / (2 * half) * (grid - 1)))
        if not (0 <= i < grid and 0 <= j < grid):
            return None
        return heights[j * grid + i] / 65535.0 * (hi - lo)

    # The city is modelled in the terrain's frame and the circuit sits at an
    # offset inside it. The cull has to happen in one frame or the other, so the
    # centreline is brought into the terrain's.
    offset = terrain_offset(args.track_data, args.track_name)
    control, centre_track = read_centreline(args.track_data, args.track_name)
    centre_local = [(p[0] - offset[0], p[1] - offset[1], p[2] - offset[2])
                    for p in centre_track]
    near = NearTrack(centre_local)
    print("# circuit: %d control points -> %d samples, %.0f m lap"
          % (len(control), len(centre_local),
             sum(math.dist(centre_local[i], centre_local[(i + 1) % len(centre_local)])
                 for i in range(len(centre_local)))), file=sys.stderr)

    data = json.load(open(args.cache, encoding="utf-8"))
    ways = [e for e in data.get("elements", [])
            if e.get("type") == "way" and e.get("geometry")]
    print("# %d footprints in the cache" % len(ways), file=sys.stderr)

    textures = city_textures.build(args.texture_dir, prefix=args.name + "_city")

    gltf = Gltf()
    material_index = {}
    for style in WALL_STYLES:
        tex = gltf.add_texture(textures["wall_" + style], "wall_" + style)
        rough = 0.35 if style == "glass" else 0.88
        metal = 0.25 if style == "glass" else 0.0
        material_index["wall_" + style] = gltf.add_material(
            "Wall_" + style.capitalize(), tex, rough, metal)
    for style in ROOF_STYLES:
        tex = gltf.add_texture(textures["roof_" + style], "roof_" + style)
        rough = 0.55 if style == "metal" else 0.9
        metal = 0.35 if style == "metal" else 0.0
        material_index["roof_" + style] = gltf.add_material(
            "Roof_" + style.capitalize(), tex, rough, metal)

    chunks = {}          # (cx, cz) -> {material key: Surface}
    collision = {}       # (cx, cz) -> Surface
    landmarks = []
    stats = {"built": 0, "in_road": 0, "degenerate": 0, "off_terrain": 0,
             "solid": 0, "pitched": 0, "tagged_height": 0,
             "self_intersecting": 0}
    shape_count = {}
    style_count = {}

    for way in ways:
        if args.max and stats["built"] >= args.max:
            break
        way_id = int(way.get("id", 0))
        ring_raw = []
        for node in way["geometry"]:
            x = (node["lon"] - lon0) * EARTH_LON * k
            z = -(node["lat"] - lat0) * EARTH_LAT
            ring_raw.append((x, z))
        ring = clean_ring(ring_raw)
        if ring is None or len(ring) > 400:
            stats["degenerate"] += 1
            continue
        area = signed_area(ring)
        if area < 6.0:
            stats["degenerate"] += 1        # a shed smaller than a car: noise
            continue
        if not is_simple(ring):
            stats["self_intersecting"] += 1
            continue

        # Out of the road. Both tests are needed: a corner shop is caught by the
        # vertex test, and a warehouse the road drives through is only caught by
        # asking whether the road is inside it.
        clearance = args.clear
        if any(near.distance(px, pz, clearance) < clearance for px, pz in ring):
            stats["in_road"] += 1
            continue
        if near.samples_inside(ring, pad=clearance * 0.5):
            stats["in_road"] += 1
            continue

        cx = sum(p[0] for p in ring) / len(ring)
        cz = sum(p[1] for p in ring) / len(ring)
        base = ground(cx, cz)
        if base is None:
            stats["off_terrain"] += 1
            continue
        # The elevation model is 30 m data: across a footprint on a Kigali
        # hillside the ground under one corner can be metres below the ground
        # under another. Standing the building on its centroid's height leaves
        # the downhill corners hanging in the air, which is the single most
        # obvious way a generated city gives itself away. So the walls start at
        # the *lowest* ground the footprint touches, with a skirt below that,
        # and the height is still measured from the centroid - a building may
        # be buried a little at the back, which is what buildings on hills do,
        # but none of them float.
        foot = base
        for px, pz in ring:
            here = ground(px, pz)
            if here is not None and here < foot:
                foot = here
        foot -= 0.6

        tags = way.get("tags", {})
        spec = classify(way_id, tags, area)
        if spec["tagged_height"]:
            stats["tagged_height"] += 1

        rect = min_area_rect(ring)
        # Only pitch a roof the footprint can actually carry. A hip built on the
        # bounding rectangle of an L-shaped plot hangs in the air over one wing.
        if rect is not None and spec["roof_shape"] != "flat":
            if rect[5] > area * 1.22 or rect[4] * 2.0 > 40.0:
                spec["roof_shape"] = "flat"
                spec["roof_material"] = "flat"
        if spec["roof_shape"] != "flat":
            stats["pitched"] += 1

        wall_key = "wall_" + spec["wall"]
        roof_key = "roof_" + spec["roof_material"]
        wall_tints = WALL_TINTS[spec["wall"]]
        roof_tints = ROOF_TINTS[spec["roof_material"]]
        wall_colour = wall_tints[int(seeded(way_id, "wc") * len(wall_tints))] + (1.0,)
        roof_colour = roof_tints[int(seeded(way_id, "rc") * len(roof_tints))] + (1.0,)

        # A pitched roof is part of the tagged height, so the wall stops short of
        # it; a flat one is not, so the wall goes all the way.
        total = spec["height"]
        if spec["roof_shape"] == "flat":
            wall_top = base + total
        else:
            wall_top = base + max(2.4, total - roof_rise(spec, rect, total))
        if wall_top - foot < 2.4:
            wall_top = foot + 2.4

        key = (int(math.floor(cx / CHUNK_METRES)), int(math.floor(cz / CHUNK_METRES)))
        surfaces = chunks.setdefault(key, {})
        walls = surfaces.setdefault(wall_key, Surface())
        roofs = surfaces.setdefault(roof_key, Surface())

        tris = ear_clip(ring)
        add_wall_ring(walls, ring, foot, wall_top, wall_colour)
        reached = build_roof(walls, roofs, ring, tris, wall_top, spec, rect,
                             wall_colour, roof_colour)

        shape_count[spec["roof_shape"]] = shape_count.get(spec["roof_shape"], 0) + 1
        style_count[spec["wall"]] = style_count.get(spec["wall"], 0) + 1
        stats["built"] += 1

        # Solid, if the car could ever get to it. The collision shell is the
        # plain prism: a roof you can land on is not worth the triangles, and a
        # flat lid at the eaves is what a car hitting a house actually meets.
        if near.distance(cx, cz, args.collide) < args.collide:
            shell = collision.setdefault(key, Surface())
            add_wall_ring(shell, ring, foot, wall_top, (1.0, 1.0, 1.0, 1.0))
            add_cap(shell, ring, tris, wall_top, (1.0, 1.0, 1.0, 1.0))
            stats["solid"] += 1

        name = is_landmark(tags, spec["height"])
        if name:
            landmarks.append({
                "name": name,
                "kind": tags.get("amenity") or tags.get("tourism")
                        or tags.get("office") or spec["kind"],
                "position": [round(cx + offset[0], 2), round(reached + offset[1], 2),
                             round(cz + offset[2], 2)],
                "height": round(spec["height"], 1),
                "footprint_area": round(area, 1),
            })

    # ------------------------------------------------------------ to the file
    visible_nodes = 0
    for (gx, gz), surfaces in sorted(chunks.items()):
        primitives = []
        for key, surface in sorted(surfaces.items()):
            if surface.empty():
                continue
            primitives.append({
                "attributes": {
                    "POSITION": gltf.add_vec(surface.pos, "VEC3"),
                    "NORMAL": gltf.add_vec(surface.nrm, "VEC3"),
                    "TEXCOORD_0": gltf.add_vec(surface.uv, "VEC2"),
                    "COLOR_0": gltf.add_colours(surface.col),
                },
                "indices": gltf.add_indices(surface.idx),
                "material": material_index[key],
            })
        if not primitives:
            continue
        name = "CityChunk_%+04d_%+04d" % (gx, gz)
        gltf.add_node(name, gltf.add_mesh(name, primitives))
        visible_nodes += 1

    # `-colonly` is Godot's own import suffix: the importer turns the node into a
    # StaticBody3D with a trimesh shape and throws the mesh away. Doing it by
    # name means the collision needs no code on the Godot side at all.
    collision_nodes = 0
    for (gx, gz), surface in sorted(collision.items()):
        if surface.empty():
            continue
        primitives = [{
            "attributes": {"POSITION": gltf.add_vec(surface.pos, "VEC3")},
            "indices": gltf.add_indices(surface.idx),
        }]
        name = "CitySolid_%+04d_%+04d-colonly" % (gx, gz)
        gltf.add_node(name, gltf.add_mesh(name, primitives))
        collision_nodes += 1

    glb_path = os.path.join(args.out, "%s_city.glb" % args.name)
    size = gltf.write(glb_path, "astra-racer build_city.py")

    triangles = sum(len(s.idx) // 3 for c in chunks.values() for s in c.values())
    vertices = sum(len(s.pos) for c in chunks.values() for s in c.values())
    collision_tris = sum(len(s.idx) // 3 for s in collision.values())

    manifest = {
        "name": args.name,
        "source": "OpenStreetMap contributors, ODbL",
        "frame": "terrain-local: x east, z south, y metres above model zero",
        "offset": list(offset),
        "chunk_metres": CHUNK_METRES,
        "buildings": stats["built"],
        "footprints_available": len(ways),
        "dropped_in_road": stats["in_road"],
        "dropped_degenerate": stats["degenerate"],
        "dropped_self_intersecting": stats["self_intersecting"],
        "dropped_off_terrain": stats["off_terrain"],
        "with_tagged_height": stats["tagged_height"],
        "pitched_roofs": stats["pitched"],
        "solid_buildings": stats["solid"],
        "visible_chunks": visible_nodes,
        "collision_chunks": collision_nodes,
        "triangles": triangles,
        "vertices": vertices,
        "collision_triangles": collision_tris,
        "roof_shapes": shape_count,
        "wall_styles": style_count,
        "landmarks": len(landmarks),
        "clear_metres": args.clear,
        "collide_metres": args.collide,
    }
    with open(os.path.join(args.out, "%s_city.json" % args.name), "w",
              encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    landmarks.sort(key=lambda b: -b["footprint_area"])
    with open(os.path.join(args.out, "%s_city_landmarks.json" % args.name), "w",
              encoding="utf-8") as f:
        json.dump({"source": "OpenStreetMap contributors, ODbL",
                   "frame": "circuit coordinates",
                   "landmarks": landmarks}, f, indent=2)

    print("# %d buildings built of %d footprints" % (stats["built"], len(ways)),
          file=sys.stderr)
    print("#   %d dropped in the road, %d degenerate, %d self-intersecting, "
          "%d off the terrain"
          % (stats["in_road"], stats["degenerate"], stats["self_intersecting"],
             stats["off_terrain"]), file=sys.stderr)
    print("#   roofs: %s" % shape_count, file=sys.stderr)
    print("#   walls: %s" % style_count, file=sys.stderr)
    print("#   %d solid near the track (%d collision triangles in %d chunks)"
          % (stats["solid"], collision_tris, collision_nodes), file=sys.stderr)
    print("#   %d landmarks named" % len(landmarks), file=sys.stderr)
    print("#   %d triangles, %d vertices, %d visible chunks"
          % (triangles, vertices, visible_nodes), file=sys.stderr)
    print("# wrote %s (%.1f MB)" % (glb_path, size / 1e6), file=sys.stderr)
    return 0


def terrain_offset(gd_path, track_name):
    """The circuit-space position the terrain and the city are mounted at."""
    import re
    text = open(gd_path, encoding="utf-8").read()
    start = text.find('"name": "%s"' % track_name)
    block = text[start:]
    at = block.find('"terrain"')
    m = re.search(r"Vector3\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)",
                  block[at:at + 400])
    if not m:
        raise SystemExit("build_city: no terrain position for %s" % track_name)
    return tuple(float(g) for g in m.groups())


if __name__ == "__main__":
    sys.exit(main())
