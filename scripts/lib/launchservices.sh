# shellcheck shell=bash
# LaunchServices hygiene for scripts that launch or install a bundle. Source it after lib/env.sh.
#
# Launching a bundle registers it in the user's LaunchServices database. A copy of the app built in
# a mirror, in build/media or in a scratch folder would stay registered after its run, and the system
# would know many launchers. So every bundle a script launches is unregistered afterwards, except the
# one copy the system should know: the copy make install put in INSTALL_DIR when there is one, and
# build/<name>.app, the one make builds and people run, when there is none.
#
# Env:
#   LSREGISTER   the lsregister tool. Tests pass a recorder, so nothing reaches LaunchServices.
#   INSTALL_DIR  where make install puts the app (default /Applications).

LSREGISTER=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
INSTALL_DIR=${INSTALL_DIR:-/Applications}

# Prints the bundle's physical path, or nothing when it does not exist. Never fails, so a caller
# under set -e can test what it printed.
bundle_path() { # <bundle>
    (cd "$1" 2> /dev/null && pwd -P) || true
}

# Prints the bundle ID in the bundle's Info.plist, or nothing. Reads the file; asks LaunchServices
# nothing.
bundle_id() { # <bundle>
    plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2> /dev/null || true
}

# Prints the physical path of the installed copy, INSTALL_DIR/<name>.app, when it carries this app's
# bundle ID, and nothing otherwise.
installed_app() {
    local path="$INSTALL_DIR/$APP_BUNDLE"
    [ -d "$path" ] || return 0
    [ "$(bundle_id "$path")" = "$BRAND_BUNDLE_ID" ] || return 0
    bundle_path "$path"
}

# True when the bundle is the copy the system should know: the installed copy when there is one,
# and build/<name>.app of this checkout when there is none.
is_canonical_app() { # <bundle>
    local path installed canonical
    path=$(bundle_path "$1")
    installed=$(installed_app)
    if [ -n "$installed" ]; then
        [ "$path" = "$installed" ]
        return
    fi
    canonical="$(cd "$ROOT/build" 2> /dev/null && pwd -P)/$APP_BUNDLE"
    [ "$path" = "$canonical" ]
}

# Unregisters the bundle from LaunchServices, unless it is the copy the system should know. Never
# fails the caller.
unregister_unless_canonical() { # <bundle>
    local path
    path=$(bundle_path "$1")
    [ -n "$path" ] || return 0
    is_canonical_app "$path" && return 0
    "$LSREGISTER" -u "$path" > /dev/null 2>&1 || echo "[launchservices] could not unregister $path" >&2
    return 0
}
