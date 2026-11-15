#!/bin/bash
# Writes the app's Info.plist from the template support/Info.plist.in and the values in
# support/brand.env.
#   scripts/info-plist.sh <output path>
#
# Env: VERSION and BUILD_NUMBER set CFBundleShortVersionString and CFBundleVersion.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
OUT=${1:?usage: info-plist.sh <output path>}
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.partial.$$"
sed -e "s|@BRAND_NAME@|$BRAND_NAME|g" \
    -e "s|@BRAND_BUNDLE_ID@|$BRAND_BUNDLE_ID|g" \
    -e "s|@BRAND_URL_SCHEME@|$BRAND_URL_SCHEME|g" \
    -e "s|@MIN_MACOS@|$MACOSX_DEPLOYMENT_TARGET|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@BUILD_NUMBER@|$BUILD_NUMBER|g" \
    "$ROOT/support/Info.plist.in" > "$TMP"
if grep -n '@[A-Z_]*@' "$TMP" >&2; then
    rm -f "$TMP"
    echo "[info-plist] unfilled token in support/Info.plist.in" >&2
    exit 1
fi
# Validates the result and drops the template's comment.
plutil -convert xml1 "$TMP"
mv -f "$TMP" "$OUT"
