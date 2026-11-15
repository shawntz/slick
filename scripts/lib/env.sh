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
