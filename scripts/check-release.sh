#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Checks every artifact of a release folder that scripts/release.sh wrote.
#   scripts/check-release.sh <release dir>
#
# It unpacks the zip that ships, not the bundle it was made from, and checks:
# - the checksums in SHA256SUMS.txt and release.env
# - the zip holds exactly one bundle, whose signature passes strict verification, with the hardened
#   runtime on every piece of code and exactly the entitlements in support/release.entitlements
# - Info.plist carries the version, build number, bundle id and oldest macOS of the release
# - the executable's architectures, the third-party notices in Resources, and a dSYM whose UUIDs
#   match the executable
# - the cask renders, parses as Ruby and declares what scripts/check-cask.rb expects
# A real release must also carry a Developer ID signature with a secure timestamp, a stapled
# ticket, and pass Gatekeeper's assessment. A dry run must be signed ad hoc.
#
# It reads files and runs codesign, plutil, lipo, dwarfdump and ruby. It changes nothing in the
# release folder and makes no network request.
#
# Env: RUBY names the Ruby interpreter. Default: ruby on PATH.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"
LOG_TAG=check-release
DIR=${1:?usage: check-release.sh <release dir>}
DIR=$(cd "$DIR" && pwd) || fail "no release folder at $1"

read_release_env "$DIR/release.env"
for key in RELEASE_MODE RELEASE_VERSION RELEASE_BUILD_NUMBER RELEASE_ZIP RELEASE_DSYM_ZIP \
    RELEASE_SHA256 RELEASE_ARCHS RELEASE_MIN_MACOS; do
    [ -n "${!key:-}" ] || fail "$DIR/release.env has no $key."
done
case $RELEASE_MODE in
    release | dry-run) ;;
    *) fail "release.env names mode '$RELEASE_MODE'; expected release or dry-run." ;;
esac
RUBY=${RUBY:-ruby}
command -v "$RUBY" > /dev/null || fail "Ruby not found, and the cask check needs it. Install it or set RUBY."

TMP=$(temp_dir check-release)
trap 'rm -rf "$TMP"' EXIT
checked() {
    say "ok: $*"
}

# 1. Files and checksums.
for file in "$RELEASE_ZIP" "$RELEASE_DSYM_ZIP" SHA256SUMS.txt release-notes.md; do
    [ -s "$DIR/$file" ] || fail "$file is missing or empty in $DIR."
done
(cd "$DIR" && shasum -a 256 --check --status SHA256SUMS.txt) || fail "SHA256SUMS.txt does not match the files in $DIR."
SUMS=$(awk '{print $2}' "$DIR/SHA256SUMS.txt" | sort | tr '\n' ' ')
[ "$SUMS" = "$(printf '%s\n' "$RELEASE_ZIP" "$RELEASE_DSYM_ZIP" | sort | tr '\n' ' ')" ] \
    || fail "SHA256SUMS.txt should list exactly $RELEASE_ZIP and $RELEASE_DSYM_ZIP, and lists: $SUMS"
ACTUAL_SHA=$(shasum -a 256 "$DIR/$RELEASE_ZIP" | awk '{print $1}')
[ "$ACTUAL_SHA" = "$RELEASE_SHA256" ] || fail "release.env names SHA-256 $RELEASE_SHA256, but the zip's is $ACTUAL_SHA."
checked "checksums of $RELEASE_ZIP and $RELEASE_DSYM_ZIP"

# 2. The zip unpacks to one bundle with a valid signature.
mkdir "$TMP/app" "$TMP/dsym"
ditto -x -k "$DIR/$RELEASE_ZIP" "$TMP/app" || fail "$RELEASE_ZIP does not unpack."
ENTRIES=$(cd "$TMP/app" && ls -A)
[ "$ENTRIES" = "$APP_BUNDLE" ] || fail "$RELEASE_ZIP should hold only $APP_BUNDLE, and holds: $ENTRIES"
APP="$TMP/app/$APP_BUNDLE"
EXE="$APP/Contents/MacOS/$BRAND_NAME"
[ -f "$EXE" ] || fail "the bundle has no executable at Contents/MacOS/$BRAND_NAME."
codesign --verify --strict --deep --verbose=2 "$APP" 2> "$TMP/verify.log" \
    || { cat "$TMP/verify.log" >&2; fail "the unpacked bundle fails strict signature verification."; }
checked "strict signature verification of the unpacked bundle"

# Prints codesign's description of a signature.
signature() { # <path>
    codesign --display --verbose=4 "$1" 2>&1
}
SIG=$(signature "$APP")
grep -q '^CodeDirectory .*flags=.*runtime' <<< "$SIG" || fail "the bundle is signed without the hardened runtime."
if [ "$RELEASE_MODE" = release ]; then
    grep -q '^Authority=Developer ID Application: ' <<< "$SIG" || fail "the bundle is not signed with a Developer ID Application identity."
    grep -q '^Timestamp=' <<< "$SIG" || fail "the signature has no secure timestamp."
    checked "Developer ID signature with a secure timestamp"
else
    grep -q '^Signature=adhoc' <<< "$SIG" || fail "a dry run must be signed ad hoc, and this one is not."
    checked "ad hoc signature, as a dry run should have"
fi

# Every Mach-O file inside carries its own signature with the hardened runtime.
COUNT=0
while IFS= read -r -d '' file; do
    [[ $(file -b "$file") == Mach-O* ]] || continue
    grep -q '^CodeDirectory .*flags=.*runtime' <<< "$(signature "$file")" \
        || fail "${file#"$APP"/} is not signed with the hardened runtime."
    COUNT=$((COUNT + 1))
done < <(find "$APP/Contents" -type f -print0)
[ "$COUNT" -ge 1 ] || fail "found no Mach-O file in the bundle."
checked "hardened runtime on all $COUNT Mach-O files"

# The entitlements are exactly support/release.entitlements.
codesign --display --entitlements - --xml "$APP" > "$TMP/entitlements.plist" 2> /dev/null \
    || fail "could not read the bundle's entitlements."
python3 -I - "$TMP/entitlements.plist" "$ROOT/support/release.entitlements" << 'PY' || fail "the entitlements are wrong; see above."
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    signed = plistlib.load(f)
with open(sys.argv[2], "rb") as f:
    wanted = plistlib.load(f)
if "com.apple.security.get-task-allow" in signed:
    sys.exit("check-release: the bundle carries get-task-allow, which notarization rejects.")
if signed != wanted:
    sys.exit("check-release: the signed entitlements differ from support/release.entitlements.")
PY
checked "entitlements match support/release.entitlements"

# 3. Info.plist.
plist_value() { # <key>
    plutil -extract "$1" raw "$APP/Contents/Info.plist" 2> /dev/null || echo "(missing)"
}
expect_plist() { # <key> <value>
    local actual
    actual=$(plist_value "$1")
    [ "$actual" = "$2" ] || fail "Info.plist has $1 = $actual, expected $2."
}
expect_plist CFBundleShortVersionString "$RELEASE_VERSION"
expect_plist CFBundleVersion "$RELEASE_BUILD_NUMBER"
expect_plist CFBundleIdentifier "$BRAND_BUNDLE_ID"
expect_plist CFBundleExecutable "$BRAND_NAME"
expect_plist LSMinimumSystemVersion "$RELEASE_MIN_MACOS"
checked "Info.plist: version $RELEASE_VERSION, build $RELEASE_BUILD_NUMBER, macOS $RELEASE_MIN_MACOS or later"

# 4. Architectures, notices and symbols.
ARCHS=$(lipo -archs "$EXE")
[ "$ARCHS" = "$RELEASE_ARCHS" ] || fail "the executable is built for '$ARCHS', but release.env names '$RELEASE_ARCHS'."
checked "architectures: $ARCHS"
NOTICES="$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
[ -f "$NOTICES" ] || fail "the bundle has no Resources/THIRD-PARTY-NOTICES.md."
cmp -s "$NOTICES" "$ROOT/THIRD-PARTY-NOTICES.md" || fail "the bundle's THIRD-PARTY-NOTICES.md differs from the repository's."
checked "THIRD-PARTY-NOTICES.md in Resources"

ditto -x -k "$DIR/$RELEASE_DSYM_ZIP" "$TMP/dsym" || fail "$RELEASE_DSYM_ZIP does not unpack."
DSYM="$TMP/dsym/$APP_BUNDLE.dSYM"
[ -d "$DSYM" ] || fail "$RELEASE_DSYM_ZIP should hold $APP_BUNDLE.dSYM."
EXE_UUIDS=$(dwarfdump --uuid "$EXE" | awk '{print $2}' | sort | paste -sd ' ' -)
DSYM_UUIDS=$(dwarfdump --uuid "$DSYM" | awk '{print $2}' | sort | paste -sd ' ' -)
[ -n "$EXE_UUIDS" ] && [ "$EXE_UUIDS" = "$DSYM_UUIDS" ] \
    || fail "the dSYM's UUIDs ($DSYM_UUIDS) do not match the executable's ($EXE_UUIDS)."
checked "dSYM matches the executable: $EXE_UUIDS"

# 5. A real release is notarized, stapled and accepted by Gatekeeper.
if [ "$RELEASE_MODE" = release ]; then
    xcrun stapler validate "$APP" > "$TMP/stapler.log" 2>&1 \
        || { cat "$TMP/stapler.log" >&2; fail "the unpacked bundle has no valid stapled ticket."; }
    spctl --assess --type execute --verbose=2 "$APP" > "$TMP/spctl.log" 2>&1 \
        || { cat "$TMP/spctl.log" >&2; fail "Gatekeeper rejects the unpacked bundle."; }
    grep -q 'source=Notarized Developer ID' "$TMP/spctl.log" \
        || { cat "$TMP/spctl.log" >&2; fail "Gatekeeper accepts the bundle, but not as notarized Developer ID."; }
    checked "stapled ticket, and Gatekeeper accepts it as notarized Developer ID"
fi

# 6. The cask renders, parses and declares what it should.
"$ROOT/scripts/render-cask.sh" "$DIR" "$TMP/cask.rb" 2> "$TMP/render.log" \
    || { cat "$TMP/render.log" >&2; fail "the cask does not render."; }
"$RUBY" -wc "$TMP/cask.rb" > /dev/null || fail "the rendered cask is not valid Ruby."
REPO=$(github_repo)
TOKEN=$(cask_token)
MACOS=$(macos_symbol "$RELEASE_MIN_MACOS")
case $RELEASE_ARCHS in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=x86_64 ;;
    *) ARCH="" ;;
esac
# The zap paths start with a literal tilde, as Homebrew wants them.
# shellcheck disable=SC2088
ZAP="~/Library/Application Support/$BRAND_DATA_DIR|~/Library/Preferences/$BRAND_BUNDLE_ID.plist"
# shellcheck disable=SC2088
ZAP="$ZAP|~/Library/Saved Application State/$BRAND_BUNDLE_ID.savedState"
"$RUBY" "$ROOT/scripts/check-cask.rb" "$TMP/cask.rb" \
    "token=$TOKEN" \
    "version=$RELEASE_VERSION" \
    "sha256=$RELEASE_SHA256" \
    "url=https://github.com/$REPO/releases/download/v$RELEASE_VERSION/$RELEASE_ZIP" \
    "name=$BRAND_NAME" \
    "app=$APP_BUNDLE" \
    "quit=$BRAND_BUNDLE_ID" \
    "macos=$MACOS" \
    "arch=$ARCH" \
    "zap=$ZAP" \
    >&2 || fail "the rendered cask does not declare what it should."
checked "the cask renders, parses as Ruby and declares this release"

say "OK: $RELEASE_MODE $RELEASE_VERSION ($RELEASE_BUILD_NUMBER) in $DIR"
