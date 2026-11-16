# shellcheck shell=bash
# LaunchServices hygiene for scripts that launch a bundle. Source it after lib/env.sh.
#
# Launching a bundle registers it in the user's LaunchServices database. A copy of the app built in
# a mirror, in build/media or in a scratch folder would stay registered after its run, and the system
# would know many launchers. So every bundle a script launches is unregistered afterwards, except
# build/<name>.app, the one make builds and people run.

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Prints the bundle's physical path, or nothing when it does not exist.
bundle_path() { # <bundle>
    (cd "$1" 2> /dev/null && pwd -P)
}

# True when the bundle is build/<name>.app of this checkout.
is_canonical_app() { # <bundle>
    local canonical
    canonical="$(cd "$ROOT/build" 2> /dev/null && pwd -P)/$APP_BUNDLE"
    [ "$(bundle_path "$1")" = "$canonical" ]
}

# Unregisters the bundle from LaunchServices, unless it is build/<name>.app. Never fails the caller.
unregister_unless_canonical() { # <bundle>
    local path
    path=$(bundle_path "$1")
    [ -n "$path" ] || return 0
    is_canonical_app "$path" && return 0
    "$LSREGISTER" -u "$path" > /dev/null 2>&1 || echo "[launchservices] could not unregister $path" >&2
    return 0
}
