#!/bin/bash
# Runs SwiftPM for one package with that package's own build directory and a manifest cache kept
# inside it, so two packages never share a lock or a cache.
#   scripts/swiftpm.sh <package dir> <build|test|run|package> [arguments...]
#
# Env: SWIFT_FLAGS adds words to every call, for example "-Xswiftc -warnings-as-errors" in CI.
set -euo pipefail
USAGE="usage: swiftpm.sh <package dir> <build|test|run|package> [arguments...]"
DIR=$(cd "${1:?$USAGE}" && pwd)
SUBCOMMAND=${2:?$USAGE}
shift 2
# SWIFT_FLAGS is deliberately split into words.
# shellcheck disable=SC2086
exec swift "$SUBCOMMAND" --package-path "$DIR" --scratch-path "$DIR/.build" --manifest-cache local \
    ${SWIFT_FLAGS:-} "$@"
