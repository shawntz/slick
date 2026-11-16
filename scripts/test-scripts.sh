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
# - bundle.sh: every bundle carries THIRD-PARTY-NOTICES.md. The bundle wraps a copy of
#   /usr/bin/true, is signed ad hoc in the temporary folder, and is never opened or registered.
# - lib/env.sh's time_limit, which bounds make test-rust and stands in for timeout(1): it ends a
#   command and everything the command started, with sleep standing in for a hung test.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
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

test_bundle_notices() {
    local dir="$WORK/bundle" out status app
    mkdir -p "$dir/out"
    cp /usr/bin/true "$dir/executable"
    status=0
    out=$(SIGN_IDENTITY=- STRIP=0 "$SCRIPTS/bundle.sh" "$dir/executable" "$dir/out" debug 2>&1) || status=$?
    expect "bundle: status" 0 "$status"
    app="$dir/out/$APP_BUNDLE"
    expect "bundle: the notices in Resources are the repository's" same \
        "$(cmp -s "$ROOT/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/THIRD-PARTY-NOTICES.md" && echo same || echo "different or missing: $out")"
    expect "bundle: the signature covers them" valid \
        "$(codesign --verify --strict "$app" > /dev/null 2>&1 && echo valid || echo invalid)"
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

cd "$ROOT"
test_time_limit
test_install
test_uninstall
test_showcase_merge
test_showcase_publish
test_bundle_notices

if [ "$FAILURES" -gt 0 ]; then
    echo "test-scripts: $FAILURES of $CHECKS checks failed" >&2
    exit 1
fi
echo "test-scripts: OK ($CHECKS checks)"
