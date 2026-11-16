#!/bin/bash
# Writes the app's Info.plist from the template support/Info.plist.in and the values in
# support/brand.env.
#   scripts/info-plist.sh <output path>
#
# Env: VERSION and BUILD_NUMBER set CFBundleShortVersionString and CFBundleVersion.
#      UPDATE_FEED_URL, when set, is written as SUFeedURL, the address of the update feed.
#      scripts/bundle.sh sets it only for release packaging, so a build from source never offers to
#      replace itself with a release.
# BRAND_UPDATE_PUBLIC_KEY in support/brand.env, when set, is written as SUPublicEDKey. The app makes
# Sparkle's updater only from a bundle that carries both. UPDATE_PUBLIC_KEY, when set, takes the
# key's place, for tests; scripts/check-release.sh requires brand.env's key in a release.
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
if [ -n "${UPDATE_FEED_URL:-}" ]; then
    plutil -insert SUFeedURL -string "$UPDATE_FEED_URL" "$TMP"
fi
PUBLIC_KEY=${UPDATE_PUBLIC_KEY-${BRAND_UPDATE_PUBLIC_KEY:-}}
if [ -n "$PUBLIC_KEY" ]; then
    plutil -insert SUPublicEDKey -string "$PUBLIC_KEY" "$TMP"
fi
mv -f "$TMP" "$OUT"
