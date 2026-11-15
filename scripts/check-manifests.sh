#!/bin/bash
# Checks every Package.swift against the rules in docs/ARCHITECTURE.md:
# - tools version 6.2, macOS 26 deployment target;
# - the shared swiftSettings block, identical everywhere (a manifest cannot import shared code);
# - default MainActor isolation exactly where the architecture asks for it;
# - package dependencies only along the allowed edges;
# - no feature manifest mentions KitHosting, the contracts between the app's own packages.
#   scripts/check-manifests.sh
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"

# Allowed package dependencies. App may depend on everything.
allowed_dependencies() { # <package name> <is feature: 0|1>
    if [ "$2" = 1 ]; then
        echo "Kit LauncherUI CoreBridge"
        return
    fi
    case $1 in
        Kit | LauncherUI | CoreBridge) echo "" ;;
        Platform) echo "Kit" ;;
        SettingsUI | Host) echo "Kit LauncherUI" ;;
        Root) echo "Kit CoreBridge" ;;
        App) echo "*" ;;
        *) echo "unknown" ;;
    esac
}

# Default isolation: "main" = must use defaultIsolation(MainActor.self), "none" = must not,
# "any" = the package decides.
isolation_rule() { # <package name> <is feature: 0|1>
    if [ "$2" = 1 ]; then
        echo main
        return
    fi
    case $1 in
        LauncherUI | Platform | Host | Root | SettingsUI | App) echo main ;;
        CoreBridge) echo none ;;
        *) echo any ;;
    esac
}

status=0
problem() {
    echo "check-manifests: $*"
    status=1
}
reference=""
for manifest in "$ROOT"/Packages/*/Package.swift "$ROOT"/Packages/Features/*/Package.swift; do
    [ -f "$manifest" ] || continue
    dir=$(dirname "$manifest")
    name=$(basename "$dir")
    feature=0
    [ "$(basename "$(dirname "$dir")")" = Features ] && feature=1
    where=${manifest#"$ROOT"/}

    [ "$(head -1 "$manifest")" = "// swift-tools-version: 6.2" ] || problem "$where: tools version must be 6.2"
    grep -q 'platforms: \[.macOS(.v26)\]' "$manifest" || problem "$where: platforms must be [.macOS(.v26)]"

    block=$(awk '/^let swiftSettings: \[SwiftSetting\] = \[/ {f = 1} f {print} f && /^\]/ {exit}' "$manifest")
    if [ -z "$block" ]; then
        problem "$where: missing the shared swiftSettings block"
    else
        hash=$(printf '%s' "$block" | shasum | cut -c1-12)
        if [ -z "$reference" ]; then
            reference=$hash
        elif [ "$hash" != "$reference" ]; then
            problem "$where: swiftSettings block differs from the other manifests"
        fi
    fi

    has_main=0
    grep -q '\.defaultIsolation(MainActor\.self)' "$manifest" && has_main=1
    case $(isolation_rule "$name" "$feature") in
        main) [ $has_main = 1 ] || problem "$where: must use .defaultIsolation(MainActor.self)" ;;
        none) [ $has_main = 0 ] || problem "$where: must not use default MainActor isolation" ;;
    esac

    if [ $feature = 1 ] && grep -q 'KitHosting' "$manifest"; then
        problem "$where: a feature may not use KitHosting"
    fi

    allowed=$(allowed_dependencies "$name" "$feature")
    [ "$allowed" = unknown ] && problem "$where: unknown package; add its rules to this script and ARCHITECTURE.md"
    for dependency in $(grep -o '\.package(path: "[^"]*")' "$manifest" | sed 's|.*/\([^/"]*\)")$|\1|'); do
        [ "$allowed" = "*" ] && continue
        case " $allowed " in
            *" $dependency "*) ;;
            *) problem "$where: $name may not depend on $dependency" ;;
        esac
    done
done
[ $status = 0 ] && echo "check-manifests: OK"
exit $status
