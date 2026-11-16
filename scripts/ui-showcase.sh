#!/bin/bash
# Regenerates the product pictures in site/media from LauncherUI's showcase mode: the real panel
# drawn by the package over a generated wallpaper, captured through ScreenCaptureKit, then
# converted to untagged sRGB PNGs with a manifest and a contact sheet.
#   scripts/ui-showcase.sh [shots=hero,theme-ocean] [tones=dark,light] [idle=15]
#
# Captures wait for 15 s without keyboard or mouse input before each batch, give up after
# 30 minutes, hold key status for about a quarter of a second each, and sit in the bottom-left
# corner of the main screen. Pictures not captured in this run are kept as they are, so one shot
# can be redone alone. scripts/ui-showcase.py writes the pictures' entries into the manifest and
# keeps the entries of the clips and stills that make media wrote, with the manifest's about text.
# The demo gets the purple system accent through its own argument domain; nothing outside that
# process changes.
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

python3 -I "$ROOT/scripts/ui-showcase.py" "$RAW" "$MEDIA" "$WORK/contact-sheet.png"
