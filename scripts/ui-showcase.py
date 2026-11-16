#!/usr/bin/env python3
"""Turns raw showcase captures into publishable files.

    python3 -I scripts/ui-showcase.py <raw folder> <media folder> <contact sheet>
    python3 -I scripts/ui-showcase.py --shots     prints the file name of every shot

scripts/ui-showcase.sh runs it after the captures, with BRAND_NAME in the environment from
scripts/lib/env.sh. For each capture: converts from the display's
colour profile to sRGB, drops alpha, the device profile and EXIF, and saves an optimized PNG. Fails
when a file is over the size limit. Then writes the showcase's entries into manifest.json and draws
a contact sheet.

The manifest is shared. scenarios/media/publish.py writes the entries of the clips and of the
settings window's stills, which carry a "clip" or a "still" key, and the "about" text that covers
them. This script replaces only the entries without either key, keeps every other entry and the
about text, and orders the entries as publish.py does: pictures, then stills, then clips.
"""

from __future__ import annotations

import io
import json
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageCms, ImageDraw, ImageFont
except ImportError:
    # Listing the shots and merging the manifest need no Pillow, so scripts/test-scripts.sh can
    # check them anywhere. Publishing pictures does.
    Image = ImageCms = ImageDraw = ImageFont = None

NAME = os.environ["BRAND_NAME"]
LIMIT = 900_000
SAMPLE = (
    f"The apps, files and names are made-up sample data. The picture comes from {NAME}'s "
    "interface code running on its own, not from the finished app."
)

# file, appearance, caption, alt (before the sample-data sentence)
SHOTS = [
    (
        "hero-dark.png", "dark",
        "Two typed letters find the app, and the field completes its name.",
        f"{NAME}'s search panel in dark mode: a slab of dark glass over a purple gradient wallpaper. "
        "The query “ca” is typed and the rest of the top result's name, “dence Calendar”, "
        "shows in grey after the cursor. Eight results follow: six apps, a Markdown file and a "
        "note command. The first row, Cadence Calendar, is selected and tagged Running. The bar "
        "at the bottom shows Open Application on Return and Actions on Command-K.",
    ),
    (
        "hero-light.png", "light",
        "Two typed letters find the app, and the field completes its name.",
        f"{NAME}'s search panel in light mode: a slab of pale glass over a lavender gradient wallpaper. "
        "The query “ca” is typed and the rest of the top result's name, “dence Calendar”, "
        "shows in grey after the cursor. Eight results follow: six apps, a Markdown file and a "
        "note command. The first row, Cadence Calendar, is selected and tagged Running.",
    ),
    (
        "suggestions-dark.png", "dark",
        "Before you type, the panel lists suggestions and your favorites.",
        f"{NAME}'s search panel in dark mode with an empty search field. A Suggested section lists "
        "five apps, three of them tagged Running. A Favorites section lists four items with their "
        "hotkeys or aliases, such as Option-Command-A for Aurora Notes and the alias “todo” "
        "for Juniper Tasks. The first suggestion is selected.",
    ),
    (
        "suggestions-light.png", "light",
        "Before you type, the panel lists suggestions and your favorites.",
        f"{NAME}'s search panel in light mode with an empty search field. A Suggested section lists "
        "five apps, and a Favorites section lists four items with their hotkeys or aliases. The "
        "first suggestion is selected.",
    ),
    (
        "actions-dark.png", "dark",
        "Command-K opens the action panel for the selected result, with a shortcut beside each action.",
        f"{NAME}'s search panel in dark mode with the action panel open over the results for "
        "“ca”. The action panel has its own filter field and lists actions for Cadence "
        "Calendar in three groups: Open Application and Show in Finder; Add to Favorites, Set Alias "
        "and Set Hotkey; Copy Path, Hide Application and Force Quit, which is in red. Each action "
        "shows its keyboard shortcut. Add to Favorites is selected.",
    ),
    (
        "actions-light.png", "light",
        "Command-K opens the action panel for the selected result, with a shortcut beside each action.",
        f"{NAME}'s search panel in light mode with the action panel open over the results for "
        "“ca”. It lists actions for Cadence Calendar with their keyboard shortcuts, and "
        "Add to Favorites is selected.",
    ),
    (
        "detail-dark.png", "dark",
        "File results beside a preview of the selected note and its details.",
        f"{NAME}'s search panel in dark mode, inside a Search Files view with “plan” typed "
        "and a Kind filter set to All Kinds. On the left, six files and a folder match. On the "
        "right, the selected file, Sourdough plan.md, is shown as formatted Markdown with "
        "headings, a numbered list, bullet points and a code block. Under it, a table lists its "
        "kind, size, folder, tags and dates.",
    ),
    (
        "detail-light.png", "light",
        "File results beside a preview of the selected note and its details.",
        f"{NAME}'s search panel in light mode, inside a Search Files view with “plan” typed. "
        "A list of matching files sits beside a formatted Markdown preview of the selected note, "
        "with a table of its details underneath.",
    ),
    (
        "grid-dark.png", "dark",
        "A folder of pictures shown as a grid of thumbnails.",
        f"{NAME}'s search panel in dark mode showing a Pictures view as a grid of ten abstract "
        "wallpaper thumbnails in two rows of five, each titled with its file name and size. The "
        "third picture in the first row, Lagoon.png, is selected. The thumbnails were generated in code.",
    ),
    (
        "grid-light.png", "light",
        "A folder of pictures shown as a grid of thumbnails.",
        f"{NAME}'s search panel in light mode showing a Pictures view as a grid of ten abstract "
        "wallpaper thumbnails with their file names. The third one is selected. The thumbnails "
        "were generated in code.",
    ),
    (
        "form-dark.png", "dark",
        "A command asks for input in a form drawn inside the panel.",
        f"{NAME}'s search panel in dark mode showing a Create Note form for the sample app Aurora "
        "Notes. It has a title field with the cursor in it, a folder menu, tags, a multi-line note, "
        "a file path with a Choose button, a Pin checkbox and a hotkey set to Option-Command-N. "
        "The bar at the bottom shows Create Note on Command-Return.",
    ),
    (
        "form-light.png", "light",
        "A command asks for input in a form drawn inside the panel.",
        f"{NAME}'s search panel in light mode showing a Create Note form with a title, a folder "
        "menu, tags, a note, a file path, a checkbox and a hotkey field.",
    ),
    (
        "theme-standard.png", "dark",
        "Standard theme: the system accent color, purple here, on a glass selection lens.",
        "The search results for “ca” in the Standard theme, dark mode. The glass selection "
        "lens on the first row and the text cursor take the system accent color, which is purple "
        "in this picture.",
    ),
    (
        "theme-graphite.png", "dark",
        "Graphite theme: a neutral grey tint on the glass and a flat selection fill.",
        "The search results for “ca” in the Graphite theme, dark mode. The glass has a neutral "
        "grey tint, the first row is marked with a flat grey fill instead of a glass lens, and the "
        "text cursor is graphite grey.",
    ),
    (
        "theme-ocean.png", "dark",
        "Ocean theme: glass tinted blue-green with a rounder selection lens.",
        "The search results for “ca” in the Ocean theme, dark mode. The glass is tinted "
        "blue-green and the first row sits under a rounder glass lens. The text cursor takes the "
        "deep teal accent.",
    ),
    (
        "theme-ember.png", "dark",
        "Ember theme: warm glass and a wide selection fill drawn from its deep orange accent.",
        "The search results for “ca” in the Ember theme, dark mode. The glass is tinted "
        "warm brown, the first row sits on a wide, dark red-orange fill instead of a glass lens, "
        "and the text cursor takes the orange accent.",
    ),
    (
        "theme-violet.png", "dark",
        "Violet theme: ink-dark glass, a magenta-tinted lens and the app icon's electric violet.",
        "The search results for “ca” in the Violet theme, dark mode. The glass is tinted a "
        "deep ink purple, the first row sits under a glass lens tinted magenta, and the text "
        "cursor takes the electric violet accent from the app icon.",
    ),
]


def to_srgb(image: Image.Image) -> Image.Image:
    profile = image.info.get("icc_profile")
    rgb = image.convert("RGBA") if image.mode != "RGBA" else image
    if rgb.getchannel("A").getextrema() != (255, 255):
        raise SystemExit("capture has transparent pixels; the backdrop did not cover it")
    rgb = rgb.convert("RGB")
    if profile:
        source = ImageCms.ImageCmsProfile(io.BytesIO(profile))
        target = ImageCms.createProfile("sRGB")
        rgb = ImageCms.profileToProfile(
            rgb, source, target, renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC, outputMode="RGB"
        )
    # Untagged PNG is read as sRGB everywhere. The generated profile carries a creation date,
    # so keeping it would also make every run's bytes differ.
    rgb.info.pop("icc_profile", None)
    rgb.info.pop("exif", None)
    return rgb


ABOUT = (
    f"Product pictures of {NAME} for the website and the README. Each was captured from "
    "the launcher's own interface code drawing a made-up sample catalog over a wallpaper "
    "generated in code, at 2x on a Retina display, by scripts/ui-showcase.sh. None shows "
    "the finished app or anyone's real apps."
)


def merged_manifest(existing: dict | None, pictures: list[dict]) -> dict:
    """The manifest with this run's pictures in place of the old ones.

    Keeps the existing about text and every entry with a "clip" or a "still" key, which
    scenarios/media/publish.py wrote, in publish.py's order. Uses ABOUT when there is none yet.
    """
    existing = existing or {}
    names = {entry["file"] for entry in pictures}
    kept = [
        entry for entry in existing.get("files", [])
        if ("clip" in entry or "still" in entry) and entry["file"] not in names
    ]
    stills = sorted((e for e in kept if "still" in e), key=lambda e: (e["still"], e["file"]))
    clips = sorted((e for e in kept if "clip" in e and "still" not in e), key=lambda e: (e["clip"], e["file"]))
    return {"about": existing.get("about", ABOUT), "files": pictures + stills + clips}


def read_manifest(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    if sys.argv[1:] == ["--shots"]:
        print("\n".join(file for file, *_ in SHOTS))
        return
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    if Image is None:
        raise SystemExit("ui-showcase: Pillow is not installed. Install it with: python3 -m pip install Pillow")
    source, media, sheet_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    media.mkdir(parents=True, exist_ok=True)
    entries, problems, thumbs, made = [], [], [], 0
    for file, appearance, caption, alt in SHOTS:
        raw, out = source / file, media / file
        if raw.exists():
            image = to_srgb(Image.open(raw))
            image.save(out, format="PNG", optimize=True)
            made += 1
            print(f"{file}: new, {image.width}x{image.height}, {out.stat().st_size / 1000:.0f} KB")
        elif out.exists():
            image = Image.open(out)
            image.load()
        else:
            problems.append(f"{file}: no capture and no earlier picture")
            continue
        size = out.stat().st_size
        if size > LIMIT:
            problems.append(f"{file}: {size} bytes, over {LIMIT}")
        entries.append(
            {
                "file": file,
                "width": image.width,
                "height": image.height,
                "appearance": appearance,
                "caption": caption,
                "alt": f"{alt} {SAMPLE}",
            }
        )
        thumbs.append((file, size, image))

    manifest_path = media / "manifest.json"
    manifest = merged_manifest(read_manifest(manifest_path), entries)
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    if thumbs:
        columns, scale, pad, label = 4, 0.25, 24, 34
        tw = max(int(i.width * scale) for _, _, i in thumbs)
        th = max(int(i.height * scale) for _, _, i in thumbs)
        rows = (len(thumbs) + columns - 1) // columns
        title = 64
        sheet = Image.new("RGB", (pad + columns * (tw + pad), title + rows * (th + label + pad) + pad), (52, 52, 58))
        draw = ImageDraw.Draw(sheet)
        font = ImageFont.load_default(size=20)
        big = ImageFont.load_default(size=30)
        draw.text((pad, 18), f"{NAME} product pictures in site/media, sample catalog drawn by the interface code", fill="white", font=big)
        for index, (file, size, image) in enumerate(thumbs):
            x = pad + (index % columns) * (tw + pad)
            y = title + (index // columns) * (th + label + pad)
            sheet.paste(image.resize((int(image.width * scale), int(image.height * scale)), Image.LANCZOS), (x, y))
            draw.text((x, y + th + 6), f"{file}  {image.width}x{image.height}  {size / 1000:.0f} KB", fill="white", font=font)
        sheet_path.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(sheet_path, optimize=True)
        print(f"contact sheet: {sheet_path}")

    if problems:
        print("PROBLEMS:\n  " + "\n  ".join(problems))
        raise SystemExit(1)
    kept = len(manifest["files"]) - len(entries)
    print(f"showcase OK: {made} new, {len(entries)} pictures and {kept} clip and still entries in the manifest")


if __name__ == "__main__":
    main()
