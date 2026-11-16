#!/usr/bin/env python3
"""Checks site/media/manifest.json against the files beside it and the storyboards in scenarios/media.

    python3 -I scenarios/media/check.py

It fails when a manifest entry names a missing file or has no alt text or caption, when a text has a
dash or a parenthesis, when a clip is over its budget, or when a storyboard's clip or still is not in
the manifest, as happens when a tool rewrites the manifest with only its own pictures.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MEDIA = ROOT / "site/media"
STORYBOARDS = ROOT / "scenarios/media"
WEB_MAX = 3_000_000
GIF_MAX = 6_000_000
GIF_MIN_WIDTH = 900
# An em dash, an en dash, a spaced hyphen or a parenthesis. Hyphenated words such as Command-K pass.
BANNED = re.compile(r"[—–()]| - ")


def problems():
    manifest = json.loads((MEDIA / "manifest.json").read_text(encoding="utf-8"))
    entries = {entry["file"]: entry for entry in manifest["files"]}
    found = []
    for name, entry in entries.items():
        path = MEDIA / name
        if not path.is_file():
            found.append(f"{name}: no such file")
            continue
        for key in ("alt", "caption"):
            text = entry.get(key) or ""
            if not text.strip():
                found.append(f"{name}: no {key}")
            elif BANNED.search(text):
                found.append(f"{name}: {key} has a dash or a parenthesis")
        size = path.stat().st_size
        if name.endswith(".mp4") and size > WEB_MAX:
            found.append(f"{name}: {size} bytes, over {WEB_MAX}")
        if name.endswith(".gif") and (size > GIF_MAX or entry.get("width", 0) < GIF_MIN_WIDTH):
            found.append(f"{name}: {size} bytes and {entry.get('width')} px wide")
        for key in ("clip", "still"):
            if key in entry and not (ROOT / entry[key]).is_file():
                found.append(f"{name}: its storyboard {entry[key]} is missing")
    for storyboard in sorted(STORYBOARDS.glob("*.json")):
        media = json.loads(storyboard.read_text(encoding="utf-8")).get("media") or {}
        wanted = [still["file"] for still in media.get("stills") or []]
        if media.get("file") and media.get("clip") is not False:
            stem = media["file"]
            wanted += [f"{stem}.mp4", f"{stem}.gif", f"{stem}-poster.png"]
        found += [f"{storyboard.name}: {file} is not in the manifest" for file in wanted if file not in entries]
    return found


def main():
    found = problems()
    for problem in found:
        print(f"media check: {problem}", file=sys.stderr)
    if found:
        sys.exit(1)
    print("media check: OK")


if __name__ == "__main__":
    main()
