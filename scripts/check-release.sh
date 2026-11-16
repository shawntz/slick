#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Checks every artifact of a release folder that scripts/release.sh wrote.
#   scripts/check-release.sh <release dir>
#
# It unpacks the zip that ships, not the bundle it was made from, and checks:
# - the checksums in SHA256SUMS.txt and release.env
# - the zip holds exactly one bundle, whose signature passes strict verification, with the hardened
#   runtime on every piece of code, every piece of nested code signed like the bundle, and exactly
#   the entitlements in support/release.entitlements
# - Sparkle.framework in Contents/Frameworks with its symbolic links, found through the
#   executable's runpath, and no runpath into a build folder
# - Info.plist carries the version, build number, bundle id, oldest macOS, the update feed, the
#   update key, automatic checks off and no automatic installs
# - the executable starts: run with --version, it prints the name, the version and the build number
#   and exits before it makes any window. dyld loads every linked framework before that, so a
#   missing or wrongly signed framework fails here
# - the executable's architectures, the third-party notices in Resources, and a dSYM whose UUIDs
#   match the executable
# - appcast.xml is well-formed with one item and every field, the zip's length, and a signature
#   that scripts/update-signature.swift verifies against the update key
# - the cask renders, parses as Ruby and declares what scripts/check-cask.rb expects
# A real release must also carry a Developer ID signature with a secure timestamp on every piece of
# code, a stapled ticket, pass Gatekeeper's assessment, and sign the update with the key in
# support/brand.env. A dry run must be signed ad hoc, with the library validation exception an ad
# hoc build needs, and signs the update with a throwaway key.
#
# It reads files and runs codesign, plutil, lipo, otool, dwarfdump, python3, swiftc and ruby, and
# the unpacked executable with --version only. It changes nothing in the release folder and makes
# no network request.
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
    RELEASE_SHA256 RELEASE_ARCHS RELEASE_MIN_MACOS RELEASE_APPCAST RELEASE_FEED RELEASE_UPDATE_PUBLIC_KEY; do
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
for file in "$RELEASE_ZIP" "$RELEASE_DSYM_ZIP" SHA256SUMS.txt release-notes.md "$RELEASE_APPCAST"; do
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

# Every piece of nested code is signed like the bundle: ad hoc in a dry run, and in a release with
# the bundle's Developer ID team and a secure timestamp. Library validation loads only code of the
# app's own team.
TEAM=$(sed -n 's/^TeamIdentifier=//p' <<< "$SIG")
NESTED=$(nested_code "$APP") || fail "could not list the code nested in the bundle."
NESTED_COUNT=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    nested=$(signature "$path")
    name=${path#"$APP"/}
    grep -q '^CodeDirectory .*flags=.*runtime' <<< "$nested" || fail "$name is not signed with the hardened runtime."
    if [ "$RELEASE_MODE" = release ]; then
        [ "$(sed -n 's/^TeamIdentifier=//p' <<< "$nested")" = "$TEAM" ] \
            || fail "$name is not signed with the bundle's team, $TEAM."
        grep -q '^Authority=Developer ID Application: ' <<< "$nested" || fail "$name is not signed with Developer ID."
        grep -q '^Timestamp=' <<< "$nested" || fail "$name has no secure timestamp."
    else
        grep -q '^Signature=adhoc' <<< "$nested" || fail "$name is not signed ad hoc, as the dry run's bundle is."
    fi
    NESTED_COUNT=$((NESTED_COUNT + 1))
done <<< "$NESTED"
[ "$NESTED_COUNT" -ge 1 ] || fail "found no nested code, and Sparkle.framework should bring some."
checked "all $NESTED_COUNT pieces of nested code signed like the bundle"

# The entitlements are exactly support/release.entitlements. An ad hoc dry run also carries the
# library validation exception, without which it could not load the ad hoc framework.
codesign --display --entitlements - --xml "$APP" > "$TMP/entitlements.plist" 2> /dev/null \
    || fail "could not read the bundle's entitlements."
python3 -I - "$TMP/entitlements.plist" "$ROOT/support/release.entitlements" "$RELEASE_MODE" << 'PY' || fail "the entitlements are wrong; see above."
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    signed = plistlib.load(f)
with open(sys.argv[2], "rb") as f:
    wanted = plistlib.load(f)
if "com.apple.security.get-task-allow" in signed:
    sys.exit("check-release: the bundle carries get-task-allow, which notarization rejects.")
if sys.argv[3] == "dry-run":
    wanted["com.apple.security.cs.disable-library-validation"] = True
if signed != wanted:
    sys.exit("check-release: the signed entitlements differ from support/release.entitlements.")
PY
if [ "$RELEASE_MODE" = release ]; then
    checked "entitlements match support/release.entitlements"
else
    checked "entitlements match support/release.entitlements, with the ad hoc build's library validation exception"
fi

# Sparkle.framework with its links, found through the runpath, and no runpath into a build folder.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FRAMEWORK" ] || fail "the bundle has no Contents/Frameworks/Sparkle.framework."
for link in Versions/Current Sparkle Autoupdate Updater.app XPCServices Resources; do
    [ -L "$FRAMEWORK/$link" ] || fail "Sparkle.framework/$link is not a symbolic link. The zip lost the framework's links."
done
RPATHS=$(otool -l "$EXE" | awk '/cmd LC_RPATH/ {rpath = 1; next} rpath && $1 == "path" {print; rpath = 0}' \
    | sed -E 's/^ *path (.*) \(offset [0-9]+\)$/\1/')
grep -qx '@executable_path/../Frameworks' <<< "$RPATHS" || fail "the executable has no runpath to Contents/Frameworks."
if grep -v '^@' <<< "$RPATHS" | grep -q .; then
    fail "the executable keeps a runpath outside the bundle: $(grep -v '^@' <<< "$RPATHS" | head -1)"
fi
otool -L "$EXE" | grep -q '@rpath/Sparkle.framework/' || fail "the executable does not link Sparkle.framework."
checked "Sparkle.framework with its links, found through the executable's runpath"

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
[ "$RELEASE_FEED" = "$(update_feed_url)" ] || fail "release.env names the feed $RELEASE_FEED, not $(update_feed_url)."
expect_plist SUFeedURL "$RELEASE_FEED"
expect_plist SUEnableAutomaticChecks false
expect_plist SUAllowsAutomaticUpdates false
expect_plist SUScheduledCheckInterval 86400
if [ "$RELEASE_MODE" = release ]; then
    [ -n "${BRAND_UPDATE_PUBLIC_KEY:-}" ] || fail "support/brand.env has no BRAND_UPDATE_PUBLIC_KEY."
    [ "$RELEASE_UPDATE_PUBLIC_KEY" = "$BRAND_UPDATE_PUBLIC_KEY" ] \
        || fail "the update was signed for another public key than the one in support/brand.env."
fi
expect_plist SUPublicEDKey "${BRAND_UPDATE_PUBLIC_KEY:-(missing)}"
checked "Info.plist: the update feed, ${BRAND_UPDATE_PUBLIC_KEY:+the update key, }automatic checks off and no automatic installs"

# The executable starts and loads its frameworks. --version prints and exits before any window.
VERSION_LINE=$(timeout 20 "$EXE" --version 2> "$TMP/version.log") \
    || { cat "$TMP/version.log" >&2; fail "the unpacked executable did not start with --version. A missing or wrongly signed framework stops it before it prints."; }
[ "$VERSION_LINE" = "$BRAND_NAME $RELEASE_VERSION ($RELEASE_BUILD_NUMBER)" ] \
    || fail "--version printed '$VERSION_LINE', expected '$BRAND_NAME $RELEASE_VERSION ($RELEASE_BUILD_NUMBER)'."
checked "the executable starts: $VERSION_LINE"

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

# 6. The update feed: one item with every field, the zip's length, and a signature that verifies.
REPO=$(github_repo)
DOWNLOAD="https://github.com/$REPO/releases/download/v$RELEASE_VERSION/$RELEASE_ZIP"
[ "$RELEASE_DOWNLOAD" = "$DOWNLOAD" ] || fail "release.env names the download $RELEASE_DOWNLOAD, not $DOWNLOAD."
HARDWARE=()
[ "$RELEASE_ARCHS" != arm64 ] || HARDWARE=(hardware=arm64)
UPDATE_SIGNATURE=$(python3 -I "$ROOT/scripts/appcast.py" check appcast="$DIR/$RELEASE_APPCAST" name="$BRAND_NAME" \
    version="$RELEASE_VERSION" build="$RELEASE_BUILD_NUMBER" minimum="$RELEASE_MIN_MACOS" url="$DOWNLOAD" \
    length="$(stat -f %z "$DIR/$RELEASE_ZIP")" ${HARDWARE[@]+"${HARDWARE[@]}"}) \
    || fail "$RELEASE_APPCAST does not describe this release; see above."
xcrun swiftc -O "$ROOT/scripts/update-signature.swift" -o "$TMP/update-signature" 2> "$TMP/swiftc.log" \
    || { cat "$TMP/swiftc.log" >&2; fail "could not compile scripts/update-signature.swift."; }
"$TMP/update-signature" verify "$RELEASE_UPDATE_PUBLIC_KEY" "$DIR/$RELEASE_ZIP" "$UPDATE_SIGNATURE" > /dev/null \
    || fail "the update signature in $RELEASE_APPCAST does not verify against the update key."
if [ "$RELEASE_MODE" = release ]; then
    checked "$RELEASE_APPCAST describes $RELEASE_ZIP, and its signature verifies against the update key"
else
    checked "$RELEASE_APPCAST describes $RELEASE_ZIP, and its signature verifies against the dry run's throwaway key"
fi

# 7. The cask renders, parses and declares what it should.
"$ROOT/scripts/render-cask.sh" "$DIR" "$TMP/cask.rb" 2> "$TMP/render.log" \
    || { cat "$TMP/render.log" >&2; fail "the cask does not render."; }
"$RUBY" -wc "$TMP/cask.rb" > /dev/null || fail "the rendered cask is not valid Ruby."
TOKEN=$(cask_token)
MACOS=$(macos_symbol "$RELEASE_MIN_MACOS")
case $RELEASE_ARCHS in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=x86_64 ;;
    *) ARCH="" ;;
esac
# The zap paths start with a literal tilde, as Homebrew wants them.
# shellcheck disable=SC2088
ZAP="~/Library/Application Support/$BRAND_DATA_DIR|~/Library/Caches/$BRAND_BUNDLE_ID|~/Library/Preferences/$BRAND_BUNDLE_ID.plist"
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
