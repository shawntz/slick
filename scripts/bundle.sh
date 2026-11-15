#!/bin/bash
# Assembles and signs the app bundle around the executable that SwiftPM built.
#   scripts/bundle.sh <executable> <output dir> [debug|release]
# Prints the path of the bundle on stdout and progress on stderr.
#
# Env:
#   SIGN_IDENTITY  "-" forces ad hoc signing. A SHA-1 hash or an identity name forces that identity.
#                  Unset: the first Apple Development identity in the keychain, else ad hoc.
#   STRIP          1 writes <output dir>/<name>.app.dSYM, then strips every symbol the executable
#                  does not need to run. 0 keeps the symbols in the executable. Default: 1 for
#                  release, 0 for debug. A stripped build symbolicates through the dSYM beside it.
#   VERSION, BUILD_NUMBER  passed on to scripts/info-plist.sh.
#
# A stable signing identity matters during development: macOS keeps permission grants such as
# Accessibility only while each new build satisfies the designated requirement of the old one. An
# Apple Development signature does; an ad hoc signature never does.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
BIN=${1:?usage: bundle.sh <executable> <output dir> [debug|release]}
OUT=${2:?usage: bundle.sh <executable> <output dir> [debug|release]}
CONFIG=${3:-release}
APP="$OUT/$APP_BUNDLE"
log() { printf '[bundle] %s\n' "$*" >&2; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BRAND_NAME"
"$ROOT/scripts/info-plist.sh" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon: compile the Icon Composer document into Assets.car and AppIcon.icns. actool takes about two
# seconds, so the output is cached by a hash of the source.
ICON_SRC="$ROOT/support/AppIcon.icon"
ICON_HASH=$(cd "$ICON_SRC" && find . -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16)
ICON_DIR="$ROOT/build/icon-cache/$ICON_HASH"
if [ ! -f "$ICON_DIR/Assets.car" ]; then
    rm -rf "$ROOT/build/icon-cache" && mkdir -p "$ICON_DIR"
    xcrun actool "$ICON_SRC" --compile "$ICON_DIR" --platform macosx \
        --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" --app-icon AppIcon \
        --output-partial-info-plist "$ICON_DIR/partial.plist" > /dev/null
fi
cp "$ICON_DIR/Assets.car" "$ICON_DIR/AppIcon.icns" "$APP/Contents/Resources/"

# Release builds move their symbols into a dSYM beside the bundle, which halves the executable.
# Debug builds keep them in place. Instruments and crash reports find the dSYM by its UUID.
STRIP=${STRIP:-$([ "$CONFIG" = release ] && echo 1 || echo 0)}
rm -rf "$OUT/$APP_BUNDLE.dSYM"
if [ "$STRIP" = 1 ]; then
    dsymutil "$APP/Contents/MacOS/$BRAND_NAME" -o "$OUT/$APP_BUNDLE.dSYM"
    strip -no_code_signature_warning "$APP/Contents/MacOS/$BRAND_NAME"
    log "symbols moved to $APP_BUNDLE.dSYM"
fi

if [ "$CONFIG" = debug ]; then
    ENTITLEMENTS="$ROOT/support/debug.entitlements"
else
    ENTITLEMENTS="$ROOT/support/release.entitlements"
fi
IDENTITY=${SIGN_IDENTITY:-}
KIND="explicit identity"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2> /dev/null | awk '/"Apple Development/ {print $2; exit}')
    KIND="Apple Development"
    if [ -z "$IDENTITY" ]; then
        IDENTITY="-"
        KIND="ad hoc (no Apple Development identity found)"
    fi
fi
[ "$IDENTITY" = "-" ] && KIND="ad hoc"

sign() { # <identity>
    # The timeout guards against a keychain access prompt, which would otherwise wait forever.
    timeout 20 codesign --force --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" --sign "$1" "$APP"
}
if ! sign "$IDENTITY" 2> "$OUT/codesign.log"; then
    log "signing with $KIND failed or took over 20 s (see $OUT/codesign.log); signing ad hoc instead"
    KIND="ad hoc (fallback)"
    sign - 2>> "$OUT/codesign.log"
fi
log "signed: $KIND, entitlements: $(basename "$ENTITLEMENTS")"
codesign --verify --strict "$APP"
echo "$APP"
