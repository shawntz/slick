#!/usr/bin/env python3
"""Writes the sample apps of the published stills into a data folder for a media scenario.

    python3 -I scenarios/media/seed.py <data folder>

The app runs scenarios over the Apps feature's synthetic tree in
<data>/Caches/apps/synthetic-apps, and writes its own small tree there only when the folder has
no tree-version file yet. This script writes that file first, with the sample apps from
LauncherUITesting's ShowcaseCatalog instead, so the clips show the same made-up apps as the stills.
Each bundle holds only an Info.plist, as the Apps feature's own synthetic bundles do.

Outside the live launcher, app icons are squares in a colour taken from a hash of the bundle ID.
Each bundle ID here is the app's name followed by the first number that makes that colour close to
the middle of the app's tile in the stills. The bundle IDs never show in the clips.
"""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Packages/LauncherUI/Sources/LauncherUITesting/ShowcaseCatalog.swift"


def tile_colors():
    """Each sample app's name and the middle of its tile's two colours, read from the catalog."""
    pattern = re.compile(r'App\(name: "([^"]+)", symbol: "[^"]+", top: 0x([0-9A-F]{6}), bottom: 0x([0-9A-F]{6})')
    apps = []
    for name, top, bottom in pattern.findall(CATALOG.read_text(encoding="utf-8")):
        a, b = int(top, 16), int(bottom, 16)
        apps.append((name, tuple(((a >> s & 0xFF) + (b >> s & 0xFF)) // 2 for s in (16, 8, 0))))
    if len(apps) < 10:
        sys.exit(f"seed: expected the sample apps in {CATALOG}, found {len(apps)}")
    return apps


def icon_color(bundle_id):
    """The colour the scenario icon renderer gives an app: SyntheticIconRenderer.color(for:)."""
    value = 0xCBF29CE484222325
    for byte in ("app:" + bundle_id).encode():
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return (value & 0xFF, value >> 8 & 0xFF, value >> 16 & 0xFF)


def bundle_id(name, target):
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    best = None
    for number in range(1, 200_000):
        candidate = f"com.example.{slug}.{number}"
        distance = sum((x - y) ** 2 for x, y in zip(icon_color(candidate), target))
        if best is None or distance < best[0]:
            best = (distance, candidate)
        if distance < 18**2:
            break
    return best[1]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: seed.py <data folder>")
    tree = pathlib.Path(sys.argv[1]) / "Caches/apps/synthetic-apps"
    applications = tree / "Applications"
    for folder in (applications, tree / "System/Applications", tree / "Extensions"):
        folder.mkdir(parents=True, exist_ok=True)
    for name, target in tile_colors():
        plist = applications / f"{name}.app/Contents/Info.plist"
        plist.parent.mkdir(parents=True, exist_ok=True)
        info = {"CFBundlePackageType": "APPL", "CFBundleIdentifier": bundle_id(name, target)}
        plist.write_bytes(plistlib.dumps(info))
        color = "#%02x%02x%02x" % icon_color(info["CFBundleIdentifier"])
        print(f"seed: {name}: {info['CFBundleIdentifier']} draws {color}")
    # The Apps feature writes its own tree only while this file is missing.
    (tree / "tree-version").write_text("1")


if __name__ == "__main__":
    main()
