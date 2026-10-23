#!/usr/bin/env python3
"""Draw the sky the circuits are raced under, as an equirectangular panorama.

Godot's own ProceduralSkyMaterial is two colours and a sun, and two colours and
a sun is what the game had: a vertical wash from blue to beige with nothing in
it. That is fine behind a parkland loop with trees on the skyline. It is not
fine over Kigali, where the circuit runs along a ridge and a third of the frame
is sky for most of the lap - an empty gradient up there reads as a missing
texture, and no amount of work on the ground fixes it, because the ground is
being lit by that gradient too.

So the sky is drawn instead, and it carries the three things a procedural
gradient cannot:

  * **Cloud.** Cumulus built from fractal noise, thinned towards the zenith and
    piled up near the horizon, which is what perspective does to a deck of
    cloud at a fixed height - you look through more of it the further off it
    is. Lit from the sun's own direction, so the side of a cloud facing the sun
    is bright and the far side is grey.
  * **A sun in the right place.** Its disk and halo are drawn at exactly the
    direction the circuit's DirectionalLight3D shines from, so the glare and
    the shadows agree.
  * **Aerial perspective.** The last few degrees above the horizon are pale and
    warm rather than blue, because that is the air itself, and it is what makes
    a distant hillside sit *behind* something instead of floating.

Used as a PanoramaSkyMaterial it is also the ambient light and the reflection
probe for everything on the circuit, so the cloud is doing more than decorating
the top of the frame.

Usage:
  python3 tools/make_sky.py --out assets/sky --name kigali \\
      --sun-pitch -32 --sun-yaw 120
"""

import argparse
import math
import os
import sys

import numpy as np
from PIL import Image


# --------------------------------------------------------------------- noise

LATTICE = 512           # cells before the cloud noise repeats


def _plane_noise(x, z, scale, rng):
    """Value noise on the cloud plane, wrapping every LATTICE cells.

    The clouds are sampled on a flat plane above the observer rather than on
    the sphere's own (u, v), because (u, v) is not what a deck of cloud looks
    like: near the horizon v barely changes, so a lattice in v smears every
    cloud into a vertical streak running up to the zenith. On the plane the
    perspective comes out for free and there is no seam anywhere, since the
    projection is continuous and the lattice wraps.
    """
    lat = rng.random((LATTICE, LATTICE))
    fx = x / scale
    fz = z / scale
    i0 = np.floor(fx).astype(np.int64) % LATTICE
    j0 = np.floor(fz).astype(np.int64) % LATTICE
    i1 = (i0 + 1) % LATTICE
    j1 = (j0 + 1) % LATTICE
    tx = fx - np.floor(fx)
    tz = fz - np.floor(fz)
    tx = tx * tx * (3 - 2 * tx)
    tz = tz * tz * (3 - 2 * tz)
    a = lat[j0, i0]
    b = lat[j0, i1]
    c = lat[j1, i0]
    d = lat[j1, i1]
    return (a * (1 - tx) * (1 - tz) + b * tx * (1 - tz)
            + c * (1 - tx) * tz + d * tx * tz)


def fbm(x, z, octaves, scale, rng, gain=0.52):
    total = np.zeros_like(x)
    weight = 1.0
    norm = 0.0
    for k in range(octaves):
        total += _plane_noise(x, z, scale / (2 ** k), rng) * weight
        norm += weight
        weight *= gain
    return total / norm


# ----------------------------------------------------------------- the sky

def sun_direction(pitch_deg, yaw_deg):
    """Where the sun is, from the rotation the circuit gives its light.

    A DirectionalLight3D shines along its own -Z, so the sun is in the opposite
    direction, and Godot composes Node3D.rotation in YXZ order. Getting this
    from the same two numbers the circuit already carries is the whole point:
    the glare in the panorama and the shadows on the ground are then guaranteed
    to come from one place.
    """
    pitch = math.radians(pitch_deg)
    yaw = math.radians(yaw_deg)
    # R_y(yaw) * R_x(pitch) applied to (0, 0, -1)
    x, y, z = 0.0, math.sin(pitch), -math.cos(pitch)
    forward = (math.cos(yaw) * x + math.sin(yaw) * z, y,
               -math.sin(yaw) * x + math.cos(yaw) * z)
    return (-forward[0], -forward[1], -forward[2])


def build(width, height, sun, palette, seed):
    rng = np.random.default_rng(seed)
    # Equirectangular: u round the horizon, v from the zenith down.
    u = (np.arange(width) + 0.5) / width
    v = (np.arange(height) + 0.5) / height
    uu, vv = np.meshgrid(u, v)

    theta = vv * math.pi                 # 0 at the zenith, pi at the nadir
    phi = uu * 2.0 * math.pi
    dir_y = np.cos(theta)
    horiz = np.sin(theta)
    dir_x = horiz * np.sin(phi)
    dir_z = -horiz * np.cos(phi)

    up = np.clip(dir_y, 0.0, 1.0)

    # --- the gradient -------------------------------------------------------
    zenith = np.array(palette["zenith"])
    mid = np.array(palette["mid"])
    horizon = np.array(palette["horizon"])
    # Two bands rather than one: the useful detail in a real sky is all in the
    # bottom fifteen degrees, and a single lerp from zenith to horizon spends
    # most of its range on the half of the sky nobody is looking at.
    high = np.clip((up - 0.30) / 0.70, 0.0, 1.0)[..., None]
    low = np.clip(up / 0.30, 0.0, 1.0)[..., None]
    sky = horizon + (mid - horizon) * low
    sky = sky + (zenith - sky) * high

    # --- the sun ------------------------------------------------------------
    sun = np.array(sun, dtype=float)
    sun /= np.linalg.norm(sun)
    cosine = dir_x * sun[0] + dir_y * sun[1] + dir_z * sun[2]
    cosine = np.clip(cosine, -1.0, 1.0)
    angle = np.arccos(cosine)
    disk = np.clip(1.0 - angle / math.radians(1.4), 0.0, 1.0) ** 0.5
    halo = np.exp(-angle / math.radians(11.0)) * 0.55
    glare = np.exp(-angle / math.radians(48.0)) * 0.22
    sky = sky + np.array(palette["sun"]) * (disk * 2.2 + halo + glare)[..., None]

    # --- the cloud ----------------------------------------------------------
    # Project each direction onto a flat deck overhead: a ray leaving the
    # ground at elevation e meets a plane at height h a distance h / tan(e)
    # away, so straight up is directly overhead and the horizon is effectively
    # infinitely far. That single projection is where all the perspective comes
    # from - clouds get smaller and more crowded towards the horizon because
    # they really are further away, not because the shading says so.
    reach = 1.0 / np.clip(up, 1.0 / 90.0, 1.0)
    plane_x = dir_x * reach
    plane_z = dir_z * reach
    shape = fbm(plane_x, plane_z, 6, 1.7, rng, gain=0.58)
    detail = fbm(plane_x * 3.1 + 31.0, plane_z * 3.1 - 17.0, 4, 1.7, rng)
    field = shape * 0.72 + detail * 0.28

    cover = palette["cover"]
    # Looking along the deck you see through more of it, so the same cover
    # reads as more cloud near the horizon. sqrt of the path length, capped,
    # because at the horizon it would otherwise be solid white.
    depth = np.clip(np.sqrt(reach) * 0.40, 0.0, 1.2)
    threshold = np.clip(0.80 - cover * (0.28 + 0.30 * depth), 0.05, 0.99)
    # A narrow, fixed band rather than everything above the threshold: cumulus
    # go from clear sky to solid cloud in a few tens of metres, and dividing by
    # the whole remaining range instead ramps the density so slowly that every
    # cloud comes out as a haze with no edge to it.
    density = np.clip((field - threshold) / 0.085, 0.0, 1.0)
    density = density * density * (3.0 - 2.0 * density)
    # And the last two degrees fade into the haze, so the deck meets the
    # horizon instead of ending on a line.
    density *= np.clip((up - 0.004) / 0.045, 0.0, 1.0)
    density[dir_y <= 0.0] = 0.0

    # Lit from the sun, plus a crude thickness cue: sample the field again a
    # little way towards the sun and use the difference, so a cloud is bright
    # on the side the light comes from and grey where it is deep.
    towards = _plane_noise(plane_x + sun[0] * 0.75, plane_z + sun[2] * 0.75,
                           2.6, np.random.default_rng(seed)) - 0.5
    lit = np.clip(0.40 + 0.60 * np.clip(cosine, 0.0, 1.0) ** 0.5
                  + towards * 0.45, 0.0, 1.0)
    bright = np.array(palette["cloud_lit"])
    shadow = np.array(palette["cloud_shade"])
    cloud = shadow + (bright - shadow) * lit[..., None]
    # Thin cloud is bright and thick cloud is grey, which is the one cue that
    # tells you a cumulus has a body rather than being a white smear.
    cloud = cloud * (1.0 - 0.22 * density[..., None])
    sky = sky * (1.0 - density[..., None]) + cloud * density[..., None]

    # --- below the horizon --------------------------------------------------
    # Almost never seen - the terrain covers it - but a black hemisphere under
    # the world drags the sky-sourced ambient light down by half.
    below = np.clip(-dir_y / 0.25, 0.0, 1.0)[..., None]
    ground = np.array(palette["ground"])
    sky = sky * (1.0 - below) + ground * below

    return np.clip(sky, 0.0, 1.0)


PALETTES = {
    # Kigali: 1 500 m, two degrees south, and it rains most months. A deep but
    # not navy zenith, a pale warm band of haze over the hills, and real cloud.
    "kigali": {
        "zenith": (0.20, 0.38, 0.70),
        "mid": (0.44, 0.62, 0.84),
        "horizon": (0.80, 0.85, 0.88),
        "sun": (1.00, 0.95, 0.84),
        "cloud_lit": (1.00, 0.99, 0.97),
        "cloud_shade": (0.62, 0.66, 0.73),
        "ground": (0.24, 0.24, 0.22),
        "cover": 0.62,
    },
    "clear": {
        "zenith": (0.17, 0.34, 0.68),
        "mid": (0.42, 0.60, 0.83),
        "horizon": (0.84, 0.86, 0.85),
        "sun": (1.00, 0.96, 0.86),
        "cloud_lit": (1.00, 1.00, 0.99),
        "cloud_shade": (0.70, 0.73, 0.78),
        "ground": (0.22, 0.23, 0.21),
        "cover": 0.30,
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="assets/sky")
    ap.add_argument("--name", default="kigali")
    ap.add_argument("--palette", default=None)
    ap.add_argument("--width", type=int, default=2048)
    ap.add_argument("--sun-pitch", type=float, default=-32.0)
    ap.add_argument("--sun-yaw", type=float, default=120.0)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    palette = PALETTES[args.palette or args.name]
    sun = sun_direction(args.sun_pitch, args.sun_yaw)
    print("# sun at %.0f deg elevation, direction (%.2f, %.2f, %.2f)"
          % (math.degrees(math.asin(sun[1])), *sun), file=sys.stderr)
    sky = build(args.width, args.width // 2, sun, palette, args.seed)

    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "%s_sky.png" % args.name)
    Image.fromarray((sky * 255.0 + 0.5).astype("uint8"), "RGB").save(path)
    print("# wrote %s (%d x %d)" % (path, args.width, args.width // 2),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
