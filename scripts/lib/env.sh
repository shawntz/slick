# shellcheck shell=bash
# Shared setup for every script in scripts/. Source it; do not run it.
#
# Sets ROOT to the repository root, puts the Rust toolchain on PATH, pins the macOS deployment
# target and exports the BRAND_* values from support/brand.env, among them the repository's address
# and the public key that checks updates.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT

# Homebrew's rustup is keg-only, so cargo is often not on PATH. rustup-init installs to ~/.cargo/bin.
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

# The oldest macOS the app supports. Rust objects, the icon and Info.plist all use it.
export MACOSX_DEPLOYMENT_TARGET=26.0

# Each line is split at its first "=" by hand. read with IFS='=' would drop a single "=" at the end
# of the value, and a base64 key such as BRAND_UPDATE_PUBLIC_KEY ends in one.
while IFS= read -r line || [ -n "$line" ]; do
    case $line in
        BRAND_*=*) export "${line%%=*}=${line#*=}" ;;
    esac
done < "$ROOT/support/brand.env"

# Name of the app bundle that scripts/bundle.sh writes.
export APP_BUNDLE="$BRAND_NAME.app"

# Ends a process and every process under it, the deepest first, so no child is left behind
# under another parent.
end_tree() { # <pid>
    local child
    for child in $(pgrep -P "$1" 2> /dev/null); do
        end_tree "$child"
    done
    kill -TERM "$1" 2> /dev/null || true
}

# Runs a command for at most the given number of seconds. When the time runs out, it ends the
# command and every process the command started, and returns 124, as timeout(1) does. Otherwise it
# returns the command's own status. The command stays in the caller's process group, and an
# interrupt or a TERM that reaches this shell, such as a person's Ctrl-C under make, ends the
# command's processes too. The command reads no input.
time_limit() { # <seconds> <command...>
    local seconds=$1 status=0 pid watchdog marker old_int old_term
    shift
    marker=$(mktemp -u "${TMPDIR:-/tmp}/slick-time-limit.XXXXXX")
    "$@" < /dev/null &
    pid=$!
    (
        sleep "$seconds" &
        wait "$!" 2> /dev/null
        : > "$marker"
        end_tree "$pid"
    ) > /dev/null 2>&1 &
    watchdog=$!
    old_int=$(trap -p INT)
    old_term=$(trap -p TERM)
    trap 'end_tree "$pid"' INT TERM
    wait "$pid" 2> /dev/null || status=$?
    eval "${old_int:-trap - INT}"
    eval "${old_term:-trap - TERM}"
    if [ -e "$marker" ]; then
        status=124
    else
        # The command ended first, or was ended. Stop the watchdog and its sleep.
        end_tree "$watchdog"
    fi
    wait "$watchdog" 2> /dev/null || true
    rm -f "$marker"
    return "$status"
}

# timeout(1) ships with macOS only from 27.2. On an older system, such as a hosted CI runner,
# time_limit stands in for it. Callers pass only a number of seconds and a command.
if ! command -v timeout > /dev/null 2>&1; then
    timeout() { # <seconds> <command...>
        time_limit "$@"
    }
fi
