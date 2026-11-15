#!/bin/bash
# Builds the Rust core as one static library and installs it, with its generated C header, into
# the CoreBridge package.
#   scripts/build-rust.sh [release|dev]
#
# A file is installed only when its content changed, so a no-op Rust build never invalidates a Swift
# build. Each file is written under a temporary name and then renamed into place, so a Swift link
# running at the same moment sees the old file or the new one, never half of one.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
PROFILE=${1:-release}

"$ROOT/scripts/cargo.sh" build --locked --profile "$PROFILE" -p slick-ffi --features header

install_atomically() { # <source> <destination>
    local src=$1 dst=$2 tmp
    cmp -s "$src" "$dst" && return 0
    mkdir -p "$(dirname "$dst")"
    tmp="$dst.partial.$$"
    cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dst"
    echo "[build-rust] installed ${dst#"$ROOT"/}"
}

OUT_DIR=$PROFILE
[ "$PROFILE" = dev ] && OUT_DIR=debug
install_atomically "$ROOT/core/target/$OUT_DIR/libslick_ffi.a" \
    "$ROOT/Packages/CoreBridge/Artifacts/lib/libslick_ffi.a"
install_atomically "$ROOT/core/crates/slick-ffi/include/slick_core.h" \
    "$ROOT/Packages/CoreBridge/Sources/SlickCoreC/include/slick_core.h"
