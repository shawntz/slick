#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Builds a release into dist/: the app signed with Developer ID and the hardened runtime, notarized
# and stapled, zipped, its dSYM zipped beside it, and the checksums of both. It publishes nothing.
# make release-publish does that once you have looked at dist/. docs/RELEASING.md is the guide.
#   scripts/release.sh <version>                     a release, such as 0.1.0
#   RELEASE_DRY_RUN=1 scripts/release.sh <version>   a dry run, described below
#
# A release refuses to start on a tree with changes, on a shallow clone, off the main branch, when
# HEAD is not origin/main as last fetched, on a version that is not higher than the last vX.Y.Z
# tag, on a CHANGELOG.md without a "## <version>" section, and without:
#   NOTARYTOOL_PROFILE        the notarytool keychain profile, stored once with
#                             xcrun notarytool store-credentials
#   DEVELOPER_ID_APPLICATION  the Developer ID Application identity, by SHA-1 hash or by name. It may
#                             stay unset when the keychain holds exactly one such identity.
#
# A dry run is the same code with three steps switched off. It signs ad hoc without a secure
# timestamp instead of with Developer ID, and it skips notarization and stapling with the Gatekeeper
# check that follows. So it needs neither name above and never touches the Developer ID key or the
# notary service. The checks that stop a release only warn in a dry run. It writes to RELEASE_OUT
# when that is set, and otherwise to a temporary folder that it removes at the end. RELEASE_OUT must
# be new, empty, or the output of an earlier dry run, finished or not.
#
# A run that fails leaves what it made in its output folder, for a look, and the next run starts
# that folder over. release.env gets RELEASE_COMPLETE=1 only once every step and check has passed,
# and make release-publish refuses a dist/ without it.
#
# Steps:
#   1 guards     the refusals above
#   2 build      the Rust core and the app in release configuration, from nothing, in <out>/build
#   3 bundle     scripts/bundle.sh with the version and build number, stripped with a dSYM beside
#                it, and THIRD-PARTY-NOTICES.md in Resources once it is known to be current
#   4 sign       each nested piece of code, deepest first, then the bundle with the entitlements
#   5 notarize   zip with ditto, submit and wait. A dry run skips the submission.
#   6 staple     staple the ticket, trying again while it is not yet published, then assess with
#                spctl. A dry run skips both.
#   7 package    zip the bundle and the dSYM with ditto, write SHA256SUMS.txt and release.env
#   8 check      scripts/check-release.sh on the result
#
# The build number is the number of commits in HEAD's history, so each release has a higher one.
# Env: EXECUTABLE is SwiftPM's name for the app's executable. make passes it; without make, it is
# read from the Makefile. SWIFT_FLAGS adds words to swift build, as in scripts/swiftpm.sh.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"
LOG_TAG=release
STARTED=$(date +%s)

VERSION=${1:-}
[ -n "$VERSION" ] || fail "usage: make release VERSION=<x.y.z>, or scripts/release.sh <x.y.z>"
VERSION=${VERSION#v}
is_version "$VERSION" || fail "version '$VERSION' is not of the form X.Y.Z, such as 0.1.0."
DRY_RUN=${RELEASE_DRY_RUN:-0}
case $DRY_RUN in
    0) MODE=release ;;
    1) MODE=dry-run ;;
    *) fail "RELEASE_DRY_RUN must be 0 or 1, not '$DRY_RUN'." ;;
esac
cd "$ROOT"
EXECUTABLE=${EXECUTABLE:-$(sed -n 's/^EXECUTABLE := *//p' "$ROOT/Makefile")}
[ -n "$EXECUTABLE" ] || fail "no EXECUTABLE. Run this through make, or set EXECUTABLE to SwiftPM's product name."

# Stops a release. In a dry run it only warns, so the rest of the pipeline still runs.
refuse() {
    if [ "$DRY_RUN" = 1 ]; then
        say "dry run, a release would stop here: $*"
    else
        fail "$*"
    fi
}
STEP="before step 1"
step() {
    # The number and the first word, such as "5/8 notarize", for the message on failure.
    STEP="in step $(cut -d ' ' -f 1-2 <<< "$*")"
    say "== $*"
}

WORK=""
TEMP_OUT=""
OUT=""
cleanup() {
    local status=$? outcome=failed
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ -z "$TEMP_OUT" ] || rm -rf "$TEMP_OUT"
    if [ "$status" -ne 0 ]; then
        [ "$status" -ne 130 ] || outcome=stopped
        say "$MODE $VERSION $outcome $STEP after $(($(date +%s) - STARTED)) s. Nothing was published."
        if [ -n "$OUT" ] && [ -z "$TEMP_OUT" ]; then
            say "$OUT keeps what this run made, for a look. The next run starts it over."
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
WORK=$(temp_dir release-work) || fail "could not make a temporary folder under ${TMPDIR:-/tmp}."

# 1. Guards.
step "1/8 guards for $MODE $VERSION"
# The last step checks the cask with Ruby and the entitlements with Python, so look for every tool
# now rather than after a long build.
for tool in git swift codesign ditto shasum plutil lipo dwarfdump python3 "${RUBY:-ruby}"; do
    command -v "$tool" > /dev/null || fail "$tool not found. The release needs it."
done
git rev-parse --git-dir > /dev/null 2>&1 || fail "$ROOT is not a git checkout. Release from a clone."
COMMIT=$(git rev-parse HEAD)
STATUS_BEFORE=$(git status --porcelain)
if [ -n "$STATUS_BEFORE" ]; then
    refuse "the tree has changes. Commit them, or release from a clean clone:
$(head -20 <<< "$STATUS_BEFORE")"
fi
[ "$(git rev-parse --is-shallow-repository)" = false ] \
    || refuse "this is a shallow clone, so the build number would be wrong. Run: git fetch --unshallow"
# As in Splay: release only main, and only once it is pushed. This reads origin/main as last
# fetched or pushed, without a network request. make release-publish fetches and checks again.
BRANCH=$(git branch --show-current)
[ "$BRANCH" = main ] || refuse "release from the main branch, not from '${BRANCH:-a detached HEAD}'. Run: git switch main"
if ! UPSTREAM=$(git rev-parse -q --verify refs/remotes/origin/main); then
    refuse "this clone has no origin/main. Run: git fetch origin main"
elif [ "$UPSTREAM" != "$COMMIT" ]; then
    refuse "HEAD is not origin/main. Push your commits with git push, or bring main up to date with git pull, then run this again."
fi
LAST=$(last_released_version) || fail "could not list the tags."
if [ -n "$LAST" ] && ! version_gt "$VERSION" "$LAST"; then
    refuse "version $VERSION is not higher than the last release tag, v$LAST."
fi
NOTES=""
if [ -f "$ROOT/CHANGELOG.md" ]; then
    NOTES=$(changelog_section "$VERSION")
fi
if [ -z "$NOTES" ]; then
    refuse "CHANGELOG.md has no '## $VERSION' section with notes. Rename '## Unreleased' to '## $VERSION', start a new empty '## Unreleased' above it, and commit."
    [ ! -f "$ROOT/CHANGELOG.md" ] || NOTES=$(changelog_section Unreleased)
    [ -n "$NOTES" ] || NOTES="Dry run of $VERSION. No notes."
fi
ENTITLEMENTS="$ROOT/support/release.entitlements"
if grep -q 'com.apple.security.get-task-allow' "$ENTITLEMENTS"; then
    fail "support/release.entitlements asks for get-task-allow, which notarization rejects."
fi
if [ "$DRY_RUN" = 1 ]; then
    IDENTITY=-
    PROFILE=""
    say "dry run: signing ad hoc, and skipping notarization and stapling"
else
    PROFILE=${NOTARYTOOL_PROFILE:-}
    [ -n "$PROFILE" ] || fail "set NOTARYTOOL_PROFILE to your notarytool keychain profile. Store one once with: xcrun notarytool store-credentials <profile> --apple-id <Apple ID> --team-id <team ID>"
    for tool in notarytool stapler; do
        xcrun --find "$tool" > /dev/null 2>&1 || fail "xcrun cannot find $tool. Select a full Xcode with xcode-select."
    done
    command -v spctl > /dev/null || fail "spctl not found."
    IDENTITY=$(developer_id_identity)
    say "signing identity: $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/^[^"]*//')"
    say "notary profile: $PROFILE"
fi
BUILD_NUMBER=$(git rev-list --count HEAD)
say "version $VERSION, build $BUILD_NUMBER, commit $COMMIT"

# The output folder. A release always writes dist/. A dry run writes RELEASE_OUT or a temporary
# folder. Each starts empty. A .gitignore inside keeps git from listing it, and .release-output
# names the mode, so a later dry run knows the folder as its own even when this run fails early.
if [ "$DRY_RUN" = 0 ]; then
    OUT="$ROOT/dist"
    rm -rf "$OUT"
elif [ -n "${RELEASE_OUT:-}" ]; then
    mkdir -p "$RELEASE_OUT" || fail "could not make RELEASE_OUT=$RELEASE_OUT."
    DRY_OUT=$(cd "$RELEASE_OUT" && pwd)
    if [ -n "$(ls -A "$DRY_OUT")" ]; then
        grep -qx 'dry-run' "$DRY_OUT/.release-output" 2> /dev/null \
            || grep -qx 'RELEASE_MODE=dry-run' "$DRY_OUT/release.env" 2> /dev/null \
            || fail "RELEASE_OUT=$DRY_OUT is not empty and holds no earlier dry run. Name an empty or new folder."
        find "$DRY_OUT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    OUT=$DRY_OUT
else
    OUT=$(temp_dir release-dry-run) || fail "could not make a temporary folder under ${TMPDIR:-/tmp}."
    TEMP_OUT=$OUT
fi
mkdir -p "$OUT"
printf '*\n' > "$OUT/.gitignore"
printf '%s\n' "$MODE" > "$OUT/.release-output"
BUILD="$OUT/build"
STAGE="$BUILD/stage"
mkdir -p "$STAGE"
say "output: $OUT"

# 2. A clean build of the Rust core and the app.
step "2/8 build the Rust core and the app from nothing, in release configuration"
CARGO_TARGET_DIR="$BUILD/cargo" "$ROOT/scripts/build-rust.sh" release \
    || fail "the Rust build failed. Its errors are above."
swift_build() {
    # SWIFT_FLAGS is deliberately split into words, as in scripts/swiftpm.sh.
    # shellcheck disable=SC2086
    swift build --package-path "$ROOT/Packages/App" --scratch-path "$BUILD/swiftpm" --manifest-cache local \
        -c release ${SWIFT_FLAGS:-} "$@"
}
swift_build --product "$EXECUTABLE" || fail "swift build failed. Its errors are above."
BIN_DIR=$(swift_build --show-bin-path) || fail "swift build could not name its output folder."
BIN="$BIN_DIR/$EXECUTABLE"
[ -x "$BIN" ] || fail "swift build left no executable at $BIN."

# 3. The bundle, with the version, the build number and the third-party notices.
step "3/8 bundle"
if ! "$ROOT/scripts/third-party-notices.sh" --check; then
    refuse "THIRD-PARTY-NOTICES.md does not match the crates this build links. Run make notices and commit it."
fi
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY=- STRIP=1 \
    "$ROOT/scripts/bundle.sh" "$BIN" "$STAGE" release > /dev/null
APP="$STAGE/$APP_BUNDLE"
DSYM="$STAGE/$APP_BUNDLE.dSYM"
[ -d "$APP" ] || fail "scripts/bundle.sh wrote no bundle at $APP."
[ -d "$DSYM" ] || fail "scripts/bundle.sh wrote no dSYM at $DSYM. Release builds need STRIP=1."
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md" \
    || fail "could not copy THIRD-PARTY-NOTICES.md into the bundle."
for pair in "CFBundleShortVersionString=$VERSION" "CFBundleVersion=$BUILD_NUMBER"; do
    actual=$(plutil -extract "${pair%%=*}" raw "$APP/Contents/Info.plist") \
        || fail "Info.plist has no ${pair%%=*}."
    [ "$actual" = "${pair#*=}" ] || fail "Info.plist has ${pair%%=*} = $actual, expected ${pair#*=}."
done
ARCHS=$(lipo -archs "$APP/Contents/MacOS/$BRAND_NAME") || fail "lipo cannot read the executable's architectures."
say "bundle: version $VERSION ($BUILD_NUMBER), $ARCHS, $(du -sh "$APP" | awk '{print $1}')"

# 4. Sign each nested piece of code, deepest first, then the bundle.
step "4/8 sign"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
if [ "$DRY_RUN" = 1 ]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp)
fi
NESTED=$(nested_code "$APP") || fail "could not list the code nested in $APP_BUNDLE."
while IFS= read -r path; do
    [ -n "$path" ] || continue
    codesign "${SIGN_ARGS[@]}" "$path" || fail "could not sign ${path#"$APP"/}."
    say "signed ${path#"$APP"/}"
done <<< "$NESTED"
# Under Developer ID, codesign may ask once for access to the key. Choose Always Allow.
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP" || fail "could not sign $APP_BUNDLE."
codesign --verify --strict --deep --verbose=2 "$APP" || fail "the signed bundle fails strict verification."
say "signed $APP_BUNDLE: $(codesign --display --verbose=2 "$APP" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"

# 5. Notarize. The archive for the notary service is made in a dry run too, so ditto runs either way.
step "5/8 notarize"
NOTARY_ZIP="$WORK/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP" || fail "could not zip $APP_BUNDLE for the notary service."
if [ "$DRY_RUN" = 1 ]; then
    say "dry run: skipped sending $(du -h "$NOTARY_ZIP" | awk '{print $1}') to the notary service"
else
    say "sending $(du -h "$NOTARY_ZIP" | awk '{print $1}') to the notary service and waiting, usually a few minutes."
    say "notarytool prints nothing until the service answers. Ctrl-C stops the wait, not the submission."
    # With --output-format json, notarytool holds its output until the end and then prints one
    # object with id, status and message. Its exit status alone does not say whether Apple accepted.
    NOTARY_EXIT=0
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$PROFILE" --wait --output-format json \
        > "$OUT/notary.json" 2> "$WORK/notary.log" || NOTARY_EXIT=$?
    NOTARY_ID=$(plutil -extract id raw "$OUT/notary.json" 2> /dev/null || true)
    NOTARY_STATUS=$(plutil -extract status raw "$OUT/notary.json" 2> /dev/null || true)
    if [ -z "$NOTARY_ID" ]; then
        cat "$OUT/notary.json" "$WORK/notary.log" >&2 2> /dev/null || true
        fail "notarytool returned no submission ID, exit status $NOTARY_EXIT. If it cannot find the profile '$PROFILE', store it as docs/RELEASING.md says. Otherwise read its message above."
    fi
    say "notary submission $NOTARY_ID: ${NOTARY_STATUS:-no status}"
    if [ "$NOTARY_STATUS" != Accepted ]; then
        if xcrun notarytool log "$NOTARY_ID" --keychain-profile "$PROFILE" "$OUT/notary-log.json" > /dev/null 2>&1; then
            # The log lists each problem with the file it is in. Print them, so the cause shows here.
            python3 -I - "$OUT/notary-log.json" << 'PY' >&2 || true
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    log = json.load(handle)
for issue in log.get("issues") or []:
    print("[release] notary: %s: %s" % (issue.get("path", "?"), issue.get("message", "?")))
PY
        fi
        fail "notarization ended with status '${NOTARY_STATUS:-unknown}'. The reasons are in $OUT/notary-log.json, or run: xcrun notarytool log $NOTARY_ID --keychain-profile $PROFILE"
    fi
fi

# 6. Staple the ticket and ask Gatekeeper.
step "6/8 staple"
if [ "$DRY_RUN" = 1 ]; then
    say "dry run: skipped stapling and the Gatekeeper assessment"
else
    # Apple publishes the ticket a little after it accepts the submission, so try for about two
    # minutes before giving up.
    STAPLE_TRIES=5
    attempt=1
    until xcrun stapler staple "$APP" > "$WORK/stapler.log" 2>&1; do
        if [ "$attempt" -ge "$STAPLE_TRIES" ]; then
            cat "$WORK/stapler.log" >&2
            fail "stapling failed $STAPLE_TRIES times. Apple accepted submission $NOTARY_ID, so the ticket service or the network is the likely cause. Run make release again later. It builds, signs and notarizes again from the start."
        fi
        say "the ticket is not ready yet, attempt $attempt of $STAPLE_TRIES. Trying again in 30 s."
        attempt=$((attempt + 1))
        sleep 30
    done
    xcrun stapler validate "$APP" > "$WORK/stapler.log" 2>&1 \
        || { cat "$WORK/stapler.log" >&2; fail "the stapled ticket does not validate."; }
    spctl --assess --type execute --verbose=2 "$APP" > "$WORK/spctl.log" 2>&1 \
        || { cat "$WORK/spctl.log" >&2; fail "Gatekeeper rejects the stapled bundle."; }
    grep -q 'source=Notarized Developer ID' "$WORK/spctl.log" \
        || { cat "$WORK/spctl.log" >&2; fail "Gatekeeper does not see the bundle as notarized Developer ID."; }
    say "stapled, and Gatekeeper accepts it: $(grep 'source=' "$WORK/spctl.log")"
fi

# 7. Package what ships.
step "7/8 package"
ZIP=$(app_zip_name "$VERSION")
DSYM_ZIP=$(dsym_zip_name "$VERSION")
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP" || fail "could not zip $APP_BUNDLE into $ZIP."
ditto -c -k --sequesterRsrc --keepParent "$DSYM" "$OUT/$DSYM_ZIP" || fail "could not zip the dSYM into $DSYM_ZIP."
(cd "$OUT" && shasum -a 256 "$ZIP" "$DSYM_ZIP" > SHA256SUMS.txt) || fail "could not write SHA256SUMS.txt."
SHA256=$(shasum -a 256 "$OUT/$ZIP" | awk '{print $1}') || fail "could not hash $ZIP."
printf '%s\n' "$NOTES" > "$OUT/release-notes.md"
TREE_CLEAN=1
[ -z "$STATUS_BEFORE" ] || TREE_CLEAN=0
cat > "$OUT/release.env" << EOF
# Written by scripts/release.sh. scripts/check-release.sh and scripts/release-publish.sh read it.
RELEASE_MODE=$MODE
RELEASE_VERSION=$VERSION
RELEASE_TAG=v$VERSION
RELEASE_BUILD_NUMBER=$BUILD_NUMBER
RELEASE_COMMIT=$COMMIT
RELEASE_TREE_CLEAN=$TREE_CLEAN
RELEASE_ZIP=$ZIP
RELEASE_DSYM_ZIP=$DSYM_ZIP
RELEASE_SHA256=$SHA256
RELEASE_ARCHS=$ARCHS
RELEASE_MIN_MACOS=$MACOSX_DEPLOYMENT_TARGET
EOF
mv "$APP" "$DSYM" "$OUT/" || fail "could not move the bundle and the dSYM into $OUT."
rm -rf "$BUILD"

# 8. Check what ships.
step "8/8 check"
"$ROOT/scripts/check-release.sh" "$OUT"
if [ "$(git status --porcelain)" != "$STATUS_BEFORE" ] || [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
    refuse "the tree changed while the release was built, so dist/ may not match the commit. Look at git status, then run make release again."
fi
# The mark make release-publish looks for. Only messages follow it.
printf 'RELEASE_COMPLETE=1\n' >> "$OUT/release.env"

ELAPSED=$(($(date +%s) - STARTED))
if [ "$DRY_RUN" = 1 ]; then
    say "dry run of $VERSION passed in $ELAPSED s. Nothing was signed with Developer ID, notarized or published."
    if [ -n "$TEMP_OUT" ]; then
        say "the temporary output folder is removed now. Set RELEASE_OUT to keep it."
    else
        say "output kept in $OUT"
    fi
    exit 0
fi
cat >&2 << EOF

[release] $BRAND_NAME $VERSION ($BUILD_NUMBER) is built, notarized and stapled in $ELAPSED s. Nothing is published.

  dist/$ZIP          $(du -h "$OUT/$ZIP" | awk '{print $1}'), SHA-256 $SHA256
  dist/$DSYM_ZIP     the symbols, for crash reports
  dist/SHA256SUMS.txt       both checksums
  dist/release-notes.md     the release notes, from CHANGELOG.md
  dist/$APP_BUNDLE          the stapled bundle the zip holds

Next:
  1. Check dist/ by hand, as the "Before you publish" list in docs/RELEASING.md says.
  2. make release-publish VERSION=$VERSION
EOF
