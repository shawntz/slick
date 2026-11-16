#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Assembles and signs the app bundle around the executable that SwiftPM built: Info.plist, the
# icon, THIRD-PARTY-NOTICES.md in Resources, and Sparkle.framework in Frameworks.
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
#   UPDATE_FEED    1 writes the update feed into Info.plist as SUFeedURL. Only release packaging sets
#                  it, as scripts/release.sh does. A build from source has no feed, so it never
#                  offers to replace itself with the latest release.
#   SPARKLE_ARTIFACTS  the folder of Sparkle's SwiftPM artifact, with Sparkle.xcframework in it.
#                  Default: found above the executable, in the SwiftPM build folder that made it.
#
# A stable signing identity matters during development: macOS keeps permission grants such as
# Accessibility only while each new build satisfies the designated requirement of the old one. An
# Apple Development signature does; an ad hoc signature never does.
#
# The framework and each helper inside it are signed with the app's identity, deepest first, then
# the app, all with the hardened runtime. Under the hardened runtime, library validation lets the
# app load only code with its own Team ID. Ad hoc code has none, so an ad hoc build also carries the
# entitlement com.apple.security.cs.disable-library-validation. scripts/lib/release.sh explains why.
# With library validation off, any ad hoc framework put in its place would load with the app's
# permission grants, so an ad hoc build is for tests and checks, not for daily use with
# Accessibility or Input Monitoring. The log line says so for every ad hoc build.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
LOG_TAG=bundle
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"
BIN=${1:?usage: bundle.sh <executable> <output dir> [debug|release]}
OUT=${2:?usage: bundle.sh <executable> <output dir> [debug|release]}
CONFIG=${3:-release}
APP="$OUT/$APP_BUNDLE"
EXE="$APP/Contents/MacOS/$BRAND_NAME"
log() { printf '[bundle] %s\n' "$*" >&2; }

SPARKLE=$(sparkle_artifacts "$BIN")
FRAMEWORK=$(sparkle_framework "$SPARKLE")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$EXE"
FEED=""
if [ "${UPDATE_FEED:-0}" = 1 ]; then
    FEED=$(update_feed_url)
fi
UPDATE_FEED_URL="$FEED" "$ROOT/scripts/info-plist.sh" "$APP/Contents/Info.plist"
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

# The licenses of the third-party code the app links travel with every bundle, before signing.
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"

# Sparkle.framework from the Updates package's SwiftPM artifact. ditto keeps its symbolic links,
# which the framework's signature covers. The App package's manifest gives the executable the
# runpath @executable_path/../Frameworks, so it finds the framework here.
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

# SwiftPM also records its own build folder as a runpath. It names a folder on the build machine,
# so it goes. Only runpaths that start with @ stay.
RPATHS=$(otool -l "$EXE" | awk '/cmd LC_RPATH/ {rpath = 1; next} rpath && $1 == "path" {print; rpath = 0}' \
    | sed -E 's/^ *path (.*) \(offset [0-9]+\)$/\1/')
while IFS= read -r rpath; do
    case $rpath in
        '' | @*) ;;
        *) install_name_tool -delete_rpath "$rpath" "$EXE" || { log "could not remove the runpath $rpath"; exit 1; } ;;
    esac
done <<< "$RPATHS"

# Release builds move their symbols into a dSYM beside the bundle, which halves the executable.
# Debug builds keep them in place. Instruments and crash reports find the dSYM by its UUID.
STRIP=${STRIP:-$([ "$CONFIG" = release ] && echo 1 || echo 0)}
rm -rf "$OUT/$APP_BUNDLE.dSYM"
if [ "$STRIP" = 1 ]; then
    dsymutil "$EXE" -o "$OUT/$APP_BUNDLE.dSYM"
    strip -no_code_signature_warning "$EXE"
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

SIGNING=$(mktemp -d "${TMPDIR:-/tmp}/bundle-sign.XXXXXX")
trap 'rm -rf "$SIGNING"' EXIT
# Signs every piece of nested code, deepest first, then the app with its entitlements. The timeout
# guards against a keychain access prompt, which would otherwise wait forever.
sign() { # <identity>
    local path entitlements nested
    entitlements=$(signing_entitlements "$1" "$ENTITLEMENTS" "$SIGNING/app.entitlements")
    nested=$(nested_code "$APP") || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        timeout 20 codesign --force --options runtime --timestamp=none --sign "$1" "$path" || return 1
    done <<< "$nested"
    timeout 20 codesign --force --options runtime --timestamp=none \
        --entitlements "$entitlements" --sign "$1" "$APP"
}
if ! sign "$IDENTITY" 2> "$OUT/codesign.log"; then
    log "signing with $KIND failed or took over 20 s (see $OUT/codesign.log); signing ad hoc instead, with library validation off"
    KIND="ad hoc (fallback)"
    IDENTITY="-"
    sign - 2>> "$OUT/codesign.log"
fi
VALIDATION="on"
if [ "$IDENTITY" = "-" ]; then
    VALIDATION="off, so give this build no Accessibility or Input Monitoring grant for daily use"
fi
log "signed: $KIND, entitlements: $(basename "$ENTITLEMENTS"), library validation: $VALIDATION, feed: ${FEED:-none}"
codesign --verify --strict --deep "$APP"
echo "$APP"
