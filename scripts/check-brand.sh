#!/bin/bash
# Keeps the product's identity in two places: support/brand.env for scripts and
# Packages/Kit/Sources/Kit/Brand.swift for code. Fails when the two disagree, or when the product
# name, bundle identifier, data folder or URL scheme is written out anywhere else. The repository's
# address is the one value brand.env shares with the App package's ProjectLinks instead, and it
# must agree there too.
#   scripts/check-brand.sh
#
# Scope: code, scripts, templates and configuration that git tracks or would track. Prose is not
# checked, because it describes the product by name: Markdown files, LICENSE, the website under
# site/ and the feature list in support/features.json. scripts/rename-project.py rewrites those.
#
# Code names are not brand values. Module, package, crate and symbol names such as SlickApp,
# slick-ffi or slick_abi_version stay the same when the product is renamed, so only quoted or
# path-like uses of the brand values count. SwiftPM manifests may quote the product name, because
# there it names a module or product; scripts/bundle.sh renames the executable from brand.env.
set -euo pipefail
. "$(dirname "$0")/lib/env.sh"
BRAND_SWIFT="Packages/Kit/Sources/Kit/Brand.swift"

status=0
problem() {
    echo "check-brand: $*"
    status=1
}

# 1. The two sources agree.
swift_value() { # <property name>
    sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" "$ROOT/$BRAND_SWIFT"
}
compare() { # <brand.env key> <Brand.swift property>
    local env_value=${!1} swift
    swift=$(swift_value "$2")
    [ "$env_value" = "$swift" ] || problem "$1=$env_value in support/brand.env but Brand.$2 is \"$swift\""
}
compare BRAND_NAME name
compare BRAND_BUNDLE_ID bundleID
compare BRAND_DATA_DIR dataDirectoryName
compare BRAND_URL_SCHEME urlScheme
# The repository's address: brand.env's for the scripts and the update feed, ProjectLinks' for the
# About pane.
PROJECT_LINKS="Packages/App/Sources/SlickApp/ProjectLinks.swift"
links_repository=$(sed -n 's/.*static let repository = link("\(.*\)").*/\1/p' "$ROOT/$PROJECT_LINKS")
[ "${BRAND_REPOSITORY%/}" = "$links_repository" ] \
    || problem "BRAND_REPOSITORY=$BRAND_REPOSITORY in support/brand.env but ProjectLinks.repository is \"$links_repository\""

# 2. Nothing else writes the values out.
cd "$ROOT"
FILES=()
while IFS= read -r file; do
    case $file in
        *.md | LICENSE | site/* | support/features.json | support/brand.env | "$BRAND_SWIFT") continue ;;
    esac
    [ -f "$file" ] && FILES+=("$file")
done < <(git ls-files --cached --others --exclude-standard)

# Empty arrays are expanded with ${a[@]+"${a[@]}"} because bash 3.2 treats "${a[@]}" as unset.
search() { # <description> <fixed string> [files...]
    local what=$1 needle=$2 hits
    shift 2
    [ $# -gt 0 ] || return 0
    hits=$(grep -nIF -- "$needle" "$@" || true)
    if [ -n "$hits" ]; then
        problem "$what written out; use support/brand.env or Kit.Brand instead:"
        echo "$hits" | sed 's/^/    /'
    fi
}
NOT_MANIFESTS=()
for file in ${FILES[@]+"${FILES[@]}"}; do
    [ "$(basename "$file")" = Package.swift ] || NOT_MANIFESTS+=("$file")
done
search "bundle identifier" "$BRAND_BUNDLE_ID" ${FILES[@]+"${FILES[@]}"}
search "URL scheme" "$BRAND_URL_SCHEME://" ${FILES[@]+"${FILES[@]}"}
search "URL scheme" "\"$BRAND_URL_SCHEME\"" ${FILES[@]+"${FILES[@]}"}
search "data folder" "Application Support/$BRAND_DATA_DIR" ${FILES[@]+"${FILES[@]}"}
search "app bundle name" "$BRAND_NAME.app" ${FILES[@]+"${FILES[@]}"}
search "product name" "\"$BRAND_NAME\"" ${NOT_MANIFESTS[@]+"${NOT_MANIFESTS[@]}"}

[ $status = 0 ] && echo "check-brand: OK (${#FILES[@]} files)"
exit $status
