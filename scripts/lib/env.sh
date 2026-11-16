# Shared setup for every script in scripts/. Source it; do not run it.
#
# Sets ROOT to the repository root, puts the Rust toolchain on PATH, pins the macOS deployment
# target and exports the BRAND_* values from support/brand.env.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT

# Homebrew's rustup is keg-only, so cargo is often not on PATH. rustup-init installs to ~/.cargo/bin.
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

# The oldest macOS the app supports. Rust objects, the icon and Info.plist all use it.
export MACOSX_DEPLOYMENT_TARGET=26.0

while IFS='=' read -r key value; do
    case $key in
        BRAND_*) export "$key=$value" ;;
    esac
done < "$ROOT/support/brand.env"

# Name of the app bundle that scripts/bundle.sh writes.
export APP_BUNDLE="$BRAND_NAME.app"

# timeout(1) ships with macOS only from 27.2. On an older system, such as a hosted CI runner, this
# stand-in runs a command, ends it after the given number of seconds and returns 124, as
# timeout(1) does. The command reads no input, which none of the callers need.
if ! command -v timeout > /dev/null 2>&1; then
    timeout() { # <seconds> <command...>
        local seconds=$1 status=0 pid watchdog marker
        shift
        marker=$(mktemp -u "${TMPDIR:-/tmp}/slick-timeout.XXXXXX")
        "$@" &
        pid=$!
        (
            sleep "$seconds" &
            wait "$!" 2> /dev/null
            : > "$marker"
            kill -TERM "$pid" 2> /dev/null
        ) > /dev/null 2>&1 &
        watchdog=$!
        wait "$pid" 2> /dev/null || status=$?
        if [ -e "$marker" ]; then
            status=124
        else
            # The command ended first. Stop the watchdog and its sleep.
            pkill -TERM -P "$watchdog" 2> /dev/null || true
            kill -TERM "$watchdog" 2> /dev/null || true
        fi
        wait "$watchdog" 2> /dev/null || true
        rm -f "$marker"
        return "$status"
    }
fi
