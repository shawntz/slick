#!/usr/bin/env python3
"""Copies recorded clips into site/media and writes their entries in site/media/manifest.json.

    python3 -I scenarios/media/publish.py <results folder> <storyboard name>...

Each storyboard in scenarios/media names its files, appearance, caption and alt text in its
"media" object. The recorder wrote <file>.mp4, <file>.gif, <file>-poster.png and <file>.json in
<results folder>/<storyboard name>/clips. This script checks the budgets (the MP4 at most 3 MB, the
GIF at most 6 MB and at least 900 pixels wide), copies the three files, saves the poster as an
optimized PNG without colour profile or metadata, and replaces the manifest entries that came from
the same storyboard. Clip entries follow the stills, so a GIF never takes a still's place on the
site, and each carries "clip" with the path of its storyboard.

A storyboard may also list "stills": pictures its `still` steps wrote to
<results folder>/<storyboard name>/captures/<capture>.png, each with its own file, caption and alt
text, and an optional "crop" box in pixels. Their entries carry "still" with the path of the
storyboard. With "clip": false the clip itself is not published, as for the settings window,
where only the stills are wanted.
"""
import json
import pathlib
import shutil
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
MEDIA = ROOT / "site/media"
MANIFEST = MEDIA / "manifest.json"
WEB_MAX = 3_000_000
GIF_MAX = 6_000_000
GIF_MIN_WIDTH = 900


def fail(message):
    sys.exit(f"publish: {message}")


def save_png(source, target, crop=None):
    """An optimized PNG without alpha, colour profile or metadata, cut to `crop`, a box in pixels
    as left, top, right and bottom, when one is given."""
    with Image.open(source) as image:
        picture = image.convert("RGB")
        if crop:
            picture = picture.crop(tuple(crop))
        picture.save(target, optimize=True)


def still_entries(results, name, media):
    source = f"scenarios/media/{name}.json"
    entries = []
    for still in media.get("stills") or []:
        for key in ("capture", "file", "caption", "alt"):
            if not still.get(key):
                fail(f"{name}.json has a still without {key}")
        capture = results / name / "captures" / f"{still['capture']}.png"
        if not capture.exists():
            fail(f"{capture} was not written")
        save_png(capture, MEDIA / still["file"], still.get("crop"))
        with Image.open(MEDIA / still["file"]) as image:
            width, height = image.size
        entries.append({"file": still["file"], "width": width, "height": height,
                        "appearance": media["appearance"], "caption": still["caption"], "still": source,
                        "alt": still["alt"]})
    return entries


def entries_for(results, name):
    storyboard = ROOT / "scenarios/media" / f"{name}.json"
    media = json.loads(storyboard.read_text(encoding="utf-8")).get("media") or {}
    if not media.get("appearance"):
        fail(f"{storyboard.name} has no media.appearance")
    stills = still_entries(results, name, media)
    if media.get("clip") is False:
        return stills
    for key in ("file", "caption", "alt", "gifAlt", "posterAlt"):
        if not media.get(key):
            fail(f"{storyboard.name} has no media.{key}")
    stem = media["file"]
    clips = results / name / "clips"
    report = json.loads((clips / f"{stem}.json").read_text(encoding="utf-8"))
    web, gif, poster = (report["files"][kind] for kind in ("web", "gif", "poster"))
    if web["bytes"] > WEB_MAX:
        fail(f"{web['file']} is {web['bytes']} bytes, over {WEB_MAX}")
    if gif["bytes"] > GIF_MAX or gif["width"] < GIF_MIN_WIDTH:
        fail(f"{gif['file']} is {gif['bytes']} bytes and {gif['width']} px wide")

    shutil.copyfile(clips / web["file"], MEDIA / web["file"])
    shutil.copyfile(clips / gif["file"], MEDIA / gif["file"])
    save_png(clips / poster["file"], MEDIA / poster["file"])

    source = f"scenarios/media/{name}.json"
    seconds = round(report["seconds"], 2)
    common = {"appearance": media["appearance"], "caption": media["caption"], "clip": source}
    return stills + [
        {"file": web["file"], "poster": poster["file"], "width": web["width"], "height": web["height"],
         "seconds": seconds, **common, "alt": media["alt"]},
        {"file": gif["file"], "width": gif["width"], "height": gif["height"], "seconds": seconds, **common,
         "alt": media["gifAlt"]},
        {"file": poster["file"], "width": poster["width"], "height": poster["height"], **common,
         "alt": media["posterAlt"]},
    ]


def main():
    if len(sys.argv) < 3:
        fail("usage: publish.py <results folder> <storyboard name>...")
    results = pathlib.Path(sys.argv[1])
    names = sys.argv[2:]
    new = [entry for name in names for entry in entries_for(results, name)]
    sources = {f"scenarios/media/{name}.json" for name in names}
    files = {entry["file"] for entry in new}
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    kept = [
        e for e in manifest["files"]
        if e.get("clip") not in sources and e.get("still") not in sources and e["file"] not in files
    ]
    every = kept + new
    pictures = [e for e in every if "clip" not in e and "still" not in e]
    stills = sorted((e for e in every if "still" in e), key=lambda e: (e["still"], e["file"]))
    clips = sorted((e for e in every if "clip" in e), key=lambda e: (e["clip"], e["file"]))
    manifest["files"] = pictures + stills + clips
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for entry in new:
        size = (MEDIA / entry["file"]).stat().st_size
        print(f"publish: {entry['file']} {entry['width']}x{entry['height']} {size} bytes")


if __name__ == "__main__":
    main()
