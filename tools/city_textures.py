#!/usr/bin/env python3
"""Generate the wall and roof textures the city is built from.

Four wall styles and three roof styles, drawn rather than photographed, so they
sit inside the game's flat-shaded look instead of fighting it: crisp rectangles,
no noise, no grunge, a palette in the same register as the road and the kerbs.

Each texture is *one tile* covering 4 bays by 4 floors - 12.8 m square at the
3.2 m per floor the importer uses everywhere else. Four bays rather than one is
the whole trick: a single-bay tile repeats every window and reads as wallpaper,
whereas four means a wall only repeats every 12.8 m, which at racing speed is
never.

Colour lives in the mesh, not here. Every texture is drawn in greys so the
per-building tint carried in the vertex colours multiplies cleanly over it -
that is what gets a whole city out of four materials.

Usage:
  python3 tools/city_textures.py --out assets/terrain
"""

import argparse
import os
import random
import sys
import zlib

from PIL import Image, ImageDraw

TILE = 512          # pixels per tile
BAYS = 4            # bays across the tile
FLOORS = 4          # floors up the tile
CELL = TILE // BAYS  # 128 px per bay / floor


def _cell(i, j):
    """Pixel box of bay i, floor j. Floor 0 is the *bottom* of the tile."""
    x0 = i * CELL
    y0 = (FLOORS - 1 - j) * CELL
    return x0, y0, x0 + CELL, y0 + CELL


def _window(draw, box, inset, frame, glass, sill=None, panes=(1, 1)):
    """A window inside a bay: a frame, glass, optionally a sill and mullions."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    ix0 = x0 + int(w * inset[0])
    ix1 = x1 - int(w * inset[1])
    iy0 = y0 + int(h * inset[2])
    iy1 = y1 - int(h * inset[3])
    if ix1 - ix0 < 4 or iy1 - iy0 < 4:
        return
    draw.rectangle([ix0, iy0, ix1, iy1], fill=frame)
    b = max(2, CELL // 32)
    draw.rectangle([ix0 + b, iy0 + b, ix1 - b, iy1 - b], fill=glass)
    across, up = panes
    for k in range(1, across):
        x = ix0 + (ix1 - ix0) * k // across
        draw.rectangle([x - b // 2, iy0, x + b // 2, iy1], fill=frame)
    for k in range(1, up):
        y = iy0 + (iy1 - iy0) * k // up
        draw.rectangle([ix0, y - b // 2, ix1, y + b // 2], fill=frame)
    if sill is not None:
        draw.rectangle([ix0 - b, iy1, ix1 + b, iy1 + b * 2], fill=sill)


def wall_plaster(rng):
    """Plastered masonry: the ordinary Kigali house and shopfront.

    Small punched windows, a course line at each floor, and a plinth along the
    ground floor - the ground floor is drawn differently from the ones above it
    because that is the difference a street actually shows.
    """
    img = Image.new("RGB", (TILE, TILE), (214, 210, 202))
    d = ImageDraw.Draw(img)
    for j in range(FLOORS):
        for i in range(BAYS):
            box = _cell(i, j)
            if j == 0 and i % 2 == 0:
                # A doorway or a shop opening at street level.
                _window(d, box, (0.28, 0.28, 0.30, 0.0), (168, 164, 156),
                        (96, 98, 102), panes=(2, 1))
            else:
                _window(d, box, (0.24, 0.24, 0.26, 0.30), (232, 230, 226),
                        (112, 120, 128), sill=(196, 192, 184), panes=(2, 2))
        y = _cell(0, j)[1]
        d.rectangle([0, y - 2, TILE, y + 1], fill=(198, 194, 186))
    return img


def wall_brick(rng):
    """Fired brick, laid in courses. Darker, smaller openings, no sills."""
    img = Image.new("RGB", (TILE, TILE), (176, 168, 160))
    d = ImageDraw.Draw(img)
    course = max(4, CELL // 12)
    for row, y in enumerate(range(0, TILE, course)):
        d.rectangle([0, y, TILE, y + 1], fill=(160, 152, 145))
        offset = (course * 2) if row % 2 else 0
        for x in range(offset, TILE, course * 4):
            d.rectangle([x, y, x + 1, y + course], fill=(160, 152, 145))
    for j in range(FLOORS):
        for i in range(BAYS):
            box = _cell(i, j)
            _window(d, box, (0.30, 0.30, 0.28, 0.34), (150, 144, 138),
                    (104, 110, 118), panes=(2, 2))
    return img


def wall_concrete(rng):
    """A mid-rise concrete frame: wide windows in a structural grid.

    The bays are separated by a visible column and each floor by a visible
    spandrel, because that is what makes a concrete-framed building look like
    one rather than like a wall with holes.
    """
    img = Image.new("RGB", (TILE, TILE), (206, 204, 200))
    d = ImageDraw.Draw(img)
    for j in range(FLOORS):
        for i in range(BAYS):
            box = _cell(i, j)
            _window(d, box, (0.14, 0.14, 0.22, 0.16), (188, 186, 182),
                    (118, 128, 138), panes=(3, 1))
        y = _cell(0, j)[1]
        d.rectangle([0, y - 3, TILE, y + 2], fill=(196, 194, 190))
    for i in range(1, BAYS):
        x = i * CELL
        d.rectangle([x - 3, 0, x + 2, TILE], fill=(198, 196, 192))
    return img


def wall_glass(rng):
    """A curtain wall: continuous glazing, thin mullions, a spandrel band."""
    img = Image.new("RGB", (TILE, TILE), (150, 162, 172))
    d = ImageDraw.Draw(img)
    mullion = max(2, CELL // 40)
    for j in range(FLOORS):
        y0 = _cell(0, j)[1]
        y1 = y0 + CELL
        band = y1 - max(6, CELL // 6)
        d.rectangle([0, y0, TILE, band], fill=(146, 160, 174))
        d.rectangle([0, band, TILE, y1], fill=(178, 180, 180))
        for i in range(BAYS * 2):
            x = i * TILE // (BAYS * 2)
            d.rectangle([x, y0, x + mullion, band], fill=(196, 198, 200))
        # One pane in every few is a different reflection. A perfectly uniform
        # curtain wall is the one thing real glass never is.
        for i in range(BAYS * 2):
            if rng.random() < 0.28:
                x = i * TILE // (BAYS * 2)
                w = TILE // (BAYS * 2)
                shade = rng.choice([(132, 146, 160), (166, 176, 186), (140, 154, 166)])
                d.rectangle([x + mullion, y0 + 2, x + w - 1, band - 2], fill=shade)
        d.rectangle([0, y1 - mullion, TILE, y1], fill=(196, 198, 200))
    return img


def roof_metal(rng):
    """Corrugated iron: the roof most of this city is actually under."""
    img = Image.new("RGB", (TILE, TILE), (178, 178, 176))
    d = ImageDraw.Draw(img)
    pitch = max(6, TILE // 64)
    for x in range(0, TILE, pitch):
        d.rectangle([x, 0, x + pitch // 2, TILE], fill=(196, 196, 194))
        d.rectangle([x + pitch // 2, 0, x + pitch, TILE], fill=(158, 158, 157))
    # Sheets are 2 m long and overlap; the lap line runs across the corrugations.
    for y in range(0, TILE, TILE // 4):
        d.rectangle([0, y, TILE, y + 2], fill=(148, 148, 147))
    return img


def roof_tile(rng):
    """Clay pantiles, in courses, for the houses that have them."""
    img = Image.new("RGB", (TILE, TILE), (188, 180, 176))
    d = ImageDraw.Draw(img)
    course = TILE // 12
    for row, y in enumerate(range(0, TILE, course)):
        offset = (course // 2) if row % 2 else 0
        d.rectangle([0, y, TILE, y + 2], fill=(150, 144, 140))
        for x in range(offset, TILE + course, course):
            d.rectangle([x, y, x + 2, y + course], fill=(164, 157, 153))
            d.ellipse([x + 3, y + 3, x + course - 3, y + course - 1],
                      fill=(200, 192, 188))
    return img


def roof_flat(rng):
    """A flat roof: bitumen bays, a parapet shadow, and plant. Seen from a car
    this is almost never visible - but from the top of the hill it is, and a
    flat grey plane up there is the thing that gives a fake city away."""
    img = Image.new("RGB", (TILE, TILE), (170, 168, 164))
    d = ImageDraw.Draw(img)
    bay = TILE // 6
    for x in range(0, TILE, bay):
        d.rectangle([x, 0, x + 2, TILE], fill=(158, 156, 152))
    for y in range(0, TILE, bay):
        d.rectangle([0, y, TILE, y + 2], fill=(158, 156, 152))
    for _ in range(7):
        w = rng.randint(bay // 2, bay * 2)
        h = rng.randint(bay // 2, bay * 2)
        x = rng.randint(0, TILE - w)
        y = rng.randint(0, TILE - h)
        d.rectangle([x, y, x + w, y + h], fill=(190, 188, 184))
        d.rectangle([x, y + h - 4, x + w, y + h], fill=(148, 146, 142))
    return img


def _wrapped_noise(size, cells, rng):
    """One octave of seamless value noise, as a `size` x `size` float array in
    [0, 1]. `cells` lattice points across the tile, wrapping at the edges, which
    is what makes the octave - and so the whole texture - tile."""
    import numpy as np
    lattice = np.array([[rng.random() for _ in range(cells)]
                        for _ in range(cells)])
    u = (np.arange(size) / size * cells)
    i0 = np.floor(u).astype(int) % cells
    i1 = (i0 + 1) % cells
    f = u - np.floor(u)
    f = f * f * (3.0 - 2.0 * f)
    a = lattice[np.ix_(i0, i0)]
    b = lattice[np.ix_(i1, i0)]
    c = lattice[np.ix_(i0, i1)]
    d = lattice[np.ix_(i1, i1)]
    fx = f[:, None]
    fy = f[None, :]
    return (a * (1 - fx) * (1 - fy) + b * fx * (1 - fy)
            + c * (1 - fx) * fy + d * fx * fy)


def _ground_height(rng):
    """The ground's own small relief, as a float array in roughly [0, 1].

    Everything about how the ground reads at close range comes from this: the
    albedo is this height shaded, and the normal map is its gradient. Building
    both from one field is what stops the shading and the bumps disagreeing,
    which is the thing that makes a tiled ground look like a photograph of
    ground rather than ground.

    Octaves only, and plenty of them. An earlier version folded one octave
    about its middle to get "tufts" with edges, which at a single frequency is
    not tufts, it is a maze - the ridges join up into worms the same width
    everywhere and the ground comes out looking like tripe. Grass has no
    characteristic width, so the field must not either.
    """
    import numpy as np
    field = np.zeros((TILE, TILE))
    weight = 1.0
    total = 0.0
    for cells in (2, 3, 5, 8, 13, 21, 34, 55, 89, 144):
        field += _wrapped_noise(TILE, cells, rng) * weight
        total += weight
        weight *= 0.62
    field /= total
    field -= field.min()
    field /= max(1e-6, field.max())
    return field


def ground_detail(rng):
    """Close-up detail for the ground, in neutral grey.

    The terrain is coloured per vertex - grass in the valley, dry scrub up the
    hill, red laterite where it is too steep to hold anything - so this carries
    no colour of its own. All it does is stop a ground cell from being a flat
    facet of one value, which from a car doing 160 is the difference between
    ground and a green screen.

    The first version of this was speckle: two and a half thousand grey dots on
    a flat grey field. Tiled every few metres over six kilometres of valley
    that is invisible - the dots are smaller than a pixel at any distance worth
    looking at, and all that survives is their mean, which is a flat grey
    field. What reads at distance is *structure with a size to it*, so the
    contrast here is carried by the largest octaves, and the speckle is kept
    only for the last few metres before the car reaches it.
    """
    import numpy as np
    field = _ground_height(rng)
    # Shade the relief the way the sun will: a fixed light from the north-west,
    # so a hummock has a lit side and a shadowed one. Gently - this is an
    # albedo, and baking a hard light into it is what makes tiled ground look
    # stamped.
    gy, gx = np.gradient(field * 4.0)
    shade = np.clip(0.5 + (gx - gy) * 0.5, 0.0, 1.0)
    value = field * 0.62 + shade * 0.38
    # Per-pixel grain on top: the scale of the soil itself, which no octave
    # coarse enough to survive downsampling can carry.
    grain = np.array([[rng.random() for _ in range(TILE)] for _ in range(TILE)])
    value = value * 0.90 + grain * 0.10
    # Centred on the mid grey the vertex colours are tuned against, and held to
    # a range that survives being multiplied by a colour: wider than this and
    # the ground crawls, narrower and it is the flat facet again.
    value = 0.76 + (value - value.mean()) * 1.05
    grey = np.clip(value * 255.0, 40, 250).astype("uint8")
    img = Image.fromarray(np.dstack([grey, grey, grey]), "RGB")
    # Grass strokes and pebbles: the only marks in the tile with a real edge,
    # and at close range they are what gives the ground a scale.
    d = ImageDraw.Draw(img)
    for _ in range(2600):
        x = rng.randrange(TILE)
        y = rng.randrange(TILE)
        lean = rng.randint(-4, 4)
        length = rng.randint(3, 9)
        v = rng.randint(120, 205)
        d.line([x, y, x + lean, y - length], fill=(v, v, v), width=1)
    for _ in range(500):
        x = rng.randrange(TILE)
        y = rng.randrange(TILE)
        r = rng.randint(1, 3)
        v = rng.randint(170, 225)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(v, v, v))
    return img


def ground_normal(rng):
    """The normal map of the same relief the albedo was shaded from.

    Tangent-space, OpenGL convention (+Y up), which is what Godot's glTF import
    expects. It is built from `_ground_height` with the same seed as
    `ground_detail`, so the bumps the light reacts to are the bumps the albedo
    draws - the ground gains relief under a moving sun instead of being a
    printed picture of relief lit from one fixed direction for ever.
    """
    import numpy as np
    field = _ground_height(rng)
    # Strength is in world terms: the octaves span GROUND_TILE metres, so a
    # unit of height here is about a fifth of a metre of ground.
    gy, gx = np.gradient(field * 9.0)
    nx = -gx
    ny = gy
    nz = np.ones_like(field)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    rgb = np.dstack([(nx / length * 0.5 + 0.5),
                     (ny / length * 0.5 + 0.5),
                     (nz / length * 0.5 + 0.5)])
    return Image.fromarray(np.clip(rgb * 255.0, 0, 255).astype("uint8"), "RGB")


TEXTURES = {
    "ground_detail": ground_detail,
    "ground_normal": ground_normal,
    "wall_plaster": wall_plaster,
    "wall_brick": wall_brick,
    "wall_concrete": wall_concrete,
    "wall_glass": wall_glass,
    "roof_metal": roof_metal,
    "roof_tile": roof_tile,
    "roof_flat": roof_flat,
}


def build(out_dir, prefix="city"):
    """Write every texture and return {name: path}."""
    os.makedirs(out_dir, exist_ok=True)
    written = {}
    for name, fn in TEXTURES.items():
        # The ground's normal map is the gradient of the same relief its albedo
        # is shaded from, so it has to be drawn from the same seed.
        seed_name = "ground_detail" if name == "ground_normal" else name
        rng = random.Random(zlib.crc32(seed_name.encode("utf-8")) & 0xFFFF)
        img = fn(rng)
        path = os.path.join(out_dir, f"{prefix}_{name}.png")
        img.save(path, optimize=True)
        written[name] = path
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="assets/terrain")
    ap.add_argument("--prefix", default="city")
    args = ap.parse_args()
    for name, path in build(args.out, args.prefix).items():
        print(f"# {name:16s} -> {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
