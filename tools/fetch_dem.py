#!/usr/bin/env python3
"""Fetch a real elevation model for an area and write it as a heightmap.

The race-route GPX carries 293 elevations along one line. That is a profile, not
a surface: it says how high the road is, not how high the ground either side of
it is, and a terrain built by smearing a line sideways would be a fiction. This
pulls the actual ground instead.

Source: the AWS Open Data "terrain-tiles" set (Mapzen's terrarium encoding,
derived from SRTM), which is public, needs no account and no key. Elevation is
packed into the RGB of a PNG so it survives a plain HTTP fetch:

    elevation_metres = (R * 256 + G + B / 256) - 32768

Writes, into an output directory:
    <name>_heightmap.png    16-bit, 0 = lowest point, 65535 = highest
    <name>_terrain.json     the georeference, the elevation range, attribution

Usage:
  python3 tools/fetch_dem.py --lat -1.94 --lon 30.09 --size-km 6.4 \
      --zoom 14 --grid 256 --out assets/terrain --name kigali
"""

import argparse
import io
import json
import math
import os
import subprocess
import sys
import urllib.request

TILE = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def lon_to_x(lon, z):
    return (lon + 180.0) / 360.0 * (1 << z)


def lat_to_y(lat, z):
    r = math.radians(lat)
    return (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * (1 << z)


def x_to_lon(x, z):
    return x / (1 << z) * 360.0 - 180.0


def y_to_lat(y, z):
    n = math.pi - 2.0 * math.pi * y / (1 << z)
    return math.degrees(math.atan(0.5 * (math.exp(n) - math.exp(-n))))


def fetch(z, x, y, cache):
    """One terrarium tile, cached on disk so a rerun costs nothing."""
    path = os.path.join(cache, f"{z}_{x}_{y}.png")
    if not os.path.exists(path):
        url = TILE.format(z=z, x=x, y=y)
        with urllib.request.urlopen(url, timeout=45) as r:
            data = r.read()
        if not data.startswith(b"\x89PNG"):
            raise RuntimeError(f"{url} did not return a PNG")
        with open(path, "wb") as f:
            f.write(data)
    return path


def decode(path, grid):
    """Tile PNG to a 2-D elevation array, via ImageMagick's raw RGB output."""
    raw = subprocess.run(["convert", path, "-depth", "8", "rgb:-"],
                         capture_output=True, check=True).stdout
    w = h = int(math.sqrt(len(raw) / 3))
    out = [[0.0] * w for _ in range(h)]
    for j in range(h):
        row = out[j]
        base = j * w * 3
        for i in range(w):
            k = base + i * 3
            row[i] = (raw[k] * 256 + raw[k + 1] + raw[k + 2] / 256.0) - 32768.0
    if (w, h) != (grid, grid):
        raise RuntimeError(f"tile is {w}x{h}, expected {grid}x{grid}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--size-km", type=float, default=6.4)
    ap.add_argument("--zoom", type=int, default=14)
    ap.add_argument("--grid", type=int, default=256)
    ap.add_argument("--out", default=".")
    ap.add_argument("--name", default="terrain")
    ap.add_argument("--cache", default=os.path.join(
        os.path.expanduser("~"), ".cache", "astra_terrain_tiles"))
    args = ap.parse_args()

    try:
        from PIL import Image
    except ImportError:
        print("PIL is required to write the heightmap", file=sys.stderr)
        return 1

    os.makedirs(args.cache, exist_ok=True)
    os.makedirs(args.out, exist_ok=True)

    dlat = (args.size_km / 2.0) / 110.54
    dlon = (args.size_km / 2.0) / (111.32 * math.cos(math.radians(args.lat)))
    lat0, lat1 = args.lat - dlat, args.lat + dlat
    lon0, lon1 = args.lon - dlon, args.lon + dlon

    z = args.zoom
    x0 = int(math.floor(lon_to_x(lon0, z)))
    x1 = int(math.floor(lon_to_x(lon1, z)))
    y0 = int(math.floor(lat_to_y(lat1, z)))     # north is the low y
    y1 = int(math.floor(lat_to_y(lat0, z)))
    tiles_x, tiles_y = x1 - x0 + 1, y1 - y0 + 1
    print(f"# {tiles_x * tiles_y} tiles at z={z} covering "
          f"{args.size_km:.1f} x {args.size_km:.1f} km", file=sys.stderr)

    mosaic = []
    for y in range(y0, y1 + 1):
        row = []
        for x in range(x0, x1 + 1):
            row.append(decode(fetch(z, x, y, args.cache), 256))
        mosaic.append(row)
    full_h = len(mosaic) * 256
    full = [[0.0] * (tiles_x * 256) for _ in range(full_h)]
    for ty, row in enumerate(mosaic):
        for tx, tile in enumerate(row):
            for j in range(256):
                dst = full[ty * 256 + j]
                src = tile[j]
                for i in range(256):
                    dst[tx * 256 + i] = src[i]

    # Crop to the requested box, by fractional tile pixel position.
    def col_of(lon):
        return (lon_to_x(lon, z) - x0) * 256

    def row_of(lat):
        return (lat_to_y(lat, z) - y0) * 256

    c0, c1 = int(round(col_of(lon0))), int(round(col_of(lon1)))
    r0, r1 = int(round(row_of(lat1))), int(round(row_of(lat0)))
    c0, c1 = max(0, c0), min(tiles_x * 256, c1)
    r0, r1 = max(0, r0), min(full_h, r1)
    crop_w, crop_h = c1 - c0, r1 - r0
    print(f"# cropped to {crop_w} x {crop_h} px "
          f"({args.size_km * 1000.0 / crop_w:.1f} m per pixel)", file=sys.stderr)

    # Nearest-neighbour resample to the requested grid.
    grid = args.grid
    heights = [[0.0] * grid for _ in range(grid)]
    for j in range(grid):
        sy = min(crop_h - 1, int(j * crop_h / grid))
        src_row = full[r0 + sy]
        dst_row = heights[j]
        for i in range(grid):
            sx = min(crop_w - 1, int(i * crop_w / grid))
            dst_row[i] = src_row[c0 + sx]

    flat = [v for row in heights for v in row]
    lo, hi = min(flat), max(flat)
    print(f"# elevation {lo:.0f} .. {hi:.0f} m  (range {hi - lo:.0f} m)", file=sys.stderr)

    span = max(1.0, hi - lo)
    img = Image.new("I;16", (grid, grid))
    img.putdata([int(round((v - lo) / span * 65535.0)) for v in flat])
    hm_path = os.path.join(args.out, f"{args.name}_heightmap.png")
    img.save(hm_path)

    meta = {
        "name": args.name,
        "source": "AWS Open Data terrain-tiles (Mapzen terrarium encoding, SRTM-derived)",
        "attribution": "Elevation: Mapzen/Amazon terrain-tiles, from NASA SRTM",
        "zoom": z,
        "grid": grid,
        "centre": {"lat": args.lat, "lon": args.lon},
        "bounds": {"lat_min": lat0, "lat_max": lat1, "lon_min": lon0, "lon_max": lon1},
        "metres_per_pixel": (args.size_km * 1000.0) / grid,
        "elevation_min_m": round(lo, 2),
        "elevation_max_m": round(hi, 2),
        "heightmap": os.path.basename(hm_path),
    }
    json_path = os.path.join(args.out, f"{args.name}_terrain.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(f"# wrote {hm_path}", file=sys.stderr)
    print(f"# wrote {json_path}", file=sys.stderr)

    # Row 0 is north; a spot check makes a flipped or mis-decoded mosaic show up
    # here rather than as a terrain built upside down.
    corner = [heights[0][0], heights[0][-1], heights[-1][0], heights[-1][-1]]
    print(f"# corners NW/NE/SW/SE: " + ", ".join(f"{v:.0f} m" for v in corner),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
