#!/bin/bash
# Fails on Swift calls that register a bundle in the user's LaunchServices database. Asking the
# system for a bundle's localized name, its display name or its icon by file path registers that
# bundle, so a test or scenario that does it on a made-up bundle fills the database with made-up
# apps. docs/ARCHITECTURE.md, "Working on a live desktop", rule 10.
#   scripts/check-launchservices.sh             check every Swift file git tracks or would track
#   scripts/check-launchservices.sh <files...>  check these files
#   scripts/check-launchservices.sh --self-test check this script and lib/launchservices.sh
#
# Forbidden everywhere: the localized-name resource value (localizedNameKey and
# kCFURLLocalizedNameKey) and FileManager's displayName(atPath:). An icon lookup by file path,
# NSWorkspace's icon(forFile:) or icon(forFiles:), is allowed only in Platform's live icon renderer,
# which draws real apps and files in the live launcher. A match after // on its line is a comment
# and does not count.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"

RENDERER="Packages/Platform/Sources/Platform/Icons/IconRenderer.swift"
ANYWHERE='(^|[^A-Za-z0-9_])(localizedNameKey|kCFURLLocalizedNameKey)([^A-Za-z0-9_]|$)|displayName\(atPath:'
ICON_BY_PATH='icon\(forFiles?:'

# Prints each forbidden call in the files as "file:line: what", and returns 1 when there is one.
check() { # <files...>
    local status=0 file hits
    for file in "$@"; do
        [ -f "$file" ] || continue
        hits=$(grep -nE "$ANYWHERE" "$file" || true)
        if [ "${file#./}" != "$RENDERER" ]; then
            hits+=$'\n'$(grep -nE "$ICON_BY_PATH" "$file" || true)
        fi
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            local line=${hit%%:*} code=${hit#*:}
            # A match only after // is in a comment.
            local before=${code%%//*}
            if [ "$before" != "$code" ] && ! grep -qE "$ANYWHERE|$ICON_BY_PATH" <<< "$before"; then
                continue
            fi
            echo "check-launchservices: $file:$line registers a bundle with LaunchServices: ${code#"${code%%[![:space:]]*}"}"
            status=1
        done <<< "$hits"
    done
    return $status
}

self_test() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/check-launchservices.XXXXXX")
    trap 'rm -rf "$dir"' RETURN
    local failures=0
    expect() { # <0|1> <description> <swift line> [path inside dir]
        local want=$1 what=$2 code=$3 path=${4:-Sample.swift} got=0
        mkdir -p "$dir/$(dirname "$path")"
        printf '%s\n' "$code" > "$dir/$path"
        (cd "$dir" && check "$path" > /dev/null) || got=1
        if [ "$got" != "$want" ]; then
            echo "self-test: $what: expected $want, got $got" >&2
            failures=$((failures + 1))
        fi
        rm -f "$dir/$path"
    }
    expect 1 "localized name key" 'let name = try url.resourceValues(forKeys: [.localizedNameKey]).localizedName'
    expect 1 "Core Foundation key" 'CFURLCopyResourcePropertyForKey(url, kCFURLLocalizedNameKey, &value, nil)'
    expect 1 "display name" 'let shown = FileManager.default.displayName(atPath: app.path)'
    expect 1 "icon by path" 'let icon = NSWorkspace.shared.icon(forFile: fixture.path)'
    expect 1 "icons by paths" 'let icon = NSWorkspace.shared.icon(forFiles: paths)'
    expect 1 "icon by path elsewhere in Platform" 'NSWorkspace.shared.icon(forFile: path)' \
        "Packages/Platform/Sources/Platform/Other.swift"
    expect 0 "icon by path in the live renderer" 'NSWorkspace.shared.icon(forFile: path)' "$RENDERER"
    expect 0 "volume name key" 'let keys: [URLResourceKey] = [.volumeLocalizedNameKey]'
    expect 0 "icon by type" 'let icon = NSWorkspace.shared.icon(for: .plainText)'
    expect 0 "comment" '// Never call displayName(atPath:) on a fixture.'
    expect 0 "trailing comment" 'let x = 1 // not icon(forFile:)'
    expect 1 "call before a comment" 'let s = FileManager.default.displayName(atPath: p) // do not'

    # The unregister helper: a stub stands in for lsregister, so nothing reaches LaunchServices.
    # The subshell keeps this checkout, bundle name, bundle ID and install folder to itself. The
    # sample bundles are plain folders with a made-up ID, and nothing hands them to the system.
    # shellcheck disable=SC2030,SC2034
    (
        ROOT="$dir/checkout"
        APP_BUNDLE="Sample.app"
        BRAND_BUNDLE_ID="org.example.sample"
        INSTALL_DIR="$dir/Applications"
        . "$(dirname "$0")/lib/launchservices.sh"
        LSREGISTER="$dir/lsregister"
        printf '#!/bin/bash\necho "$@" >> "%s/calls"\n' "$dir" > "$LSREGISTER"
        chmod +x "$LSREGISTER"
        mkdir -p "$ROOT/build/Sample.app" "$ROOT/build/media/Sample.app" "$dir/mirror/build/Sample.app"
        expect_calls() { # <what> <expected calls>
            local calls
            calls=$(cat "$dir/calls" 2> /dev/null || true)
            rm -f "$dir/calls"
            [ "$calls" = "$2" ] || {
                echo "self-test: unregister $1: expected"$'\n'"$2"$'\n'"got"$'\n'"$calls" >&2
                exit 1
            }
        }

        # Nothing installed: build's copy is the one the system keeps.
        unregister_unless_canonical "$ROOT/build/Sample.app"
        unregister_unless_canonical "$ROOT/build/media/Sample.app"
        unregister_unless_canonical "$dir/mirror/build/Sample.app"
        unregister_unless_canonical "$dir/missing.app"
        expect_calls "with nothing installed" "-u $(cd "$ROOT/build/media/Sample.app" && pwd -P)
-u $(cd "$dir/mirror/build/Sample.app" && pwd -P)"

        # A bundle in INSTALL_DIR with another ID is not an installed copy of this app.
        mkdir -p "$INSTALL_DIR/Sample.app/Contents"
        plutil -create xml1 "$INSTALL_DIR/Sample.app/Contents/Info.plist"
        plutil -insert CFBundleIdentifier -string org.example.other "$INSTALL_DIR/Sample.app/Contents/Info.plist"
        unregister_unless_canonical "$ROOT/build/Sample.app"
        expect_calls "with another app installed" ""

        # An installed copy: build's copy goes after its run, and the installed one stays.
        plutil -replace CFBundleIdentifier -string "$BRAND_BUNDLE_ID" "$INSTALL_DIR/Sample.app/Contents/Info.plist"
        unregister_unless_canonical "$ROOT/build/Sample.app"
        unregister_unless_canonical "$INSTALL_DIR/Sample.app"
        expect_calls "with an installed copy" "-u $(cd "$ROOT/build/Sample.app" && pwd -P)"
    ) || failures=$((failures + 1))

    if [ "$failures" -gt 0 ]; then
        echo "check-launchservices: self-test failed ($failures)" >&2
        return 1
    fi
    echo "check-launchservices: self-test OK"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

if [ $# -gt 0 ]; then
    check "$@"
    exit $?
fi

# shellcheck disable=SC2031
cd "$ROOT"
FILES=()
while IFS= read -r file; do
    case $file in
        *.swift) [ -f "$file" ] && FILES+=("$file") ;;
    esac
done < <(git ls-files --cached --others --exclude-standard)
status=0
check ${FILES[@]+"${FILES[@]}"} || status=1
[ $status = 0 ] && echo "check-launchservices: OK (${#FILES[@]} files)"
exit $status
