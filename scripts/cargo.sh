#!/bin/bash
# Runs cargo in the core/ workspace with the pinned Rust toolchain.
#   scripts/cargo.sh <cargo arguments...>
#
# The pin lives in rust-toolchain.toml. When that exact version is not installed but the installed
# "stable" is the same version, stable is used, so the build does not download a second copy of the
# same compiler. Set RUSTUP_TOOLCHAIN to override.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"

pinned_toolchain() {
    local pin stable
    pin=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$ROOT/rust-toolchain.toml")
    if rustup toolchain list 2> /dev/null | grep -q "^$pin"; then
        echo "$pin"
        return
    fi
    stable=$(RUSTUP_TOOLCHAIN=stable rustc --version 2> /dev/null | awk '{print $2}')
    if [ "$stable" = "$pin" ]; then echo stable; else echo "$pin"; fi
}

command -v rustup > /dev/null || {
    echo "[cargo] rustup not found. Install it with 'brew install rustup' or from https://rustup.rs" >&2
    exit 1
}
RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-$(pinned_toolchain)}
export RUSTUP_TOOLCHAIN
cd "$ROOT/core"
exec cargo "$@"
