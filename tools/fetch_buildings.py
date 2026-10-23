#!/usr/bin/env python3
"""Fetch building footprints for an area and put them in the terrain's frame.

The terrain model defines a local frame: x east, z south, y metres above the
lowest point of the model. Buildings are fetched in that same frame, and each
one's base is the ground height sampled from the terrain heightmap, so a block of
flats stands on the hillside it actually stands on rather than floating at sea
level or sinking into a slope.

Source: OpenStreetMap, via Overpass, under ODbL - attribution required.

Writes <name>_buildings.json:
    {"frame": "...", "buildings": [{"footprint": [[x, z], ...], "base": y,
                                    "height": h, "levels": n}, ...]}

Usage:
  python3 tools/fetch_buildings.py --terrain assets/terrain/kigali_terrain.json \
      --out assets/terrain --name kigali --max 4000
"""

import argparse
import json
import math
import os
import sys
import urllib.parse
import urllib.request

OVERPASS = "https://overpass-api.de/api/interpreter"
EARTH_LAT = 110540.0
EARTH_LON = 111320.0


def overpass(query, cache):
    if os.path.exists(cache):
        return json.load(open(cache, encoding="utf-8"))
    data = urllib.parse.urlencode({"data": query}).encode()
    req = urllib.request.Request(OVERPASS, data=data,
                                headers={"User-Agent": "astra-racer/1.0 (terrain build)"})
    with urllib.request.urlopen(req, timeout=180) as r:
        out = json.loads(r.read().decode("utf-8"))
    with open(cache, "w", encoding="utf-8") as f:
        json.dump(out, f)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--terrain", required=True)
    ap.add_argument("--out", default=".")
    ap.add_argument("--name", default="kigali")
    ap.add_argument("--max", type=int, default=4000)
    ap.add_argument("--default-height", type=float, default=7.0)
    ap.add_argument("--metres-per-level", type=float, default=3.2)
    ap.add_argument("--cache", default=os.path.join(
        os.path.expanduser("~"), ".cache", "astra_racer_buildings.json"))
    args = ap.parse_args()

    try:
        from PIL import Image
    except ImportError:
        print("PIL is required to sample the terrain", file=sys.stderr)
        return 1

    meta = json.load(open(args.terrain, encoding="utf-8"))
    b = meta["bounds"]
    lat0 = meta["centre"]["lat"]
    lon0 = meta["centre"]["lon"]
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

    query = ("[out:json][timeout:180];"
             "way[\"building\"](%.6f,%.6f,%.6f,%.6f);out geom;"
             % (b["lat_min"], b["lon_min"], b["lat_max"], b["lon_max"]))
    print("# asking overpass for buildings in the terrain box", file=sys.stderr)
    data = overpass(query, args.cache)
    ways = [e for e in data.get("elements", []) if e.get("type") == "way" and e.get("geometry")]
    print(f"# {len(ways)} ways returned", file=sys.stderr)

    out = []
    skipped = 0
    for w in ways:
        tags = w.get("tags", {})
        footprint = []
        for node in w["geometry"]:
            x = (node["lon"] - lon0) * EARTH_LON * k
            z = -(node["lat"] - lat0) * EARTH_LAT
            footprint.append((x, z))
        if len(footprint) < 3:
            skipped += 1
            continue
        # Height: an explicit one, else floors, else a shop-sized default.
        h = None
        if "height" in tags:
            try:
                h = float(str(tags["height"]).split()[0].replace("m", ""))
            except ValueError:
                h = None
        levels = None
        if "building:levels" in tags:
            try:
                levels = int(float(tags["building:levels"]))
            except ValueError:
                levels = None
        if h is None and levels is not None:
            h = levels * args.metres_per_level
        if h is None:
            h = args.default_height
        h = max(3.0, min(120.0, h))
        base = ground(footprint[0][0], footprint[0][1])
        if base is None:
            skipped += 1
            continue
        out.append({"footprint": footprint, "base": base, "height": h,
                    "levels": levels or 0})
        if len(out) >= args.max:
            break

    payload = {"frame": "terrain-local: x east, z south, y metres above model zero",
               "source": "OpenStreetMap contributors, ODbL",
               "buildings": out}
    path = os.path.join(args.out, f"{args.name}_buildings.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f)
    print(f"# {len(out)} buildings written ({skipped} skipped)", file=sys.stderr)
    if out:
        hs = sorted(x["height"] for x in out)
        print(f"#   heights {hs[0]:.0f} .. {hs[-1]:.0f} m, median {hs[len(hs)//2]:.0f} m",
              file=sys.stderr)
        xs = [p[0] for x in out for p in x["footprint"]]
        zs = [p[1] for x in out for p in x["footprint"]]
        print(f"#   extent x {min(xs):.0f}..{max(xs):.0f}  z {min(zs):.0f}..{max(zs):.0f}",
              file=sys.stderr)
    print(f"# wrote {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
