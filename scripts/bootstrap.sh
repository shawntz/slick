#!/bin/bash
# Checks the toolchains, builds the Rust core and resolves every Swift package.
#   scripts/bootstrap.sh
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
fail() {
    echo "[bootstrap] $*" >&2
    exit 1
}

# Building needs the macOS 27 SDK, so Xcode 27, even though the app runs on macOS 26.
WANT_XCODE=$(cat "$ROOT/.xcode-version")
XCODE=$(xcodebuild -version 2> /dev/null | awk 'NR == 1 {print $2}')
[ -n "$XCODE" ] || fail "Xcode not found. Install Xcode $WANT_XCODE and select it with xcode-select."
[ "${XCODE%%.*}" -ge "${WANT_XCODE%%.*}" ] || fail "Xcode $XCODE is too old. Building needs Xcode $WANT_XCODE."
SDK=$(xcrun --sdk macosx --show-sdk-version)
[ "${SDK%%.*}" -ge 27 ] || fail "macOS SDK $SDK is too old. Building needs the macOS 27 SDK."
echo "[bootstrap] Xcode $XCODE, macOS SDK $SDK, $(swift --version 2> /dev/null | grep -o 'Swift version [0-9.]*')"

# rustup installs the toolchain pinned in rust-toolchain.toml on first use if it is missing.
echo "[bootstrap] $("$ROOT/scripts/cargo.sh" --version)"
command -v xcodegen > /dev/null || echo "[bootstrap] xcodegen not found. It is optional: only 'make xcode' uses it."

"$ROOT/scripts/build-rust.sh" release

for manifest in "$ROOT"/Packages/*/Package.swift "$ROOT"/Packages/Features/*/Package.swift; do
    [ -f "$manifest" ] || continue
    "$ROOT/scripts/swiftpm.sh" "$(dirname "$manifest")" package resolve
done
echo "[bootstrap] OK"
