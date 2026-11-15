#!/usr/bin/env python3
"""Fits the app icon artwork to the shape macOS masks icons with, and writes the Icon Composer layer.

    scripts/fit-icon.py                      support/icon/master.png -> support/AppIcon.icon/Assets/artwork.png
    scripts/fit-icon.py <master.png> <out.png>

Why: the master artwork is a rounded square drawn with transparent margins. Its corners are a little
rounder than the system icon shape. Shipped as a plain .icns, macOS scales it into its own shape and
fills the gap at each corner with a pale band. Fitted first, the system mask cuts exactly along the
artwork's own rim and no band appears.

How: a radial warp around the centre of the artwork. In the middle it is a uniform scale, so the
symbol keeps its shape and position. Toward the edge it blends into the scale that lands the
artwork's edge on the system edge. The largest change is about two percent, near the corners.

The system shape is not written down here. The script asks Icon Composer's ictool to render a plain
icon and reads the shape from that, so it stays right when the system shape changes. That needs
Xcode. The script needs Pillow and NumPy.

Run it again whenever support/icon/master.png changes. scripts/bundle.sh compiles the result.
"""

import math
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANVAS = 1024
ANGLES = 2880
SRGB_PROFILE = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
# The warp starts this far out, as a fraction of the distance to the edge. Inside it nothing bends.
BLEND_START = 0.62


def system_mask() -> np.ndarray:
    """The system icon shape as coverage from 0 to 1 on a CANVAS square, rendered by ictool."""
    developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip()
    ictool = os.path.join(
        os.path.dirname(developer), "Applications", "Icon Composer.app", "Contents", "Executables", "ictool"
    )
    if not os.path.exists(ictool):
        raise SystemExit("fit-icon: Icon Composer's ictool was not found. It ships with Xcode 26 and later.")
    with tempfile.TemporaryDirectory() as work:
        document = os.path.join(work, "plain.icon")
        os.makedirs(os.path.join(document, "Assets"))
        with open(os.path.join(document, "icon.json"), "w") as handle:
            handle.write(
                '{ "fill" : { "solid" : "extended-srgb:1.00000,1.00000,1.00000,1.00000" }, "groups" : [ ], '
                '"supported-platforms" : { "squares" : "shared" } }'
            )
        rendered = os.path.join(work, "plain.png")
        subprocess.run(
            [
                ictool, document, "--export-image", "--output-file", rendered, "--platform", "macOS",
                "--rendition", "Default", "--width", str(CANVAS), "--height", str(CANVAS), "--scale", "1",
            ],
            capture_output=True, check=True,
        )
        return np.asarray(Image.open(rendered).convert("RGBA")).astype(np.float64)[..., 3] / 255.0


def edge_radii(coverage: np.ndarray, cx: float, cy: float) -> np.ndarray:
    """For each angle, the distance from the centre at which coverage falls through one half."""
    height, width = coverage.shape
    radii = np.arange(0.0, 0.75 * max(height, width), 0.25)
    angles = np.linspace(-math.pi, math.pi, ANGLES, endpoint=False)
    result = np.zeros(ANGLES)
    for index, angle in enumerate(angles):
        xs = cx + radii * math.cos(angle)
        ys = cy + radii * math.sin(angle)
        inside = (xs >= 0) & (xs <= width - 1) & (ys >= 0) & (ys <= height - 1)
        xi = np.clip(np.round(xs).astype(int), 0, width - 1)
        yi = np.clip(np.round(ys).astype(int), 0, height - 1)
        values = np.where(inside, coverage[yi, xi], 0.0)
        outside = np.where(values < 0.5)[0]
        result[index] = radii[outside[0]] if len(outside) else radii[-1]
    # Average over a few neighbours so pixel steps in the measured edge do not ripple the warp.
    reach = 9
    padded = np.concatenate([result[-reach:], result, result[:reach]])
    return np.convolve(padded, np.ones(2 * reach + 1) / (2 * reach + 1), mode="valid")


def extend_edges(pixels: np.ndarray, rounds: int = 16) -> np.ndarray:
    """Grows the artwork's colours outward into its transparent margin, so sampling near the edge
    never mixes in whatever colour the transparent pixels happen to hold."""
    colour = pixels[..., :3].copy()
    known = pixels[..., 3] > 254.0
    for _ in range(rounds):
        total = np.zeros_like(colour)
        count = np.zeros(known.shape)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                shifted_known = np.roll(np.roll(known, dy, axis=0), dx, axis=1)
                shifted_colour = np.roll(np.roll(colour, dy, axis=0), dx, axis=1)
                total += shifted_colour * shifted_known[..., None]
                count += shifted_known
        grow = (~known) & (count > 0)
        colour[grow] = total[grow] / count[grow][..., None]
        known = known | grow
    return colour


def cubic_weights(fraction: np.ndarray) -> list[np.ndarray]:
    """Catmull-Rom weights for the four samples around a position."""
    f = fraction
    return [
        ((-0.5 * f + 1.0) * f - 0.5) * f,
        (1.5 * f - 2.5) * f * f + 1.0,
        ((-1.5 * f + 2.0) * f + 0.5) * f,
        (0.5 * f - 0.5) * f * f,
    ]


def sample_cubic(colour: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    height, width = colour.shape[:2]
    x0 = np.floor(xs).astype(int)
    y0 = np.floor(ys).astype(int)
    wx = cubic_weights(xs - x0)
    wy = cubic_weights(ys - y0)
    out = np.zeros(xs.shape + (3,))
    for j in range(4):
        row = np.clip(y0 + j - 1, 0, height - 1)
        for i in range(4):
            column = np.clip(x0 + i - 1, 0, width - 1)
            out += colour[row, column] * (wx[i] * wy[j])[..., None]
    return out


def main() -> int:
    arguments = sys.argv[1:]
    if len(arguments) not in (0, 2):
        print(__doc__)
        return 64
    source = arguments[0] if arguments else os.path.join(ROOT, "support", "icon", "master.png")
    target = arguments[1] if arguments else os.path.join(ROOT, "support", "AppIcon.icon", "Assets", "artwork.png")

    master = Image.open(source)
    profile = master.info.get("icc_profile")
    if profile is None and os.path.exists(SRGB_PROFILE):
        # A master with no embedded profile is sRGB. Say so in the layer, so nothing has to guess.
        with open(SRGB_PROFILE, "rb") as handle:
            profile = handle.read()
    art = np.asarray(master.convert("RGBA")).astype(np.float64)
    if art.shape[0] != art.shape[1]:
        raise SystemExit("fit-icon: the master must be square")
    alpha = art[..., 3] / 255.0
    middle = art.shape[0] // 2
    across = np.where(alpha[middle] > 0.5)[0]
    down = np.where(alpha[:, middle] > 0.5)[0]
    if len(across) == 0 or len(down) == 0:
        raise SystemExit("fit-icon: the master has no opaque body through its centre")
    art_cx = (across.min() + across.max()) / 2.0
    art_cy = (down.min() + down.max()) / 2.0
    half_x = (across.max() - across.min() + 1) / 2.0
    half_y = (down.max() - down.min() + 1) / 2.0

    mask = system_mask()
    centre = (CANVAS - 1) / 2.0
    art_edge = edge_radii(alpha, art_cx, art_cy)
    system_edge = edge_radii(mask, centre, centre)

    ys, xs = np.mgrid[0:CANVAS, 0:CANVAS].astype(np.float64)
    dx = xs - centre
    dy = ys - centre
    distance = np.hypot(dx, dy)
    angle = np.arctan2(dy, dx)
    slot = (angle + math.pi) / (2.0 * math.pi) * ANGLES
    low = np.floor(slot).astype(int) % ANGLES
    high = (low + 1) % ANGLES
    part = slot - np.floor(slot)
    to_art_edge = art_edge[low] * (1.0 - part) + art_edge[high] * part
    to_system_edge = system_edge[low] * (1.0 - part) + system_edge[high] * part

    half = CANVAS / 2.0
    uniform = 1.0 / np.sqrt((np.cos(angle) / (half_x / half)) ** 2 + (np.sin(angle) / (half_y / half)) ** 2)
    at_edge = to_art_edge / to_system_edge
    progress = np.divide(distance, to_system_edge, out=np.zeros_like(distance), where=to_system_edge > 0)
    ramp = np.clip((progress - BLEND_START) / (1.0 - BLEND_START), 0.0, 1.0)
    ramp = ramp * ramp * (3.0 - 2.0 * ramp)
    scale = uniform + (at_edge - uniform) * ramp
    # Past the artwork's edge, keep reading just inside it, so the square is filled to its corners.
    reach = np.minimum(scale * distance, to_art_edge - 1.25)
    source_x = art_cx + reach * np.cos(angle)
    source_y = art_cy + reach * np.sin(angle)

    colour = extend_edges(art)
    fitted = np.clip(sample_cubic(colour, source_x, source_y), 0.0, 255.0).round().astype(np.uint8)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    # Carry the master's colour profile over, so the layer is not left untagged.
    extra = {"icc_profile": profile} if profile else {}
    Image.fromarray(fitted, "RGB").save(target, optimize=True, **extra)

    symbol = progress < BLEND_START + 0.04
    print("fit-icon: artwork body %.0f x %.0f px, centred at (%.1f, %.1f)" % (2 * half_x, 2 * half_y, art_cx, art_cy))
    print("fit-icon: largest change %.2f%%, near the corners" % (100.0 * np.max(np.abs(at_edge - uniform) / uniform)))
    print("fit-icon: change inside the symbol area %.3f%%" % (100.0 * np.max((np.abs(scale - uniform) / uniform)[symbol])))
    print("fit-icon: wrote %s" % os.path.relpath(target, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
