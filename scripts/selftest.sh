#!/bin/bash
# Runs the app's selftest twice: as a plain process, which reports the real exit status, and through
# LaunchServices, which exercises the bundle itself (Info.plist, signature, LSUIElement). The
# selftest shows no window and takes no focus.
#   scripts/selftest.sh <App.app>
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
APP=${1:?usage: selftest.sh <App.app>}

check() { # <output>: the verdict line must pass and name the bundle from support/brand.env.
    grep -q "^selftest PASS .*bundle=$BRAND_BUNDLE_ID" <<< "$1" || {
        echo "[selftest] expected 'selftest PASS ... bundle=$BRAND_BUNDLE_ID'" >&2
        exit 1
    }
}

echo "[selftest] direct"
DIRECT=$(timeout 20 "$APP/Contents/MacOS/$BRAND_NAME" --selftest)
echo "$DIRECT"
check "$DIRECT"

echo "[selftest] LaunchServices"
LAUNCHED=$(LAUNCH_TIMEOUT=30 "$ROOT/scripts/launch.sh" "$APP" selftest --selftest)
echo "$LAUNCHED"
check "$LAUNCHED"
echo "[selftest] OK"
