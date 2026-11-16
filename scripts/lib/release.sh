# shellcheck shell=bash
# Shared helpers for the release scripts. Source it after lib/env.sh and set LOG_TAG first.
#
# A release is described by <output dir>/release.env, which scripts/release.sh writes and the other
# release scripts read. It holds plain KEY=value lines, one per line, without quotes.

# Prints a message on stderr, tagged with the script's name.
say() {
    printf '[%s] %s\n' "${LOG_TAG:-release}" "$*" >&2
}

# Prints a message on stderr and stops the script.
fail() {
    say "error: $*"
    exit 1
}

# Makes a new folder under TMPDIR, or /tmp, and prints its path. The caller removes it with a trap.
temp_dir() { # <name>
    local base=${TMPDIR:-/tmp}
    mktemp -d "${base%/}/$1.XXXXXX"
}

# True for a version of the form X.Y.Z, each part a number without a leading zero.
is_version() { # <version>
    [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

# True when the first version is higher than the second. Both must pass is_version.
version_gt() { # <a> <b>
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "$1"
    IFS=. read -r b1 b2 b3 <<< "$2"
    [ "$a1" -ne "$b1" ] && { [ "$a1" -gt "$b1" ]; return; }
    [ "$a2" -ne "$b2" ] && { [ "$a2" -gt "$b2" ]; return; }
    [ "$a3" -gt "$b3" ]
}

# Prints the highest version among the tags vX.Y.Z of this checkout that is below the given
# version, or nothing when there is none. An empty limit counts every tag.
tagged_version_below() { # <version, or "">
    local tag version best="" tags
    tags=$(git -C "$ROOT" tag --list 'v*') || return 1
    while IFS= read -r tag; do
        version=${tag#v}
        is_version "$version" || continue
        if [ -n "$1" ] && ! version_gt "$1" "$version"; then continue; fi
        if [ -z "$best" ] || version_gt "$version" "$best"; then best=$version; fi
    done <<< "$tags"
    printf '%s' "$best"
}

# Prints the highest version among the tags vX.Y.Z, or nothing when there is none.
last_released_version() {
    tagged_version_below ""
}

# Prints owner/name of the GitHub repository. RELEASE_REPO overrides the origin remote.
github_repo() {
    local url slug
    if [ -n "${RELEASE_REPO:-}" ]; then
        printf '%s' "$RELEASE_REPO"
        return
    fi
    url=$(git -C "$ROOT" remote get-url origin 2> /dev/null) \
        || fail "this checkout has no origin remote. Set RELEASE_REPO to owner/name."
    slug=$(printf '%s' "$url" | sed -E -n 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p')
    slug=${slug%.git}
    [ -n "$slug" ] || fail "origin is not a GitHub URL: $url. Set RELEASE_REPO to owner/name."
    printf '%s' "$slug"
}

# Prints Homebrew's name for a macOS version, such as tahoe for 26.0.
macos_symbol() { # <version>
    case ${1%%.*} in
        13) echo ventura ;;
        14) echo sonoma ;;
        15) echo sequoia ;;
        26) echo tahoe ;;
        27) echo golden_gate ;;
        *) fail "no Homebrew name known for macOS $1. Add it to macos_symbol in scripts/lib/release.sh." ;;
    esac
}

# Reads <file> and sets every RELEASE_* variable it names. Other lines are ignored.
read_release_env() { # <file>
    local key value
    [ -f "$1" ] || fail "$1 is missing. Run make release first."
    while IFS='=' read -r key value; do
        case $key in
            RELEASE_[A-Z0-9_]*) printf -v "$key" '%s' "$value" ;;
        esac
    done < "$1"
}

# The archive names for a version.
app_zip_name() { # <version>
    printf '%s-%s.zip' "$BRAND_NAME" "$1"
}
dsym_zip_name() { # <version>
    printf '%s-%s.dSYM.zip' "$BRAND_NAME" "$1"
}

# The Homebrew cask token: the product name in lowercase, with spaces as hyphens.
cask_token() {
    printf '%s' "$BRAND_NAME" | tr '[:upper:] ' '[:lower:]-'
}

# Prints the body of the "## <version>" section of CHANGELOG.md, without the heading. A heading may
# carry a date after the version, as in "## 0.1.0 - 2026-11-20", or brackets, as in "## [0.1.0]".
changelog_section() { # <version or Unreleased>
    awk -v want="$1" '
        /^## / {
            if (found) exit
            title = substr($0, 4)
            sub(/ .*/, "", title)
            gsub(/[][]/, "", title)
            if (title == want) { found = 1; next }
        }
        found { print }
    ' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

# Prints the code nested in a bundle, deepest first: every Mach-O file except the bundle's main
# executable, and every nested bundle that contains code. A nested bundle without code is sealed as
# a resource of its parent, so it is left out. Signing in this order signs inside out.
nested_code() { # <bundle>
    local bundle=$1 main path kinds found
    main=$(plutil -extract CFBundleExecutable raw "$bundle/Contents/Info.plist") || return 1
    main="$bundle/Contents/MacOS/$main"
    found=$(find "$bundle/Contents" -mindepth 1 \( -type f -o \( -type d \( -name '*.app' -o -name '*.appex' \
        -o -name '*.framework' -o -name '*.xpc' -o -name '*.systemextension' -o -name '*.bundle' \
        -o -name '*.plugin' \) \) \) -print) || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -f "$path" ]; then
            [ "$path" != "$main" ] || continue
            [[ $(file -b "$path") == Mach-O* ]] || continue
        else
            kinds=$(find "$path" -type f -exec file -b {} +) || return 1
            grep -q '^Mach-O' <<< "$kinds" || continue
        fi
        printf '%s\t%s\n' "$(tr -cd '/' <<< "$path" | wc -c | tr -d ' ')" "$path"
    done <<< "$found" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
}

# Prints the SHA-1 hash of the Developer ID Application identity to sign with: the one that
# DEVELOPER_ID_APPLICATION names by hash or by name, or the only one in the keychain. Listing
# identities reads no private key, so it never asks for keychain access.
developer_id_identity() {
    local identities matches count
    identities=$(security find-identity -v -p codesigning 2> /dev/null | grep '"Developer ID Application: ' || true)
    [ -n "$identities" ] || fail "the keychain holds no valid Developer ID Application identity. Install the certificate with its private key in the login keychain."
    matches=$(awk -v want="${DEVELOPER_ID_APPLICATION:-}" '{
        hash = $2
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/"[^"]*$/, "", name)
        if (want == "" || toupper(want) == hash || name == want || index(name, want) > 0) print hash
    }' <<< "$identities" | sort -u)
    count=$(grep -c . <<< "$matches" || true)
    if [ "$count" -eq 0 ]; then
        fail "DEVELOPER_ID_APPLICATION matches no valid Developer ID Application identity. These are valid:
$identities"
    fi
    if [ "$count" -gt 1 ]; then
        fail "several Developer ID Application identities match. Set DEVELOPER_ID_APPLICATION to the SHA-1 hash of one:
$identities"
    fi
    printf '%s' "$matches"
}
