#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Writes the Homebrew cask for one release from the template in support/homebrew/.
#   scripts/render-cask.sh <release dir> <output path>
#
# The version, the checksum and the architectures come from <release dir>/release.env, which
# scripts/release.sh writes. The name, bundle id and data folder come from support/brand.env, the
# repository from the origin remote, and the oldest macOS from scripts/lib/env.sh.
#
# Env: RELEASE_REPO=owner/name names the GitHub repository instead of the origin remote.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"
LOG_TAG=render-cask
USAGE="usage: render-cask.sh <release dir> <output path>"
DIR=${1:?$USAGE}
OUT=${2:?$USAGE}

read_release_env "$DIR/release.env"
for key in RELEASE_VERSION RELEASE_SHA256 RELEASE_ARCHS RELEASE_MIN_MACOS; do
    [ -n "${!key:-}" ] || fail "$DIR/release.env has no $key."
done
is_version "$RELEASE_VERSION" || fail "release.env names version '$RELEASE_VERSION', which is not X.Y.Z."
[[ $RELEASE_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail "release.env has no valid SHA-256."

TEMPLATES=("$ROOT"/support/homebrew/*.rb.in)
[ "${#TEMPLATES[@]}" -eq 1 ] && [ -f "${TEMPLATES[0]}" ] \
    || fail "expected exactly one template in support/homebrew/*.rb.in."
TEMPLATE=${TEMPLATES[0]}

# Homebrew installs an app built for one architecture only on Macs of that architecture.
case $(printf '%s\n' "$RELEASE_ARCHS" | tr ' ' '\n' | sort | tr '\n' ' ') in
    "arm64 ") ARCH_LINE="depends_on arch: :arm64" ;;
    "x86_64 ") ARCH_LINE="depends_on arch: :x86_64" ;;
    "arm64 x86_64 ") ARCH_LINE="" ;;
    *) fail "unexpected architectures in release.env: '$RELEASE_ARCHS'." ;;
esac

# Each value is computed on its own line, so a failure stops the script.
TOKEN=$(cask_token)
REPO=$(github_repo)
MACOS=$(macos_symbol "$RELEASE_MIN_MACOS")

SED_ARGS=(-e '/^# template:/d')
substitute() { # <token> <value>
    local escaped
    escaped=$(printf '%s' "$2" | sed -e 's/[\\&|]/\\&/g')
    SED_ARGS+=(-e "s|@$1@|$escaped|g")
}
substitute TOKEN "$TOKEN"
substitute VERSION "$RELEASE_VERSION"
substitute SHA256 "$RELEASE_SHA256"
substitute REPO "$REPO"
substitute MACOS "$MACOS"
substitute BRAND_NAME "$BRAND_NAME"
substitute BRAND_BUNDLE_ID "$BRAND_BUNDLE_ID"
substitute BRAND_DATA_DIR "$BRAND_DATA_DIR"
if [ -n "$ARCH_LINE" ]; then
    SED_ARGS+=(-e "s|@DEPENDS_ON_ARCH@|$ARCH_LINE|")
else
    SED_ARGS+=(-e '/@DEPENDS_ON_ARCH@/d')
fi

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.partial.$$"
trap 'rm -f "$TMP"' EXIT
sed "${SED_ARGS[@]}" "$TEMPLATE" > "$TMP"
if grep -n '@[A-Z_]*@' "$TMP" >&2; then
    fail "unfilled token in ${TEMPLATE#"$ROOT"/}"
fi
mv -f "$TMP" "$OUT"
say "wrote $OUT"
