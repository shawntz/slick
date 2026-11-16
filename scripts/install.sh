#!/bin/bash
# Installs the app for the person at the keyboard, or removes it. make install and make uninstall
# run this. Agents and tests never run it for real.
#   scripts/install.sh install <App.app>   copy the bundle into INSTALL_DIR with ditto
#   scripts/install.sh uninstall           remove INSTALL_DIR/<name>.app
#
# install refuses while a copy from INSTALL_DIR is running, and says to quit it first. It refuses to
# replace a bundle there that carries another bundle ID. It copies to a hidden folder beside the old
# copy and swaps the two only once the copy is whole. Afterwards the system knows one launcher: the
# installed copy is registered with LaunchServices and the bundle it came from, build/<name>.app,
# is unregistered. scripts/launch.sh keeps it that way, because while an installed copy exists it
# unregisters build's copy after each run.
#
# uninstall removes INSTALL_DIR/<name>.app only when it carries this app's bundle ID and is not
# running. It unregisters the copy from LaunchServices first. The data folder and the settings stay.
#
# Env:
#   INSTALL_DIR  where the app goes (default /Applications)
#   LSREGISTER   the lsregister tool. Tests pass a recorder, so nothing reaches LaunchServices.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/launchservices.sh"
USAGE="usage: install.sh install <App.app> | install.sh uninstall"

say() { printf '[install] %s\n' "$*"; }
fail() {
    printf '[install] %s\n' "$*" >&2
    exit 1
}

# Prints the ID of every process whose executable lies in the bundle, by the path it was started
# with: the path as given and the physical one.
running_from() { # <bundle>
    local given physical pid command
    given="$1/Contents/MacOS/"
    physical="$(bundle_path "$1")/Contents/MacOS/"
    while read -r pid command; do
        case $command in
            "$given"* | "$physical"*) echo "$pid" ;;
        esac
    done < <(ps -axww -o pid=,command=)
}

# Fails when a copy is running from the bundle.
refuse_while_running() { # <bundle> <what to run again>
    local pids
    pids=$(running_from "$1")
    [ -z "$pids" ] || fail "$BRAND_NAME is running from $1. Quit it first with Quit $BRAND_NAME in its menu bar menu, then run $2 again."
}

# The half-made copy install_app removes when it stops early.
STAGED=""
remove_staged() {
    [ -z "$STAGED" ] || rm -rf "$STAGED"
}

install_app() { # <App.app>
    local source dest replaced id
    source=$(bundle_path "$1")
    [ -n "$source" ] || fail "there is no app at $1. Build it with make app."
    id=$(bundle_id "$source")
    [ "$id" = "$BRAND_BUNDLE_ID" ] || fail "$1 carries the bundle ID '${id:-none}', not $BRAND_BUNDLE_ID."
    [ -d "$INSTALL_DIR" ] || fail "INSTALL_DIR=$INSTALL_DIR is not a folder."
    dest="$INSTALL_DIR/$APP_BUNDLE"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        [ "$(bundle_path "$dest")" != "$source" ] || fail "$1 is already the copy in $INSTALL_DIR."
        id=$(bundle_id "$dest")
        [ "$id" = "$BRAND_BUNDLE_ID" ] \
            || fail "$dest carries the bundle ID '${id:-none}', so it is another app. Move it away first. Nothing was changed."
        refuse_while_running "$dest" "make install"
    fi

    STAGED="$INSTALL_DIR/.$APP_BUNDLE.installing"
    replaced="$INSTALL_DIR/.$APP_BUNDLE.replaced"
    rm -rf "$STAGED" "$replaced"
    trap remove_staged EXIT
    ditto "$source" "$STAGED" \
        || fail "could not copy $APP_BUNDLE into $INSTALL_DIR. Install into a folder you can write, such as make install INSTALL_DIR=~/Applications."
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mv "$dest" "$replaced" || fail "could not move the old copy aside. Nothing was changed."
    fi
    if ! mv "$STAGED" "$dest"; then
        [ ! -e "$replaced" ] || mv "$replaced" "$dest"
        fail "could not put the new copy in place. The old copy stays."
    fi
    rm -rf "$replaced"
    STAGED=""

    dest=$(bundle_path "$dest")
    "$LSREGISTER" -f "$dest" > /dev/null 2>&1 || say "could not register $dest with LaunchServices"
    "$LSREGISTER" -u "$source" > /dev/null 2>&1 || say "could not unregister $source from LaunchServices"
    say "installed $dest"
    say "Open it from $INSTALL_DIR. Quit any copy started from build/ first, because one copy runs at a time."
    say "Turn on Open at Login in the installed copy's General settings, so login opens this copy."
}

uninstall_app() {
    local dest="$INSTALL_DIR/$APP_BUNDLE" id path
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
        say "there is no $APP_BUNDLE in $INSTALL_DIR. Nothing was removed."
        return 0
    fi
    id=$(bundle_id "$dest")
    [ "$id" = "$BRAND_BUNDLE_ID" ] \
        || fail "$dest carries the bundle ID '${id:-none}', so it is not this app. Nothing was removed."
    refuse_while_running "$dest" "make uninstall"
    path=$(bundle_path "$dest")
    "$LSREGISTER" -u "$path" > /dev/null 2>&1 || say "could not unregister $path from LaunchServices"
    rm -rf "$dest"
    say "removed $dest"
    say "The data folder in ~/Library/Application Support/$BRAND_DATA_DIR and the settings stay."
}

main() {
    case ${1:-} in
        install)
            [ $# = 2 ] || fail "$USAGE"
            install_app "$2"
            ;;
        uninstall)
            [ $# = 1 ] || fail "$USAGE"
            uninstall_app
            ;;
        *) fail "$USAGE" ;;
    esac
}

# Tests source this file for its functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
