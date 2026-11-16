#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Writes THIRD-PARTY-NOTICES.md at the repository root: the license of every third-party Rust crate
# linked into the app, of the Rust standard library, and of the emoji data.
#   scripts/third-party-notices.sh            rewrite THIRD-PARTY-NOTICES.md
#   scripts/third-party-notices.sh --check    fail when the committed file is out of date
#   scripts/third-party-notices.sh --stdout   print the notices instead of writing them
#
# It makes no network request. The crate list comes from cargo tree for slick-ffi, with the features
# scripts/build-rust.sh turns on, for this Mac's target, without build, dev and proc-macro
# dependencies. So it names only code that ends up in the static library. Each license text comes
# from the crate's folder in the local cargo registry, which a build fills. When a crate offers a
# choice, as in "MIT OR Apache-2.0", the notice uses the first license in PREFERENCE below that the
# crate offers. A crate without a license file for its license fails the script.
#
# The output names no path, date or user, so the same lockfile gives the same file on every Mac.
set -euo pipefail
# shellcheck source=lib/env.sh
. "$(dirname "$0")/lib/env.sh"
LOG_TAG=third-party-notices
# shellcheck source=lib/release.sh
. "$(dirname "$0")/lib/release.sh"

MODE="write"
case ${1:-} in
    "") ;;
    --check) MODE=check ;;
    --stdout) MODE=stdout ;;
    *) fail "usage: third-party-notices.sh [--check | --stdout]" ;;
esac
OUT="$ROOT/THIRD-PARTY-NOTICES.md"
EMOJI_LICENSE="$ROOT/Packages/Features/Emoji/DATA-LICENSE.txt"
[ -f "$EMOJI_LICENSE" ] || fail "the emoji data's license is missing: ${EMOJI_LICENSE#"$ROOT"/}"
RUST_VERSION=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$ROOT/rust-toolchain.toml")
[ -n "$RUST_VERSION" ] || fail "rust-toolchain.toml names no channel."

TMP=$(temp_dir third-party-notices)
trap 'rm -rf "$TMP"' EXIT
CARGO="$ROOT/scripts/cargo.sh"
HOST=$("$CARGO" -vV | sed -n 's/^host: //p')
[ -n "$HOST" ] || fail "cargo did not report its host target."
"$CARGO" tree --offline --locked -p slick-ffi --features header --edges normal,no-proc-macro \
    --target "$HOST" --prefix none --format '{p}' > "$TMP/tree.txt" 2> "$TMP/cargo.log" \
    || { cat "$TMP/cargo.log" >&2; fail "cargo tree failed offline. Run make core once so the local registry holds every crate."; }
"$CARGO" metadata --offline --locked --format-version 1 --filter-platform "$HOST" \
    > "$TMP/metadata.json" 2> "$TMP/cargo.log" \
    || { cat "$TMP/cargo.log" >&2; fail "cargo metadata failed offline. Run make core once so the local registry holds every crate."; }

python3 -I - "$TMP/tree.txt" "$TMP/metadata.json" "$EMOJI_LICENSE" "$RUST_VERSION" "$BRAND_NAME" \
    > "$TMP/notices.md" << 'PY'
import json
import os
import re
import sys

tree_path, metadata_path, emoji_license_path, rust_version, product = sys.argv[1:6]

# When a crate offers a choice, the first of these that it offers wins.
PREFERENCE = ["MIT", "Apache-2.0", "Zlib", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Unicode-3.0",
              "Unicode-DFS-2016", "MPL-2.0"]
# A word in a license file's name that says which license it holds.
NAME_HINTS = {"MIT": "MIT", "Apache-2.0": "APACHE", "Zlib": "ZLIB", "BSD-3-Clause": "BSD",
              "BSD-2-Clause": "BSD", "ISC": "ISC", "Unicode-3.0": "UNICODE",
              "Unicode-DFS-2016": "UNICODE", "MPL-2.0": "MPL"}
# Words each license text contains, to catch a file that holds another license.
MARKERS = {"MIT": "Permission is hereby granted", "Apache-2.0": "Apache License",
           "Zlib": "misrepresented", "BSD-3-Clause": "Redistribution and use",
           "BSD-2-Clause": "Redistribution and use", "ISC": "Permission to use, copy, modify",
           "Unicode-3.0": "UNICODE LICENSE", "Unicode-DFS-2016": "Unicode", "MPL-2.0": "Mozilla Public License"}
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING)", re.IGNORECASE)
NOTICE_FILE = re.compile(r"^(NOTICE|COPYRIGHT)(\.(md|txt))?$", re.IGNORECASE)

MIT_TEXT = """Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""


def die(message):
    sys.exit("third-party-notices: " + message)


def parse_expression(text):
    """Parses an SPDX expression into nested ("OR"|"AND", [...]) and ("ID", name) tuples."""
    tokens = re.findall(r"\(|\)|[A-Za-z0-9.+\-]+", text.replace("/", " OR "))
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else None

    def take():
        nonlocal pos
        if pos >= len(tokens):
            die("license expression ends early: " + text)
        pos += 1
        return tokens[pos - 1]

    def any_of():
        items = [all_of()]
        while peek() == "OR":
            take()
            items.append(all_of())
        return items[0] if len(items) == 1 else ("OR", items)

    def all_of():
        items = [single()]
        while peek() == "AND":
            take()
            items.append(single())
        return items[0] if len(items) == 1 else ("AND", items)

    def single():
        token = take()
        if token == "(":
            node = any_of()
            if take() != ")":
                die("unbalanced parentheses in license expression: " + text)
            return node
        if peek() == "WITH":
            take()
            return ("ID", token + " WITH " + take())
        return ("ID", token)

    node = any_of()
    if peek() is not None:
        die("cannot read license expression: " + text)
    return node


def rank(name):
    return PREFERENCE.index(name) if name in PREFERENCE else len(PREFERENCE)


def choose(node):
    """Returns the licenses whose terms the notice follows: all of an AND, the best of an OR."""
    kind, value = node
    if kind == "ID":
        return [value]
    if kind == "AND":
        chosen = []
        for child in value:
            chosen += [name for name in choose(child) if name not in chosen]
        return chosen
    options = [choose(child) for child in value]
    return min(options, key=lambda names: max(rank(name) for name in names))


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip("\n")


def license_text(package, name, only_one):
    folder = os.path.dirname(package["manifest_path"])
    files = sorted(f for f in os.listdir(folder) if LICENSE_FILE.match(f))
    hint = NAME_HINTS.get(name)
    picked = [f for f in files if hint and hint in f.upper()]
    if not picked and only_one:
        named = [package["license_file"]] if package.get("license_file") else []
        generic = [f for f in files if not any(h in f.upper() for h in NAME_HINTS.values())]
        picked = named or generic
    if not picked:
        die("%s %s offers %s, and its folder has no file with that license. Add the text by hand."
            % (package["name"], package["version"], name))
    text = read(os.path.join(folder, picked[0]))
    marker = MARKERS.get(name)
    if marker and marker.lower() not in text.lower():
        die("%s in %s %s does not look like the %s license." % (picked[0], package["name"], package["version"], name))
    return text


def fenced(text):
    longest = max([len(run) for run in re.findall(r"`+", text)] + [2])
    fence = "`" * (longest + 1)
    return "%stext\n%s\n%s" % (fence, text, fence)


with open(metadata_path, encoding="utf-8") as handle:
    packages = json.load(handle)["packages"]
by_key = {}
for package in packages:
    by_key.setdefault((package["name"], package["version"]), []).append(package)

linked = {}
with open(tree_path, encoding="utf-8") as handle:
    for line in handle:
        match = re.match(r"^(\S+) v(\S+)", line.strip())
        if not match:
            continue
        candidates = by_key.get((match.group(1), match.group(2)), [])
        if not candidates:
            die("cargo tree names %s %s, which cargo metadata does not know." % match.groups())
        third_party = [p for p in candidates if p.get("source")]
        if third_party:
            linked[(third_party[0]["name"], third_party[0]["version"])] = third_party[0]

entries = []
for key in sorted(linked):
    package = linked[key]
    expression = package.get("license")
    if not expression:
        die("%s %s declares no license expression. Add its notice by hand." % key)
    chosen = choose(parse_expression(expression))
    for name in chosen:
        if name not in PREFERENCE:
            die("%s %s uses %s, which this script does not know. Add it to PREFERENCE." % (key[0], key[1], name))
    texts = [(name, license_text(package, name, len(chosen) == 1)) for name in chosen]
    folder = os.path.dirname(package["manifest_path"])
    notices = [(f, read(os.path.join(folder, f))) for f in sorted(os.listdir(folder)) if NOTICE_FILE.match(f)]
    entries.append((package, expression, chosen, texts, notices))

out = []
out.append("# Third-party notices")
out.append("")
out.append("%s is open source under the MIT license, in LICENSE. The app also contains the code and" % product)
out.append("data below, each under its own license. Each entry names the license that applies and gives")
out.append("its text. Where a crate offers a choice of licenses, the entry uses the one named.")
out.append("")
out.append("scripts/third-party-notices.sh writes this file from the Rust crates linked into the app.")
out.append("Do not edit it by hand. Run `make notices` and commit the result.")
out.append("")
out.append("## Contents")
out.append("")
for package, expression, chosen, _, _ in entries:
    out.append("- %s %s, under %s" % (package["name"], package["version"], " and ".join(chosen)))
out.append("- The Rust standard library, under MIT")
out.append("- Emoji and symbol data from Unicode, under the Unicode License v3")
out.append("")
out.append("## Rust crates")
for package, expression, chosen, texts, notices in entries:
    out.append("")
    out.append("### %s %s" % (package["name"], package["version"]))
    out.append("")
    out.append("License expression: `%s`. This notice follows %s." % (expression, " and ".join(chosen)))
    if package.get("repository"):
        out.append("Source: %s" % package["repository"])
    authors = [re.sub(r"\s*<[^>]*>", "", author).strip() for author in package.get("authors") or []]
    authors = [author for author in authors if author]
    if authors:
        out.append("Authors: %s" % ", ".join(authors))
    for name, text in texts:
        out.append("")
        out.append("%s:" % name)
        out.append("")
        out.append(fenced(text))
    for file_name, text in notices:
        out.append("")
        out.append("%s:" % file_name)
        out.append("")
        out.append(fenced(text))
out.append("")
out.append("## The Rust standard library")
out.append("")
out.append("The library links the standard library of Rust %s. It is licensed under the MIT license or" % rust_version)
out.append("the Apache License 2.0, at your option. This notice follows MIT. Copyright: The Rust Project")
out.append("Developers, see https://thanks.rust-lang.org. The notices of the standard library's own")
out.append("dependencies are in share/doc/rust/COPYRIGHT-library.html in the Rust toolchain.")
out.append("")
out.append("MIT:")
out.append("")
out.append(fenced("Copyright (c) The Rust Project Developers\n\n" + MIT_TEXT))
out.append("")
out.append("## Emoji and symbol data")
out.append("")
out.append("The names and keywords of emoji and symbols come from Unicode's emoji-test.txt and")
out.append("UnicodeData.txt and from the CLDR annotations, under the Unicode License v3.")
out.append("")
out.append("Unicode-3.0:")
out.append("")
out.append(fenced(read(emoji_license_path)))
print("\n".join(out))
PY

case $MODE in
    stdout) cat "$TMP/notices.md" ;;
    check)
        if ! cmp -s "$TMP/notices.md" "$OUT"; then
            diff -u "$OUT" "$TMP/notices.md" | head -40 >&2 || true
            fail "THIRD-PARTY-NOTICES.md is out of date. Run make notices and commit the result."
        fi
        say "THIRD-PARTY-NOTICES.md is current"
        ;;
    write)
        if cmp -s "$TMP/notices.md" "$OUT"; then
            say "THIRD-PARTY-NOTICES.md is already current"
        else
            mv -f "$TMP/notices.md" "$OUT"
            say "wrote THIRD-PARTY-NOTICES.md"
        fi
        ;;
esac
