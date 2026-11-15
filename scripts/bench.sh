#!/bin/bash
# Prints the latency tables, measured inside the app bundle launched through LaunchServices.
#   scripts/bench.sh <App.app> [bench name]
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
APP=${1:?usage: bench.sh <App.app> [bench name]}
shift
exec "$ROOT/scripts/launch.sh" "$APP" bench --bench "$@"
