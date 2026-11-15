#!/usr/bin/env python3
"""Renames the whole project: the product, the crates, the C symbols, the Swift modules, the docs.

    scripts/rename-project.py <old> <new>            for example: scripts/rename-project.py oldname newname
    scripts/rename-project.py <old> <new> --dry-run  lists what would change and changes nothing

Names are given in lowercase. Three spellings are replaced everywhere, in file contents and in file
and folder names: lowercase, Capitalized and UPPERCASE. Build outputs are deleted, because they hold
the old names and absolute paths.

The script only touches files git knows about or would add: tracked files plus untracked files that
are not ignored. Afterwards run `make fmt`, because imports sort differently under the new name,
then `make bootstrap && make test && make lint`. Rename the repository folder yourself.
"""

import os
import re
import shutil
import subprocess
import sys


def spellings(name: str) -> list[str]:
    return [name, name.capitalize(), name.upper()]


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv[1:]
    if len(args) != 2:
        print(__doc__)
        return 64
    old, new = args
    pattern = re.compile(r"^[a-z][a-z0-9]{1,30}$")
    if not pattern.match(old) or not pattern.match(new) or old == new:
        print("rename-project: names must be different lowercase words of letters and digits")
        return 64

    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    ).stdout.strip()
    os.chdir(root)

    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        capture_output=True, check=True,
    ).stdout.split(b"\0")
    files = sorted({p.decode() for p in listed if p})

    pairs = list(zip(spellings(old), spellings(new)))
    # A file that already holds the new name would make the rename ambiguous to undo. Say so.
    clashes = 0
    changed_files = 0
    replacements = 0
    for path in files:
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        try:
            with open(path, "rb") as handle:
                raw = handle.read()
        except OSError:
            continue
        if b"\0" in raw:
            continue  # binary
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if any(n in text for _, n in pairs) and os.path.basename(path) != os.path.basename(__file__):
            clashes += 1
        updated = text
        count = 0
        for o, n in pairs:
            count += updated.count(o)
            updated = updated.replace(o, n)
        if count:
            changed_files += 1
            replacements += count
            if dry:
                print(f"  {count:5d}  {path}")
            else:
                with open(path, "wb") as handle:
                    handle.write(updated.encode("utf-8"))

    # Rename files and folders, deepest first, so a parent's new name never hides a child.
    renames = []
    seen = set()
    for path in files:
        parts = path.split("/")
        for depth in range(len(parts), 0, -1):
            prefix = "/".join(parts[:depth])
            if prefix in seen:
                continue
            seen.add(prefix)
            leaf = parts[depth - 1]
            new_leaf = leaf
            for o, n in pairs:
                new_leaf = new_leaf.replace(o, n)
            if new_leaf != leaf:
                renames.append((depth, prefix, "/".join(parts[: depth - 1] + [new_leaf])))
    renames.sort(key=lambda item: (-item[0], item[1]))
    for _, source, target in renames:
        if dry:
            print(f"  move   {source} -> {target}")
            continue
        if not os.path.exists(source):
            continue
        if os.path.exists(target):
            print(f"rename-project: {target} already exists, not moving {source}")
            return 1
        os.rename(source, target)

    # Build outputs hold the old names and absolute paths.
    outputs = ["build", "core/target"]
    for base in ("Packages", "Packages/Features"):
        if os.path.isdir(base):
            for entry in sorted(os.listdir(base)):
                outputs.append(os.path.join(base, entry, ".build"))
    outputs.append("Packages/CoreBridge/Artifacts")
    removed = 0
    for output in outputs:
        if os.path.isdir(output):
            removed += 1
            if not dry:
                shutil.rmtree(output)
    for entry in sorted(os.listdir(".")):
        if entry.endswith(".xcodeproj") and os.path.isdir(entry):
            removed += 1
            if not dry:
                shutil.rmtree(entry)

    verb = "would change" if dry else "changed"
    print(
        f"rename-project: {verb} {replacements} places in {changed_files} files, "
        f"{len(renames)} paths, {removed} build folders removed"
    )
    if clashes:
        print(f"rename-project: note: {clashes} files already contained the new name before the rename")
    if not dry:
        print("rename-project: next, run `make fmt && make bootstrap && make test && make lint`.")
        print("rename-project: imports sort differently under the new name, so the formatter must run first.")
        print("rename-project: then rename the repository folder yourself.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
