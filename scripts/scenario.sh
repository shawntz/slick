#!/bin/bash
# Runs one scripted UI scenario inside the app bundle launched through LaunchServices.
#   scripts/scenario.sh <App.app> <scenario file>
#
# result.json and the captures go to build/scenarios/<file name without .json>. The scenario
# format is in docs/SCENARIOS.md.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
USAGE="usage: scenario.sh <App.app> <scenario file>"
APP=${1:?$USAGE}
FILE=${2:?$USAGE}
[ -f "$FILE" ] || { echo "[scenario] no such file: $FILE" >&2; exit 2; }
# LaunchServices starts the app in /, so every path must be absolute.
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
OUT="$ROOT/build/scenarios/$(basename "$FILE" .json)"
rm -rf "$OUT"
mkdir -p "$OUT"
LAUNCH_TIMEOUT=${LAUNCH_TIMEOUT:-200} exec "$ROOT/scripts/launch.sh" "$APP" scenario \
    --scenario "$FILE" --output "$OUT"
