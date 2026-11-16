#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Sourcing install.sh inside run_install's subshell sets ROOT again, to the same folder.
# shellcheck disable=SC2031
# Tests the scripts that would change the Mac or the site, without changing either. Each test works
# in a temporary folder that is deleted at the end.
#   scripts/test-scripts.sh
#
# - install.sh: make install and make uninstall into a temporary INSTALL_DIR, with stand-in bundles
#   made of plain files under a made-up name and bundle ID, and a recorder in place of lsregister,
#   so nothing reaches LaunchServices.
# - ui-showcase.py: the manifest it writes, on a copy of site/media/manifest.json, never on
#   site/media itself: the merge always, and the whole publishing run with small made-up pictures
#   where Pillow is installed.
# - bundle.sh: every bundle carries THIRD-PARTY-NOTICES.md and Sparkle.framework with its links,
#   signs every helper inside ad hoc, deepest first, with the library validation exception an ad
#   hoc build needs, drops a runpath into a build folder, and writes the update feed only when
#   release packaging asks. The bundle wraps a tiny executable compiled here, the framework is a
#   stand-in made of copies of /usr/bin/true, everything is signed ad hoc in the temporary folder,
#   and nothing is ever opened or registered.
# - lib/env.sh's time_limit, which bounds make test-rust and stands in for timeout(1): it ends a
#   command and everything the command started, with sleep standing in for a hung test.
# - The update path of a release: update-signature.swift against RFC 8032's test vectors and with a
#   key pair it makes in memory and throws away, appcast.py's feed for a changelog section with
#   markup and a link and a zip of known bytes, the files release-publish.sh uploads, the cask's
#   update stanzas, and values that end in "=" in brand.env and release.env. No key is read from a
#   keychain and nothing reaches the network.
# - The guard that a release follows the last one: a higher build number and the same update key,
#   in a scratch git repository that reads none of this Mac's git settings.
# - The CI workflow's token, which may only read the repository.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
LOG_TAG=test-scripts
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"
SCRIPTS="$ROOT/scripts"
TEMP=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${TEMP%/}/test-scripts.XXXXXX")
SLEEPERS=()
cleanup() {
    local pid
    for pid in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill "$pid" 2> /dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

FAILURES=0
CHECKS=0
problem() {
    echo "test-scripts: $*" >&2
    FAILURES=$((FAILURES + 1))
}
# Compares a value with what was expected.
expect() { # <what> <expected> <actual>
    CHECKS=$((CHECKS + 1))
    [ "$2" = "$3" ] || problem "$1: expected"$'\n'"  $2"$'\n'"got"$'\n'"  $3"
}
# Checks that a text holds a phrase.
expect_contains() { # <what> <phrase> <text>
    CHECKS=$((CHECKS + 1))
    grep -qF -- "$2" <<< "$3" || problem "$1: no '$2' in"$'\n'"$3"
}

# --- install.sh -------------------------------------------------------------------------------

SAMPLE_ID=org.example.sample

# Makes a stand-in bundle of plain files: an Info.plist with the bundle ID and a marker file.
make_bundle() { # <path> <bundle id> <marker>
    mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
    plutil -create xml1 "$1/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
    printf '%s\n' "$3" > "$1/Contents/Resources/marker.txt"
    printf 'stand-in\n' > "$1/Contents/MacOS/Sample"
}

# Makes a case folder with Applications/, build/Sample.app and a recorder for lsregister, and
# prints its path.
new_case() { # <name>
    local dir="$WORK/$1"
    mkdir -p "$dir/Applications" "$dir/build"
    make_bundle "$dir/build/Sample.app" "$SAMPLE_ID" new
    printf '#!/bin/bash\necho "$@" >> "%s/calls"\n' "$dir" > "$dir/lsregister"
    chmod +x "$dir/lsregister"
    echo "$dir"
}

# Runs install.sh's install or uninstall in a subshell, as make would, under the made-up name and
# bundle ID, with the case's folder and recorder. Prints the output and returns the status. Sourcing
# install.sh sets ROOT again, to the same folder, inside the subshell only.
run_install() { # <case dir> install|uninstall [App.app]
    local dir=$1
    shift
    # shellcheck disable=SC2030
    (
        # shellcheck source=install.sh
        . "$SCRIPTS/install.sh"
        APP_BUNDLE=Sample.app
        BRAND_NAME=Sample
        BRAND_BUNDLE_ID=$SAMPLE_ID
        BRAND_DATA_DIR=Sample
        INSTALL_DIR="$dir/Applications"
        LSREGISTER="$dir/lsregister"
        main "$@"
    ) 2>&1
}

calls() { # <case dir>
    cat "$1/calls" 2> /dev/null || true
}
marker() { # <bundle>
    cat "$1/Contents/Resources/marker.txt" 2> /dev/null || echo missing
}
physical() { # <path>
    (cd "$1" && pwd -P)
}

# Starts a process whose command line names the bundle's executable, as a running copy's does,
# waits until ps lists it, and sets COPY_PID. It is sleep under another name and shows nothing.
COPY_PID=""
start_copy() { # <bundle>
    local exe="$1/Contents/MacOS/Sample"
    /bin/bash -c 'exec -a "$0" sleep 60' "$exe" > /dev/null 2>&1 &
    COPY_PID=$!
    SLEEPERS+=("$COPY_PID")
    local listed
    for _ in $(seq 1000); do
        listed=$(ps -axww -o command=)
        grep -qF -- "$exe" <<< "$listed" && return 0
        sleep 0.01
    done
    problem "the stand-in copy did not start"
}

test_install() {
    local dir out status

    dir=$(new_case install-new)
    status=0
    out=$(run_install "$dir" install "$dir/build/Sample.app") || status=$?
    expect "install: status" 0 "$status"
    expect "install: the copy" new "$(marker "$dir/Applications/Sample.app")"
    expect "install: registers the installed copy and unregisters build's" \
        "-f $(physical "$dir/Applications/Sample.app")"$'\n'"-u $(physical "$dir/build/Sample.app")" "$(calls "$dir")"
    expect "install: nothing else left in the folder" "Sample.app" "$(ls -A "$dir/Applications")"
    expect "install: build's copy stays" new "$(marker "$dir/build/Sample.app")"
    expect_contains "install: says where to turn on Open at Login" "Open at Login" "$out"

    dir=$(new_case install-over)
    make_bundle "$dir/Applications/Sample.app" "$SAMPLE_ID" old
    printf 'stale\n' > "$dir/Applications/Sample.app/Contents/Resources/stale.txt"
    status=0
    out=$(run_install "$dir" install "$dir/build/Sample.app") || status=$?
    expect "install over an old copy: status" 0 "$status"
    expect "install over an old copy: the copy" new "$(marker "$dir/Applications/Sample.app")"
    expect "install over an old copy: no file of the old copy stays" no \
        "$([ -e "$dir/Applications/Sample.app/Contents/Resources/stale.txt" ] && echo yes || echo no)"
    expect "install over an old copy: nothing else left in the folder" "Sample.app" "$(ls -A "$dir/Applications")"

    dir=$(new_case install-other-app)
    make_bundle "$dir/Applications/Sample.app" org.example.other theirs
    status=0
    out=$(run_install "$dir" install "$dir/build/Sample.app") || status=$?
    expect "install over another app: status" 1 "$status"
    expect "install over another app: left alone" theirs "$(marker "$dir/Applications/Sample.app")"
    expect "install over another app: no lsregister call" "" "$(calls "$dir")"
    expect_contains "install over another app: says so" "another app" "$out"

    dir=$(new_case install-running)
    make_bundle "$dir/Applications/Sample.app" "$SAMPLE_ID" old
    start_copy "$dir/Applications/Sample.app"
    status=0
    out=$(run_install "$dir" install "$dir/build/Sample.app") || status=$?
    expect "install while running: status" 1 "$status"
    expect_contains "install while running: says to quit it first" "Quit it first" "$out"
    expect "install while running: the old copy stays" old "$(marker "$dir/Applications/Sample.app")"
    expect "install while running: no lsregister call" "" "$(calls "$dir")"
    status=0
    out=$(run_install "$dir" uninstall) || status=$?
    expect "uninstall while running: status" 1 "$status"
    expect_contains "uninstall while running: says to quit it first" "Quit it first" "$out"
    expect "uninstall while running: the copy stays" old "$(marker "$dir/Applications/Sample.app")"
    kill "$COPY_PID" 2> /dev/null || true
    wait "$COPY_PID" 2> /dev/null || true
    status=0
    out=$(run_install "$dir" install "$dir/build/Sample.app") || status=$?
    expect "install once it quit: status" 0 "$status"
    expect "install once it quit: the copy" new "$(marker "$dir/Applications/Sample.app")"

    dir=$(new_case install-wrong-source)
    make_bundle "$dir/build/Other.app" org.example.other other
    status=0
    out=$(run_install "$dir" install "$dir/build/Other.app") || status=$?
    expect "install of another app: status" 1 "$status"
    expect "install of another app: nothing copied" "" "$(ls -A "$dir/Applications")"
    status=0
    out=$(run_install "$dir" install "$dir/build/Missing.app") || status=$?
    expect "install of a missing bundle: status" 1 "$status"
    expect_contains "install of a missing bundle: says to build it" "make app" "$out"
}

test_uninstall() {
    local dir out status path

    dir=$(new_case uninstall)
    make_bundle "$dir/Applications/Sample.app" "$SAMPLE_ID" old
    path=$(physical "$dir/Applications/Sample.app")
    status=0
    out=$(run_install "$dir" uninstall) || status=$?
    expect "uninstall: status" 0 "$status"
    expect "uninstall: removed" "" "$(ls -A "$dir/Applications")"
    expect "uninstall: unregisters the copy" "-u $path" "$(calls "$dir")"
    expect "uninstall: build's copy stays" new "$(marker "$dir/build/Sample.app")"
    expect_contains "uninstall: says the data stays" "Application Support/Sample" "$out"

    dir=$(new_case uninstall-other-app)
    make_bundle "$dir/Applications/Sample.app" org.example.other theirs
    status=0
    out=$(run_install "$dir" uninstall) || status=$?
    expect "uninstall of another app: status" 1 "$status"
    expect "uninstall of another app: left alone" theirs "$(marker "$dir/Applications/Sample.app")"
    expect "uninstall of another app: no lsregister call" "" "$(calls "$dir")"

    dir=$(new_case uninstall-nothing)
    status=0
    out=$(run_install "$dir" uninstall) || status=$?
    expect "uninstall with nothing installed: status" 0 "$status"
    expect "uninstall with nothing installed: no lsregister call" "" "$(calls "$dir")"
    expect_contains "uninstall with nothing installed: says so" "Nothing was removed" "$out"

    # The script itself, with nothing to do but read its arguments.
    for arguments in "" "remove" "install" "uninstall extra"; do
        status=0
        # Splitting the arguments into words is the point.
        # shellcheck disable=SC2086
        out=$("$SCRIPTS/install.sh" $arguments 2>&1) || status=$?
        expect "install.sh $arguments: status" 1 "$status"
        expect_contains "install.sh $arguments: usage" "usage:" "$out"
    done
}

# --- ui-showcase.py --------------------------------------------------------------------------

# Merges a copy of the site's manifest with a picture entry for every shot, as the publishing step
# does, and checks that the clips, the stills and the about text survive. Needs no Pillow.
test_showcase_merge() {
    local dir="$WORK/showcase-merge" out status
    mkdir -p "$dir"
    cp "$ROOT/site/media/manifest.json" "$dir/original.json"
    status=0
    out=$(python3 -I -B - "$SCRIPTS/ui-showcase.py" "$dir/original.json" << 'PY' 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("showcase", sys.argv[1])
showcase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(showcase)
original = json.load(open(sys.argv[2], encoding="utf-8"))
shots = [file for file, *_ in showcase.SHOTS]
pictures = [{"file": file, "width": 10, "height": 10} for file in shots]
written = showcase.merged_manifest(original, pictures)
problems = []
if written.get("about") != original.get("about"):
    problems.append("the about text changed")
kept = [e for e in original["files"] if "clip" in e or "still" in e]
if not kept:
    problems.append("the site's manifest has no clip or still entry to keep")
stills = sorted((e for e in kept if "still" in e), key=lambda e: (e["still"], e["file"]))
clips = sorted((e for e in kept if "clip" in e and "still" not in e), key=lambda e: (e["clip"], e["file"]))
if written["files"] != pictures + stills + clips:
    written_kept = [e for e in written["files"] if "clip" in e or "still" in e]
    problems.append(f"kept {len(written_kept)} clip and still entries of {len(kept)}, or changed or reordered the entries")
if showcase.merged_manifest(written, pictures) != written:
    problems.append("a second merge changed the manifest")
fresh = showcase.merged_manifest(None, pictures)
if fresh != {"about": showcase.ABOUT, "files": pictures}:
    problems.append("without a manifest it does not write its own about text and its pictures")
print("\n".join(problems) or "ok")
PY
    ) || status=$?
    expect "showcase: the merge keeps every clip and still and the about text" ok "$out"
}

# Runs the whole publishing step on a copy of the site's manifest, with a small made-up capture
# for every shot. Needs Pillow, as publishing does; without it, says so and checks nothing.
test_showcase_publish() {
    local dir="$WORK/showcase" out status
    if ! python3 -I -c 'import PIL' > /dev/null 2>&1; then
        echo "test-scripts: Pillow is not installed, so the showcase's publishing run was skipped"
        return 0
    fi
    mkdir -p "$dir/raw" "$dir/media"
    cp "$ROOT/site/media/manifest.json" "$dir/media/manifest.json"
    status=0
    out=$(python3 -I -B - "$SCRIPTS/ui-showcase.py" "$dir/raw" << 'PY' 2>&1
import subprocess, sys
from pathlib import Path
from PIL import Image
raw = Path(sys.argv[2])
shots = subprocess.run(
    [sys.executable, "-I", sys.argv[1], "--shots"], check=True, capture_output=True, text=True
).stdout.split()
for index, name in enumerate(shots):
    Image.new("RGB", (40 + index, 30), (20 * (index % 12), 90, 160)).save(raw / name)
print(len(shots))
PY
    ) || status=$?
    expect "showcase: made-up captures" 0 "$status"
    run_showcase() {
        python3 -I -B "$SCRIPTS/ui-showcase.py" "$dir/raw" "$dir/media" "$dir/sheet.png" 2>&1
    }
    status=0
    out=$(run_showcase) || status=$?
    expect "showcase: first run" 0 "$status"
    expect_contains "showcase: first run counts what it kept" "clip and still entries" "$out"
    expect "showcase: the about text stays" same "$(python3 -I -c 'import json, sys
a, b = (json.load(open(p, encoding="utf-8"))["about"] for p in sys.argv[1:3])
print("same" if a == b else "changed")' "$ROOT/site/media/manifest.json" "$dir/media/manifest.json")"
    cp "$dir/media/manifest.json" "$dir/first.json"
    # A second run with no new captures keeps the pictures it made and changes nothing.
    rm -f "$dir/raw/"*
    status=0
    out=$(run_showcase) || status=$?
    expect "showcase: second run" 0 "$status"
    expect "showcase: a second run changes nothing" same \
        "$(cmp -s "$dir/first.json" "$dir/media/manifest.json" && echo same || echo different)"
}

# --- bundle.sh ---------------------------------------------------------------------------------

# Makes a stand-in for Sparkle's SwiftPM artifact under <dir>: a framework laid out as Sparkle's is,
# with links, helpers and XPC services whose code is copies of /usr/bin/true.
make_sparkle_stand_in() { # <dir>
    local framework="$1/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" version
    version="$framework/Versions/B"
    mkdir -p "$version/Resources" "$version/Updater.app/Contents/MacOS" \
        "$version/XPCServices/Downloader.xpc/Contents/MacOS" "$1/bin"
    cp /usr/bin/true "$version/Sparkle"
    cp /usr/bin/true "$version/Autoupdate"
    cp /usr/bin/true "$version/Updater.app/Contents/MacOS/Updater"
    cp /usr/bin/true "$version/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    stand_in_plist "$version/Resources/Info.plist" org.example.framework Sparkle FMWK
    stand_in_plist "$version/Updater.app/Contents/Info.plist" org.example.updater Updater APPL
    stand_in_plist "$version/XPCServices/Downloader.xpc/Contents/Info.plist" org.example.downloader Downloader XPC!
    ln -s B "$framework/Versions/Current"
    for link in Sparkle Autoupdate Resources Updater.app XPCServices; do
        ln -s "Versions/Current/$link" "$framework/$link"
    done
}

stand_in_plist() { # <path> <bundle id> <executable> <package type>
    plutil -create xml1 "$1"
    plutil -insert CFBundleIdentifier -string "$2" "$1"
    plutil -insert CFBundleExecutable -string "$3" "$1"
    plutil -insert CFBundlePackageType -string "$4" "$1"
}

test_bundle() {
    local dir="$WORK/bundle" out status app framework rpaths order entitlements
    mkdir -p "$dir/out" "$dir/feed"
    make_sparkle_stand_in "$dir/sparkle"
    # A tiny executable with a runpath into a build folder, as SwiftPM leaves one, and the bundle's.
    printf 'int main(void) { return 0; }\n' > "$dir/main.c"
    xcrun clang -x c "$dir/main.c" -o "$dir/executable" -Wl,-rpath,/build/out/Products/Release/PackageFrameworks \
        -Wl,-rpath,@executable_path/../Frameworks
    status=0
    out=$(SIGN_IDENTITY=- STRIP=0 SPARKLE_ARTIFACTS="$dir/sparkle" UPDATE_PUBLIC_KEY="" \
        "$SCRIPTS/bundle.sh" "$dir/executable" "$dir/out" debug 2>&1) || status=$?
    expect "bundle: status" 0 "$status"
    app="$dir/out/$APP_BUNDLE"
    framework="$app/Contents/Frameworks/Sparkle.framework"
    expect "bundle: the notices in Resources are the repository's" same \
        "$(cmp -s "$ROOT/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/THIRD-PARTY-NOTICES.md" && echo same || echo "different or missing: $out")"
    expect "bundle: the signature covers them, the framework and its helpers" valid \
        "$(codesign --verify --strict --deep "$app" > /dev/null 2>&1 && echo valid || echo invalid)"
    expect "bundle: the framework keeps its links" "B Versions/Current/Sparkle Versions/Current/XPCServices" \
        "$(readlink "$framework/Versions/Current") $(readlink "$framework/Sparkle") $(readlink "$framework/XPCServices")"
    local signed=0 path
    for path in "$framework/Versions/B/Sparkle" "$framework/Versions/B/Autoupdate" \
        "$framework/Versions/B/Updater.app" "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework"; do
        # Read whole, then searched: grep -q in a pipe would end codesign early and fail the pipe.
        grep -q '^Signature=adhoc' <<< "$(codesign --display --verbose=2 "$path" 2>&1)" && signed=$((signed + 1))
    done
    expect "bundle: the framework and each helper are signed ad hoc, as the app is" 5 "$signed"
    expect "bundle: the helpers carry the hardened runtime" yes \
        "$(grep -q 'flags=.*runtime' <<< "$(codesign --display --verbose=2 "$framework/Versions/B/Autoupdate" 2>&1)" && echo yes || echo no)"
    entitlements=$(codesign --display --entitlements - --xml "$app" 2> /dev/null | plutil -convert json -o - - 2> /dev/null)
    expect_contains "bundle: an ad hoc build turns off library validation, or it could not load the framework" \
        '"com.apple.security.cs.disable-library-validation":true' "$entitlements"
    expect_contains "bundle: and says so, with what that means for permission grants" \
        "library validation: off, so give this build no Accessibility or Input Monitoring grant" "$out"
    rpaths=$(otool -l "$app/Contents/MacOS/$BRAND_NAME" | awk '$1 == "path" {print $2}' | tr '\n' ' ')
    expect "bundle: only the bundle's own runpath stays" "@executable_path/../Frameworks " "$rpaths"
    expect "bundle: a build from source has no update feed" missing \
        "$(plutil -extract SUFeedURL raw "$app/Contents/Info.plist" 2> /dev/null || echo missing)"
    expect "bundle: automatic checks are off until the person agrees" false \
        "$(plutil -extract SUEnableAutomaticChecks raw "$app/Contents/Info.plist" 2> /dev/null || echo missing)"
    expect "bundle: Sparkle offers no silent automatic installs" false \
        "$(plutil -extract SUAllowsAutomaticUpdates raw "$app/Contents/Info.plist" 2> /dev/null || echo missing)"

    # Release packaging asks for the feed, and the key comes along when there is one.
    local key
    key=$(head -c 32 /dev/zero | base64)
    status=0
    out=$(SIGN_IDENTITY=- STRIP=0 SPARKLE_ARTIFACTS="$dir/sparkle" UPDATE_FEED=1 UPDATE_PUBLIC_KEY="$key" \
        "$SCRIPTS/bundle.sh" "$dir/executable" "$dir/feed" release 2>&1) || status=$?
    expect "bundle with the feed: status" 0 "$status"
    expect "bundle with the feed: SUFeedURL is the latest release's appcast" \
        "${BRAND_REPOSITORY%/}/releases/latest/download/appcast.xml" \
        "$(plutil -extract SUFeedURL raw "$dir/feed/$APP_BUNDLE/Contents/Info.plist" 2> /dev/null || echo missing)"
    expect "bundle with the feed: SUPublicEDKey keeps its final =" "$key" \
        "$(plutil -extract SUPublicEDKey raw "$dir/feed/$APP_BUNDLE/Contents/Info.plist" 2> /dev/null || echo missing)"

    # release.sh signs nested code in nested_code's order: inside out.
    order=$(nested_code "$app" | sed "s|^$framework/||" | tr '\n' ' ')
    expect "nested_code: every helper before what holds it" \
        "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader Versions/B/Updater.app/Contents/MacOS/Updater Versions/B/XPCServices/Downloader.xpc Versions/B/Autoupdate Versions/B/Sparkle Versions/B/Updater.app $app/Contents/Frameworks/Sparkle.framework " \
        "$order"
}

# --- time_limit ---------------------------------------------------------------------------------

# Reads the child ID a sleeper wrote, remembers it so cleanup ends it, and prints it. Prints
# nothing when there is none, which a check then reports.
child_of() { # <file>
    local pid
    pid=$(cat "$1" 2> /dev/null || true)
    case $pid in
        '' | 0 | 1 | *[!0-9]*) return 0 ;;
    esac
    SLEEPERS+=("$pid")
    echo "$pid"
}

# Waits until a process is gone, 10 s at most, and says whether it is.
gone() { # <pid>
    [ -n "$1" ] || { echo "no process ID"; return 0; }
    for _ in $(seq 1000); do
        kill -0 "$1" 2> /dev/null || { echo gone; return 0; }
        sleep 0.01
    done
    echo "still running"
}

# A command that starts a child that would sleep for two minutes, writes the child's ID and waits.
# The child's shell expands it. The child writes nowhere, so one left behind holds no pipe open.
# shellcheck disable=SC2016
SLEEPER='sleep 120 > /dev/null 2>&1 & echo $! > "$1"; wait'

test_time_limit() {
    local dir="$WORK/time-limit" status out child shell
    mkdir -p "$dir"

    status=0
    time_limit 30 true || status=$?
    expect "time_limit: a command that ends in time" 0 "$status"
    status=0
    time_limit 30 sh -c 'exit 3' || status=$?
    expect "time_limit: keeps the command's status" 3 "$status"

    status=0
    time_limit 1 bash -c "$SLEEPER" _ "$dir/child" || status=$?
    expect "time_limit: a command past its time" 124 "$status"
    child_of "$dir/child" > /dev/null
    child=$(cat "$dir/child" 2> /dev/null || true)
    expect "time_limit: the command's own child ends too" gone "$(gone "$child")"

    # A TERM to the shell that waits, as when make is stopped, ends the command's processes.
    rm -f "$dir/child"
    bash -c '. "$1"; time_limit 60 bash -c "$2" _ "$3"' _ "$SCRIPTS/lib/env.sh" "$SLEEPER" "$dir/child" &
    shell=$!
    SLEEPERS+=("$shell")
    for _ in $(seq 1000); do
        [ -s "$dir/child" ] && break
        sleep 0.01
    done
    child_of "$dir/child" > /dev/null
    child=$(cat "$dir/child" 2> /dev/null || true)
    kill -TERM "$shell"
    status=0
    wait "$shell" 2> /dev/null || status=$?
    expect "time_limit: the waiting shell stops" yes "$([ "$status" -ne 0 ] && echo yes || echo "no, $status")"
    expect "time_limit: a TERM ends the command's child" gone "$(gone "$child")"

    # make test-rust with a hung stand-in for cargo fails with time_limit's status instead of
    # waiting for it.
    status=0
    out=$(MAKEFLAGS='' make -s -C "$ROOT" test-rust RUST_TEST_TIMEOUT=1 CARGO="bash -c 'sleep 120' --" 2>&1) \
        || status=$?
    expect "make test-rust: fails when a test hangs" yes "$([ "$status" -ne 0 ] && echo yes || echo no)"
    expect_contains "make test-rust: with time_limit's status" "Error 124" "$out"
}

# --- The update path ------------------------------------------------------------------------------

# RFC 8032, section 7.1, tests 1 and 2: public keys and signatures only. Sparkle signs updates with
# Ed25519, so a tool that verifies these verifies Sparkle's signatures.
RFC_KEY_1=11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=
RFC_SIGNATURE_1=5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw==
RFC_KEY_2=PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw=
RFC_SIGNATURE_2=kqAJqfDUyrhyDoILX2QlQKKye1QWUD+Ps3YiI+vbadoIWsHkPhWZbkWPNhPQ8R2MOHsurrQwKu6wDSkWErsMAA==

test_update_signature() {
    local dir="$WORK/signature" tool status signed key signature other
    mkdir -p "$dir"
    tool="$dir/update-signature"
    status=0
    xcrun swiftc -O "$SCRIPTS/update-signature.swift" -o "$tool" > "$dir/swiftc.log" 2>&1 || status=$?
    expect "update-signature: compiles" 0 "$status"
    [ "$status" = 0 ] || return 0
    : > "$dir/empty"
    printf 'r' > "$dir/r"
    expect "update-signature: RFC 8032 test 1" ok \
        "$("$tool" verify "$RFC_KEY_1" "$dir/empty" "$RFC_SIGNATURE_1" > /dev/null 2>&1 && echo ok || echo refused)"
    expect "update-signature: RFC 8032 test 2" ok \
        "$("$tool" verify "$RFC_KEY_2" "$dir/r" "$RFC_SIGNATURE_2" > /dev/null 2>&1 && echo ok || echo refused)"
    expect "update-signature: test 2's signature does not fit test 1's message" refused \
        "$("$tool" verify "$RFC_KEY_2" "$dir/empty" "$RFC_SIGNATURE_2" > /dev/null 2>&1 && echo ok || echo refused)"

    # A zip of known bytes, signed with a key pair made in memory and thrown away.
    python3 -I -c 'import sys; open(sys.argv[1], "wb").write(bytes(range(256)) * 16)' "$dir/Sample-0.1.0.zip"
    signed=$("$tool" sign-throwaway "$dir/Sample-0.1.0.zip")
    key=$(sed -n 's/^public //p' <<< "$signed")
    signature=$(sed -n 's/^signature //p' <<< "$signed")
    expect "sign-throwaway: prints a public key and a signature, and nothing else" "public signature" \
        "$(awk '{print $1}' <<< "$signed" | tr '\n' ' ' | sed 's/ $//')"
    expect "sign-throwaway: its signature verifies" ok \
        "$("$tool" verify "$key" "$dir/Sample-0.1.0.zip" "$signature" > /dev/null 2>&1 && echo ok || echo refused)"
    other=$("$tool" sign-throwaway "$dir/Sample-0.1.0.zip" | sed -n 's/^public //p')
    expect "sign-throwaway: each run makes a new key" different "$([ "$other" != "$key" ] && echo different || echo same)"
    expect "verify: another key refuses the signature" refused \
        "$("$tool" verify "$other" "$dir/Sample-0.1.0.zip" "$signature" > /dev/null 2>&1 && echo ok || echo refused)"
    cp "$dir/Sample-0.1.0.zip" "$dir/changed.zip"
    printf 'X' | dd of="$dir/changed.zip" bs=1 seek=100 conv=notrunc 2> /dev/null
    expect "verify: one changed byte refuses the signature" refused \
        "$("$tool" verify "$key" "$dir/changed.zip" "$signature" > /dev/null 2>&1 && echo ok || echo refused)"
    UPDATE_TOOL=$tool
    UPDATE_ZIP="$dir/Sample-0.1.0.zip"
    UPDATE_KEY=$key
    UPDATE_SIGNATURE=$signature
}

test_appcast() {
    local dir="$WORK/appcast" status out url signature description
    [ -n "${UPDATE_TOOL:-}" ] || { problem "appcast: no signature from test_update_signature"; return 0; }
    mkdir -p "$dir"
    cat > "$dir/notes.md" << 'MD'
### Added

- Search <b>bold</b> & "quoted" 'text' with [the docs](https://example.com/docs?a=1&b=2).
- A `<code> & sample` and a [bad link](javascript:alert(1)) that
  wraps onto a second line.

A paragraph with <script>alert(1)</script>
over two lines.
MD
    url="https://github.com/example/sample/releases/download/v0.1.0/Sample-0.1.0.zip"
    write_appcast() { # <output> [key=value...]
        local output=$1
        shift
        python3 -I "$SCRIPTS/appcast.py" write output="$output" name=Sample version=0.1.0 build=42 minimum=26.0 \
            url="$url" length=4096 signature="$UPDATE_SIGNATURE" notes="$dir/notes.md" hardware=arm64 \
            "date=Sun, 15 Nov 2026 21:00:00 +0000" "$@" 2>&1
    }
    check_appcast() { # <appcast> [key=value...]
        local appcast=$1
        shift
        python3 -I "$SCRIPTS/appcast.py" check appcast="$appcast" name=Sample version=0.1.0 build=42 minimum=26.0 \
            url="$url" length="$(stat -f %z "$UPDATE_ZIP")" hardware=arm64 "$@" 2> "$dir/check.log"
    }
    status=0
    out=$(write_appcast "$dir/appcast.xml") || status=$?
    expect "appcast: writes" 0 "$status"
    status=0
    signature=$(check_appcast "$dir/appcast.xml") || status=$?
    expect "appcast: the check passes, with the zip's length" 0 "$status"
    expect "appcast: the check hands back the signature" "$UPDATE_SIGNATURE" "$signature"
    expect "appcast: its signature verifies against the key" ok \
        "$("$UPDATE_TOOL" verify "$UPDATE_KEY" "$UPDATE_ZIP" "$signature" > /dev/null 2>&1 && echo ok || echo refused)"
    description=$(python3 -I -c 'import sys, xml.etree.ElementTree as E
item = E.parse(sys.argv[1]).getroot().find("channel/item")
print(item.find("description").text)' "$dir/appcast.xml")
    expect "appcast: the notes are plain HTML with every character of the text escaped" \
        '<h3>Added</h3>
<ul><li>Search &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot; &#x27;text&#x27; with <a href="https://example.com/docs?a=1&amp;b=2">the docs</a>.</li><li>A <code>&lt;code&gt; &amp; sample</code> and a bad link that wraps onto a second line.</li></ul>
<p>A paragraph with &lt;script&gt;alert(1)&lt;/script&gt; over two lines.</p>' "$description"
    expect_contains "appcast: the XML escapes the HTML once more" '&lt;p&gt;A paragraph with &amp;lt;script&amp;gt;' \
        "$(cat "$dir/appcast.xml")"
    # Sparkle 2.9.6's header and its code name the format attribute differently, and both read a
    # description without one as HTML.
    expect "appcast: the description carries no attribute, so Sparkle reads it as HTML" "{}" \
        "$(python3 -I -c 'import sys, xml.etree.ElementTree as E
print(E.parse(sys.argv[1]).getroot().find("channel/item/description").attrib)' "$dir/appcast.xml")"
    expect_contains "appcast: Sparkle's version is the build number" '<sparkle:version>42</sparkle:version>' \
        "$(cat "$dir/appcast.xml")"
    expect_contains "appcast: the oldest macOS has three parts" \
        '<sparkle:minimumSystemVersion>26.0.0</sparkle:minimumSystemVersion>' "$(cat "$dir/appcast.xml")"

    status=0
    check_appcast "$dir/appcast.xml" length=4095 > /dev/null || status=$?
    expect "appcast: a length other than the zip's fails" 1 "$status"
    status=0
    check_appcast "$dir/appcast.xml" build=43 > /dev/null || status=$?
    expect "appcast: another build number fails" 1 "$status"
    sed 's|</item>|</item><item><title>Second</title></item>|' "$dir/appcast.xml" > "$dir/two.xml"
    status=0
    check_appcast "$dir/two.xml" > /dev/null || status=$?
    expect "appcast: a second item fails" 1 "$status"
    printf '<rss><channel>' > "$dir/broken.xml"
    status=0
    check_appcast "$dir/broken.xml" > /dev/null || status=$?
    expect "appcast: XML that is not well-formed fails" 1 "$status"
    status=0
    write_appcast "$dir/bad.xml" signature=abc > /dev/null || status=$?
    expect "appcast: a signature that is not 64 bytes is refused" 1 "$status"
    status=0
    write_appcast "$dir/bad.xml" url=http://example.com/Sample.zip > /dev/null || status=$?
    expect "appcast: a download without https is refused" 1 "$status"
}

test_release_files() {
    local dir="$WORK/release-files" out status
    mkdir -p "$dir"
    for file in Sample-0.1.0.zip Sample-0.1.0.dSYM.zip SHA256SUMS.txt; do printf 'x\n' > "$dir/$file"; done
    status=0
    out=$(RELEASE_ZIP=Sample-0.1.0.zip RELEASE_DSYM_ZIP=Sample-0.1.0.dSYM.zip release_assets "$dir" 2>&1) \
        || status=$?
    expect "release_assets: a dist without appcast.xml is refused" 1 "$status"
    expect_contains "release_assets: says which file is missing" "appcast.xml is missing" "$out"
    printf '<rss/>\n' > "$dir/appcast.xml"
    status=0
    out=$(RELEASE_ZIP=Sample-0.1.0.zip RELEASE_DSYM_ZIP=Sample-0.1.0.dSYM.zip release_assets "$dir" 2>&1) \
        || status=$?
    expect "release_assets: four files to upload, the appcast among them" \
        "Sample-0.1.0.zip Sample-0.1.0.dSYM.zip SHA256SUMS.txt appcast.xml " \
        "$(tr '\n' ' ' <<< "${out//$dir\//}")"

    # release-publish.sh never marks a release as a pre-release: the feed is the latest release,
    # which skips pre-releases. Taking the mark off a draft is the only use of the flag.
    expect "release-publish: no pre-release mark" "--prerelease=false" \
        "$(grep -o -- '--prerelease[=a-z]*' "$SCRIPTS/release-publish.sh" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    expect_contains "release-publish: publishing makes it the latest release" "--draft=false --latest" \
        "$(cat "$SCRIPTS/release-publish.sh")"
    expect_contains "release notes: the template says the software is early" "is early software" \
        "$(cat "$ROOT/support/release-notes.md.in")"

    # Values that end in "=", as a base64 key does, survive both readers.
    printf 'RELEASE_UPDATE_PUBLIC_KEY=abc+/def=\nRELEASE_OTHER=a=b\n' > "$dir/release.env"
    expect "read_release_env: keeps a final =" "abc+/def= a=b" \
        "$(read_release_env "$dir/release.env"; echo "$RELEASE_UPDATE_PUBLIC_KEY $RELEASE_OTHER")"
    # env.sh reads the brand file beside it, so a copy reads a made-up one.
    mkdir -p "$dir/copy/scripts/lib" "$dir/copy/support"
    cp "$SCRIPTS/lib/env.sh" "$dir/copy/scripts/lib/env.sh"
    printf 'BRAND_NAME=Sample\nBRAND_UPDATE_PUBLIC_KEY=abc+/def=\n# BRAND_COMMENT=no\n' > "$dir/copy/support/brand.env"
    expect "env.sh: a brand value keeps its final =" "Sample abc+/def= unset" \
        "$(bash -c '. "$1"; echo "$BRAND_NAME $BRAND_UPDATE_PUBLIC_KEY ${BRAND_COMMENT-unset}"' _ "$dir/copy/scripts/lib/env.sh")"
}

# The cask says the app updates itself and finds new versions with the plain latest strategy.
test_cask() {
    local dir="$WORK/cask" status out
    if ! command -v "${RUBY:-ruby}" > /dev/null; then
        echo "test-scripts: Ruby is not installed, so the cask was not checked"
        return 0
    fi
    mkdir -p "$dir"
    cat > "$dir/release.env" << ENV
RELEASE_VERSION=0.1.0
RELEASE_SHA256=$(printf '%064d' 0 | tr 0 a)
RELEASE_ARCHS=arm64
RELEASE_MIN_MACOS=26.0
ENV
    status=0
    RELEASE_REPO=example/sample "$SCRIPTS/render-cask.sh" "$dir" "$dir/cask.rb" 2> /dev/null || status=$?
    expect "cask: renders" 0 "$status"
    check_cask() { # <cask file>
        "${RUBY:-ruby}" "$SCRIPTS/check-cask.rb" "$1" "token=$(cask_token)" version=0.1.0 \
            "sha256=$(printf '%064d' 0 | tr 0 a)" \
            "url=https://github.com/example/sample/releases/download/v0.1.0/$BRAND_NAME-0.1.0.zip" \
            "name=$BRAND_NAME" "app=$APP_BUNDLE" "quit=$BRAND_BUNDLE_ID" macos=tahoe arch=arm64 \
            "zap=~/Library/Application Support/$BRAND_DATA_DIR|~/Library/Caches/$BRAND_BUNDLE_ID|~/Library/Preferences/$BRAND_BUNDLE_ID.plist|~/Library/Saved Application State/$BRAND_BUNDLE_ID.savedState" 2>&1
    }
    status=0
    out=$(check_cask "$dir/cask.rb") || status=$?
    expect "cask: auto_updates true and the latest strategy pass" 0 "$status"
    grep -v 'auto_updates' "$dir/cask.rb" > "$dir/no-auto.rb"
    status=0
    out=$(check_cask "$dir/no-auto.rb") || status=$?
    expect "cask: a cask without auto_updates fails" 1 "$status"
    expect_contains "cask: says so" "auto_updates" "$out"
    sed 's/strategy :github_latest/strategy :github_releases/' "$dir/cask.rb" > "$dir/releases.rb"
    status=0
    out=$(check_cask "$dir/releases.rb") || status=$?
    expect "cask: another livecheck strategy fails" 1 "$status"
}

# --- Release history ---------------------------------------------------------------------------

# Runs git in a scratch repository without any of this Mac's git settings, so no hook, signing or
# identity of the person's own applies.
scratch_git() { # <repository> <git arguments...>
    local repository=$1
    shift
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$repository" -c user.name=Sample \
        -c user.email=sample@example.com -c commit.gpgsign=false -c tag.gpgsign=false \
        -c core.hooksPath=/dev/null "$@"
}

test_release_history() {
    local repository="$WORK/history" key old_key out
    old_key=$(head -c 32 /dev/zero | base64)
    key=$(head -c 32 /dev/zero | tr '\0' '\1' | base64)
    mkdir -p "$repository/support"
    scratch_git "$repository" init -q -b main
    printf 'BRAND_NAME=Sample\nBRAND_UPDATE_PUBLIC_KEY=%s\n' "$old_key" > "$repository/support/brand.env"
    scratch_git "$repository" add support/brand.env
    scratch_git "$repository" commit -q -m one
    scratch_git "$repository" commit -q --allow-empty -m two
    scratch_git "$repository" tag v0.1.0
    problems() { # <last version> <key>
        (
            # ROOT changes only inside this subshell, on purpose.
            # shellcheck disable=SC2030
            export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null ROOT="$repository"
            follows_release_problems "$@"
        )
    }
    out=$(problems 0.1.0 "$old_key")
    expect_contains "history: the released commit itself has no higher build number" \
        "HEAD has build number 2, the number of commits in its history, and v0.1.0 has 2." "$out"
    scratch_git "$repository" commit -q --allow-empty -m three
    expect "history: a later commit with the same key follows the release" "" "$(problems 0.1.0 "$old_key")"
    out=$(problems 0.1.0 "$key")
    expect_contains "history: another update key is refused" "another update key than v0.1.0 did" "$out"
    expect "history: one problem, the key" 1 "$(grep -c . <<< "$out")"
    expect "history: UPDATE_KEY_ROTATION=1 allows a new key on purpose" "" \
        "$(UPDATE_KEY_ROTATION=1 problems 0.1.0 "$key")"
    expect_contains "history: a tag this clone lacks is named" "the tag v0.2.0 names no commit" \
        "$(problems 0.2.0 "$old_key")"
    # A rewritten main: the same files in one commit, fewer than the release had.
    scratch_git "$repository" checkout -q --orphan rewritten
    scratch_git "$repository" commit -q -m squashed
    out=$(problems 0.1.0 "$old_key")
    expect_contains "history: a rewritten history with a lower build number is refused" \
        "HEAD has build number 1, the number of commits in its history, and v0.1.0 has 2." "$out"
}

# CI builds third-party code, so its token may only read the repository. Whoever can write releases
# controls the update feed, the latest release's appcast.xml.
test_ci_token() {
    local workflow="$ROOT/.github/workflows/ci.yml" block
    block=$(awk '/^permissions:/ {inside = 1; print; next} inside && /^  / {print; next} {inside = 0}' "$workflow")
    expect "ci: the workflow's token can only read the repository" "permissions:|  contents: read" \
        "$(tr '\n' '|' <<< "$block" | sed 's/|$//')"
    expect "ci: no job asks for its own permissions" 1 "$(grep -c 'permissions:' "$workflow")"
    expect "ci: nothing asks to write" "" "$(grep -nE ':[[:space:]]*write([[:space:]]|$)' "$workflow" || true)"
}

cd "$ROOT"
test_time_limit
test_install
test_uninstall
test_showcase_merge
test_showcase_publish
test_bundle
test_update_signature
test_appcast
test_release_files
test_cask
test_release_history
test_ci_token

if [ "$FAILURES" -gt 0 ]; then
    echo "test-scripts: $FAILURES of $CHECKS checks failed" >&2
    exit 1
fi
echo "test-scripts: OK ($CHECKS checks)"
