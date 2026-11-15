#!/bin/bash
# Regenerates the product pictures in site/media from LauncherUI's showcase mode: the real panel
# drawn by the package over a generated wallpaper, captured through ScreenCaptureKit, then
# converted to untagged sRGB PNGs with a manifest and a contact sheet.
#   scripts/ui-showcase.sh [shots=hero,theme-ocean] [tones=dark,light] [idle=15]
#
# Captures wait for 15 s without keyboard or mouse input before each batch, give up after
# 30 minutes, hold key status for about a quarter of a second each, and sit in the bottom-left
# corner of the main screen. Pictures not captured in this run are kept as they are, so one shot
# can be redone alone. The demo gets the purple system accent through its own argument domain;
# nothing outside that process changes.
#
# Env:
#   UI_SHOWCASE_MEDIA  where the pictures go (default site/media)
#   UI_SHOWCASE_WORK   raw captures and the contact sheet (default build/ui-showcase)
#   UI_DEMO_TIMEOUT    seconds before giving up (default 2100)
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
MEDIA=${UI_SHOWCASE_MEDIA:-$ROOT/site/media}
WORK=${UI_SHOWCASE_WORK:-$ROOT/build/ui-showcase}
RAW="$WORK/raw"
rm -rf "$RAW"
mkdir -p "$RAW"

UI_DEMO_OUT="$RAW" UI_DEMO_TIMEOUT=${UI_DEMO_TIMEOUT:-2100} "$ROOT/scripts/ui-demo.sh" showcase "$@" \
    -AppleAccentColor 5

python3 -I - "$RAW" "$MEDIA" "$WORK/contact-sheet.png" << 'PY'
"""Turns raw showcase captures into publishable files.

For each capture: converts from the display's colour profile to sRGB, drops alpha, the device
profile and EXIF, and saves an optimized PNG. Fails when a file is over the size limit. Then
rewrites manifest.json for every picture in the folder and draws a contact sheet.
"""

import io
import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFont

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
        "right, the selected file, Atlas launch plan.md, is shown as formatted Markdown with "
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


def main() -> None:
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

    manifest = {
        "about": (
            f"Product pictures of {NAME} for the website and the README. Each was captured from "
            "the launcher's own interface code drawing a made-up sample catalog over a wallpaper "
            "generated in code, at 2x on a Retina display, by scripts/ui-showcase.sh. None shows "
            "the finished app or anyone's real apps."
        ),
        "files": entries,
    }
    (media / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

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
    print(f"showcase OK: {made} new, {len(entries)} in the manifest")


if __name__ == "__main__":
    main()
PY
