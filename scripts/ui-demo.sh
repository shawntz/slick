#!/bin/bash
# Builds LauncherUIDemo in release, wraps it in an LSUIElement app bundle, runs one mode through
# LaunchServices without taking focus, and prints what it wrote. Measurements must run this
# way: a process started from a terminal gets lower scheduling priority than an app.
#   scripts/ui-demo.sh <mode> [key=value ...]
#
# Modes: shots, components, legibility, vibrancy, bench, type, accessibility, showcase, record.
# Packages/LauncherUI/Sources/LauncherUIDemo/main.swift says what each one does.
#
# Env:
#   UI_DEMO_OUT      where captures and sheets go (default build/ui-demo)
#   UI_DEMO_TIMEOUT  seconds to wait before giving up (default 300)
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
USAGE="usage: ui-demo.sh <mode> [key=value ...]"
MODE=${1:?$USAGE}
shift
PACKAGE="$ROOT/Packages/LauncherUI"
SWIFTPM="$ROOT/scripts/swiftpm.sh"

"$SWIFTPM" "$PACKAGE" build -c release --product LauncherUIDemo > /dev/null
BIN="$("$SWIFTPM" "$PACKAGE" build -c release --show-bin-path)/LauncherUIDemo"
APP="$PACKAGE/.build/LauncherUIDemo.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LauncherUIDemo"
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LauncherUIDemo</string>
<key>CFBundleIdentifier</key><string>$BRAND_BUNDLE_ID.launcherui-demo</string>
<key>CFBundleName</key><string>LauncherUIDemo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>$MACOSX_DEPLOYMENT_TARGET</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad hoc: the demo needs no permission, and an ad hoc signature never touches the keychain.
timeout 20 codesign --force --sign - "$APP" > /dev/null 2>&1

OUT=${UI_DEMO_OUT:-$ROOT/build/ui-demo}
mkdir -p "$OUT"
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/ui-demo.XXXXXX")
trap 'rm -rf "$LOGS"' EXIT
TIMEOUT=${UI_DEMO_TIMEOUT:-300}
PROCESS="^$APP/Contents/MacOS/"

# -n: a new instance; -g: do not bring it forward; -W: wait for it to exit.
STATUS=0
timeout "$TIMEOUT" open -n -g -W --stdout "$LOGS/stdout" --stderr "$LOGS/stderr" "$APP" \
    --args "$MODE" "out=$OUT" "watchdog=$((TIMEOUT - 10))" "$@" 2> "$LOGS/open" || STATUS=$?
if [ "$STATUS" != 0 ] && [ "$STATUS" != 124 ]; then
    # open cannot follow an app that exits within milliseconds; wait for the process instead.
    for _ in $(seq $((TIMEOUT * 10))); do
        pgrep -f "$PROCESS" > /dev/null || break
        sleep 0.1
    done
fi
if pgrep -f "$PROCESS" > /dev/null; then
    pkill -f "$PROCESS" || true
    echo "[ui-demo] $MODE did not finish within $TIMEOUT s" >&2
fi
cat "$LOGS/stdout" 2> /dev/null || true
cat "$LOGS/stderr" >&2 2> /dev/null || true
if ! grep -q "^$MODE PASS" "$LOGS/stdout" 2> /dev/null; then
    cat "$LOGS/open" >&2
    echo "[ui-demo] no '$MODE PASS' line" >&2
    exit 1
fi
