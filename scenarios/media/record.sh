#!/bin/bash
# Records the storyboards in scenarios/media with the real launcher, then publishes the clips to
# site/media. `make media` runs it.
#   scenarios/media/record.sh [only=hero-dark,actions-dark] [idle=120] [budget=5400] [attempts=3] [publish=1]
#
# 1. Builds the app with SCENARIO_RECORDING=1 in build/media/swiftpm, so the scenario runner has its
#    recorder, and bundles it as build/media/<name>.app. The release app in build/ is not touched.
# 2. For each storyboard: waits until nobody has touched the Mac for `idle` seconds, and runs it
#    through LaunchServices with a fresh data folder. Every storyboard sets "systemApps", so the
#    panel lists Apple's own apps from /System/Applications with their real icons. A clip holds
#    key status for its whole length, so the recorder throws it out the moment input arrives; then
#    this script waits for the next idle moment and tries again, up to `attempts` times. It gives up
#    waiting once `budget` seconds have passed since it started.
# 3. publish.py copies each clip's MP4, GIF and poster into site/media and rewrites their entries in
#    site/media/manifest.json, then check.py checks the whole manifest. publish=0 skips both.
#
# The app gets the purple accent in its own argument domain, as the stills did. The Mac's own
# setting is not read or changed. Results go to build/media/out/<storyboard>.
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib/env.sh"
HERE="$ROOT/scenarios/media"
OUT="$ROOT/build/media"
ONLY="" IDLE=120 BUDGET=5400 ATTEMPTS=3 PUBLISH=1
for argument in "$@"; do
    case $argument in
        only=*) ONLY=${argument#only=} ;;
        idle=*) IDLE=${argument#idle=} ;;
        budget=*) BUDGET=${argument#budget=} ;;
        attempts=*) ATTEMPTS=${argument#attempts=} ;;
        publish=*) PUBLISH=${argument#publish=} ;;
        *) echo "usage: record.sh [only=a,b] [idle=120] [budget=5400] [attempts=3] [publish=1]" >&2; exit 2 ;;
    esac
done
# SwiftPM's name for the executable, as the Makefile has it; bundle.sh renames it from brand.env.
EXECUTABLE=${EXECUTABLE:-$(sed -n 's/^EXECUTABLE := //p' "$ROOT/Makefile")}
log() { printf '[media] %s\n' "$*" >&2; }
# awk reads to the end: with pipefail, an early exit would end ioreg with SIGPIPE and fail the read.
idle_seconds() {
    ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !seen {v = int($NF / 1000000000); seen = 1} END {print v + 0}'
}

log "building the app with the scenario recorder"
SCENARIO_RECORDING=1 SWIFT_FLAGS="${SWIFT_FLAGS:-} --scratch-path $OUT/swiftpm" \
    "$ROOT/scripts/swiftpm.sh" "$ROOT/Packages/App" build -c release --product "$EXECUTABLE"
BIN=$(SCENARIO_RECORDING=1 SWIFT_FLAGS="--scratch-path $OUT/swiftpm" \
    "$ROOT/scripts/swiftpm.sh" "$ROOT/Packages/App" build -c release --show-bin-path)
APP=$(STRIP=0 "$ROOT/scripts/bundle.sh" "$BIN/$EXECUTABLE" "$OUT" release)

started=$(date +%s)
failed=()
recorded=()
for file in "$HERE"/*.json; do
    name=$(basename "$file" .json)
    if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; then continue; fi
    attempt=0
    while :; do
        attempt=$((attempt + 1))
        # Wait for an idle Mac, within the budget.
        while idle=$(idle_seconds); [ "$idle" -lt "$IDLE" ]; do
            if [ $(($(date +%s) - started)) -ge "$BUDGET" ]; then
                log "$name: no idle moment of $IDLE s within $BUDGET s; not recorded"
                failed+=("$name (no idle moment)")
                continue 3
            fi
            sleep 10
        done
        data="$OUT/data/$name"
        rm -rf "$data" "$OUT/out/$name"
        mkdir -p "$OUT/out/$name"
        log "$name: take $attempt after $idle s idle"
        status=0
        LAUNCH_TIMEOUT=200 "$ROOT/scripts/launch.sh" "$APP" scenario --scenario "$file" \
            --output "$OUT/out/$name" --data-dir "$data" -AppleAccentColor 5 \
            > "$OUT/out/$name.log" 2>&1 || status=$?
        rm -rf "$data"
        if [ "$status" = 0 ]; then
            log "$name: recorded"
            recorded+=("$name")
            break
        fi
        reason=$(grep -E '^scenario FAIL' "$OUT/out/$name.log" | tail -1 || true)
        log "$name: ${reason:-no verdict, see $OUT/out/$name.log}"
        if [[ "$reason" == *"input arrived"* || "$reason" == *"idle for"* ]] && [ "$attempt" -lt "$ATTEMPTS" ]; then
            continue
        fi
        failed+=("$name")
        break
    done
done
if pgrep -f "^$APP/Contents/MacOS/" > /dev/null; then pkill -f "^$APP/Contents/MacOS/" || true; fi

if [ "$PUBLISH" = 1 ] && [ ${#recorded[@]} -gt 0 ]; then
    python3 -I "$HERE/publish.py" "$OUT/out" "${recorded[@]}"
    python3 -I "$HERE/check.py"
fi
log "recorded: ${recorded[*]:-none}"
if [ ${#failed[@]} -gt 0 ]; then
    log "not recorded: ${failed[*]}"
    exit 1
fi
