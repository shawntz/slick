#!/bin/bash
# Runs the app bundle through LaunchServices in one of its non-interactive modes, waits for it to
# exit and prints what it wrote. Benchmarks and scenarios must run this way, because macOS
# schedules an app differently from a process started by a terminal.
#   scripts/launch.sh <App.app> <mode> [app arguments...]
#
# Every non-interactive mode ends by printing a verdict line, "<mode> PASS ..." or
# "<mode> FAIL ...". LaunchServices does not hand back the exit status, so this script succeeds
# only when the PASS line appears.
#
# The bundle is unregistered from LaunchServices after its run unless it is the copy the system
# should know, so the system knows one launcher: the copy make install put in INSTALL_DIR when
# there is one, and build/<name>.app when there is none. A copy in a mirror, the recording build
# in build/media, and build's copy while an installed copy exists are all unregistered.
#
# Env: LAUNCH_TIMEOUT is the number of seconds to wait before giving up (default 120).
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
. "$(dirname "$0")/lib/launchservices.sh"
USAGE="usage: launch.sh <App.app> <mode> [app arguments...]"
APP=$(cd "${1:?$USAGE}" && pwd)
MODE=${2:?$USAGE}
shift 2

mkdir -p "$ROOT/build"
OUTPUT=$(mktemp -d "$ROOT/build/launch.XXXXXX")
trap 'rm -rf "$OUTPUT"; unregister_unless_canonical "$APP"' EXIT
TIMEOUT=${LAUNCH_TIMEOUT:-120}
PROCESS="^$APP/Contents/MacOS/"

STATUS=0
# -g keeps the app in the background, so starting it never takes the keyboard from the person at
# the Mac. The launcher itself is never the active app either: its panel is non-activating.
timeout "$TIMEOUT" open -n -g -W --stdout "$OUTPUT/stdout" --stderr "$OUTPUT/stderr" "$APP" --args "$@" \
    2> "$OUTPUT/open" || STATUS=$?
if [ "$STATUS" != 0 ] && [ "$STATUS" != 124 ]; then
    # open cannot follow an app that exits within milliseconds of starting ("Unable to block on
    # application"). Wait for the process here instead.
    for _ in $(seq $((TIMEOUT * 10))); do
        pgrep -f "$PROCESS" > /dev/null || break
        sleep 0.1
    done
fi
if pgrep -f "$PROCESS" > /dev/null; then
    # Never leave the app running after this script.
    pkill -f "$PROCESS" || true
    echo "[launch] $MODE did not finish within $TIMEOUT s" >&2
fi
cat "$OUTPUT/stdout" 2> /dev/null || true
cat "$OUTPUT/stderr" >&2 2> /dev/null || true
if ! grep -q "^$MODE PASS" "$OUTPUT/stdout" 2> /dev/null; then
    cat "$OUTPUT/open" >&2
    echo "[launch] no '$MODE PASS' line from $(basename "$APP")" >&2
    exit 1
fi
