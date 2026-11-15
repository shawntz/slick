#!/usr/bin/env python3
"""Generates Sources/Emoji/Catalog/EmojiData.swift from Unicode and CLDR data.

Usage:
    python3 -I Tools/generate-data.py --fetch <empty folder>
    python3 -I Tools/generate-data.py <folder with the downloaded files>

--fetch downloads the five files below into the folder first. Nothing else is sent or read.

Inputs, pinned to one release each:
    emoji-test.txt              https://www.unicode.org/Public/18.0.0/emoji/emoji-test.txt
    UnicodeData.txt             https://www.unicode.org/Public/18.0.0/ucd/UnicodeData.txt
    annotations-en.xml          CLDR release-49, common/annotations/en.xml
    annotationsDerived-en.xml   CLDR release-49, common/annotationsDerived/en.xml
    unicode-license.txt         https://www.unicode.org/license.txt

Output: one line per entry, fields separated by ";":
    glyph;name;group;version;common rank;keywords;skin tone variants

- glyph: the fully qualified emoji, or the symbol.
- name: the CLDR short name in title case, or for a symbol the CLDR name or the Unicode name.
- group: the index of the group or symbol set, in the order of GROUPS below.
- version: the Emoji version the emoji arrived in; empty for symbols.
- common rank: 1 for the most used emoji, then 2 and so on; 0 for the rest. From COMMON below.
- keywords: lowercase, separated by "|".
- skin tone variants: empty, 5 variants (light to dark) for one person, or 25 variants for two
  people, separated by " ". Variant (a, b) of a two-person emoji is at index a * 5 + b, with tones
  counted from 0, so the uniform tones sit at 0, 6, 12, 18 and 24.
"""

import argparse
import html
import os
import re
import sys
import urllib.request

EMOJI_VERSION = "18.0"
UNICODE_VERSION = "18.0.0"
CLDR_RELEASE = "release-49"
# macOS 26.0 draws Emoji 16.0. Newer emoji would show as empty boxes there.
MAX_EMOJI_VERSION = (16, 0)

SOURCES = {
    "emoji-test.txt": f"https://www.unicode.org/Public/{UNICODE_VERSION}/emoji/emoji-test.txt",
    "UnicodeData.txt": f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/UnicodeData.txt",
    "annotations-en.xml": f"https://raw.githubusercontent.com/unicode-org/cldr/{CLDR_RELEASE}/common/annotations/en.xml",
    "annotationsDerived-en.xml": (
        f"https://raw.githubusercontent.com/unicode-org/cldr/{CLDR_RELEASE}/common/annotationsDerived/en.xml"
    ),
    "unicode-license.txt": "https://www.unicode.org/license.txt",
}

# Emoji groups from emoji-test.txt, then the symbol sets. The order is the order of the grid. The
# Swift enum EmojiGroup uses the same indexes.
EMOJI_GROUPS = [
    "Smileys & Emotion",
    "People & Body",
    "Animals & Nature",
    "Food & Drink",
    "Travel & Places",
    "Activities",
    "Objects",
    "Symbols",
    "Flags",
]
SYMBOL_SETS = ["arrows", "math", "greek", "currency", "punctuation", "keyboard", "shapes", "box"]
GROUPS = EMOJI_GROUPS + SYMBOL_SETS

MODIFIERS = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
VS16 = 0xFE0F

# Emoji people use most, most used first. Hand-picked for this project. It breaks ties between
# equally good matches, so "heart" finds the red heart before the heart suit.
COMMON = (
    "😂 ❤️ 🤣 👍 😭 🙏 😘 🥰 😍 😊 🎉 😁 💕 🥺 😅 🔥 ☺️ 🤦 ♥️ 🤷 🙄 😆 🤗 😉 🎂 🤔 👏 🙂 😳 🥳 😎 👌 💜 "
    "😔 💪 ✨ 💖 👀 😋 😏 😢 👉 💗 😩 💯 🌹 💞 🎈 💙 😃 😡 💐 😜 🙈 🤞 😄 🤤 🙌 🤪 ❣️ 😀 💋 💀 👇 💔 😌 "
    "💓 🤩 🙃 😬 😱 😴 🤭 😐 🌞 😒 😇 🌸 😈 🎶 ✌️ 🎊 🥵 😞 💚 ☀️ 🖤 💰 😚 👑 🎁 💥 🙋 ☹️ 😑 🥴 👈 💩 "
    "✅ 👋 🤝 ⭐ 🚀 ☕ 🍕 🎵 👻 🐶 🐱 ⚡ ❌ ⚠️ 💡 📌 🔗 🐈 🐕 🌈 🍺 🎄 🏆 📅 📝"
).split()

# Names for keyboard symbols, which their Unicode names do not suggest.
KEY_NAMES = {
    0x2318: ("Command Key", ["command", "cmd"]),
    0x2325: ("Option Key", ["option", "alt", "opt"]),
    0x21E7: ("Shift Key", ["shift"]),
    0x2303: ("Control Key", ["control", "ctrl"]),
    0x21EA: ("Caps Lock Key", ["caps lock", "caps"]),
    0x23CE: ("Return Key", ["return", "enter"]),
    0x232B: ("Delete Key", ["delete", "backspace"]),
    0x2326: ("Forward Delete Key", ["forward delete", "delete"]),
    0x238B: ("Escape Key", ["escape", "esc"]),
    0x21E5: ("Tab Key", ["tab"]),
    0x21E4: ("Back Tab Key", ["back tab", "tab"]),
    0x2324: ("Enter Key", ["enter"]),
    0x2327: ("Clear Key", ["clear"]),
    0x2380: ("Insert Key", ["insert"]),
    0x21DE: ("Page Up Key", ["page up"]),
    0x21DF: ("Page Down Key", ["page down"]),
    0x2196: ("Home Key", ["home"]),
    0x2198: ("End Key", ["end"]),
    0x2423: ("Space Key", ["space"]),
    0x23FB: ("Power Key", ["power"]),
}

# Symbols in the ranges below that no system font draws on macOS 27.2. The glyph test in
# DataTests measures every symbol; add to this set when it fails after a regeneration.
UNDRAWN_SYMBOLS = {
    0x20C0,  # SOM SIGN
}

MINOR_WORDS = {"a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "vs", "with"}


def fetch(folder):
    os.makedirs(folder, exist_ok=True)
    for name, url in SOURCES.items():
        request = urllib.request.Request(url, headers={"User-Agent": "unicode-data-fetch"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        with open(os.path.join(folder, name), "wb") as file:
            file.write(data)
        print(f"fetched {name} ({len(data)} bytes)", file=sys.stderr)


def text(cps):
    return "".join(chr(cp) for cp in cps)


def version_tuple(version):
    major, minor = version.split(".")
    return int(major), int(minor)


def capitalize(word):
    for index, character in enumerate(word):
        if character.isalpha():
            return word[:index] + character.upper() + word[index + 1 :]
        if character.isdigit():
            return word
    return word


def title_case(name):
    words = name.split(" ")
    result = []
    after_colon = True
    for word in words:
        if not after_colon and word in MINOR_WORDS:
            result.append(word)
        else:
            result.append("-".join(capitalize(part) for part in word.split("-")))
        after_colon = word.endswith(":")
    return " ".join(result)


def parse_annotations(path):
    """Keywords and names by sequence, with U+FE0F removed, as CLDR keys them."""
    keywords, names = {}, {}
    source = open(path, encoding="utf-8").read()
    for match in re.finditer(r'<annotation cp="([^"]+)"( type="tts")?>([^<]*)</annotation>', source):
        cp = html.unescape(match.group(1))
        value = html.unescape(match.group(3)).strip()
        if match.group(2):
            names[cp] = value
        else:
            keywords[cp] = [part.strip() for part in value.split("|") if part.strip()]
    return keywords, names


def parse_unicode_data(path):
    names, categories = {}, {}
    for line in open(path, encoding="utf-8"):
        fields = line.rstrip("\n").split(";")
        if len(fields) < 3 or fields[1].startswith("<"):
            continue
        cp = int(fields[0], 16)
        names[cp] = fields[1]
        categories[cp] = fields[2]
    return names, categories


def parse_emoji_test(path):
    """Base emoji in file order, each with its skin tone variants attached."""
    entries = []
    group = None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if not line or line.startswith("#") or "; fully-qualified" not in line:
            continue
        if group == "Component":
            continue
        codes, comment = line.split("#", 1)
        cps = [int(part, 16) for part in codes.split(";")[0].split()]
        match = re.match(r"\s*\S+\s+E(\d+\.\d+)\s+(.*)$", comment)
        version, name = match.group(1), match.group(2)
        tones = [MODIFIERS.index(cp) for cp in cps if cp in MODIFIERS]
        if tones:
            base = entries[-1]
            base["variants"].append({"cps": cps, "tones": tones, "version": version})
        else:
            entries.append(
                {"cps": cps, "name": name, "group": EMOJI_GROUPS.index(group), "version": version, "variants": []}
            )
    return entries


def lay_out_tones(entry):
    """The variants in slot order, or [] when the emoji has none within the version limit."""
    variants = [v for v in entry["variants"] if version_tuple(v["version"]) <= MAX_EMOJI_VERSION]
    if not variants:
        return []
    if len(variants) != len(entry["variants"]):
        raise SystemExit(f"{entry['name']}: some skin tones are newer than the limit; decide what to do")
    two_people = any(len(v["tones"]) == 2 for v in variants)
    slots = [None] * (25 if two_people else 5)
    for variant in variants:
        tones = variant["tones"]
        if two_people:
            first, second = (tones[0], tones[0]) if len(tones) == 1 else (tones[0], tones[1])
            index = first * 5 + second
        else:
            if len(tones) != 1:
                raise SystemExit(f"{entry['name']}: unexpected tones {tones}")
            index = tones[0]
        if slots[index] is not None:
            raise SystemExit(f"{entry['name']}: two variants for slot {index}")
        slots[index] = text(variant["cps"])
    if any(slot is None for slot in slots):
        raise SystemExit(f"{entry['name']}: missing skin tone variants")
    return slots


def clean_keywords(words, name):
    seen = {name.lower()}
    result = []
    for word in words:
        word = word.lower().replace(";", ",").replace("|", "/").strip()
        if word and word not in seen:
            seen.add(word)
            result.append(word)
    return result


def symbol_sets(cldr_names, unicode_names, categories, emoji_cps):
    annotated = {ord(cp) for cp in cldr_names if len(cp) == 1}

    def assigned(cps, kinds="SPN"):
        return [cp for cp in cps if cp in unicode_names and categories[cp][0] in kinds]

    def annotated_in(start, end):
        return [cp for cp in range(start, end + 1) if cp in annotated]

    keyboard = list(KEY_NAMES)
    sets = {
        "keyboard": keyboard,
        "arrows": assigned(list(range(0x2190, 0x2200)) + list(range(0x27F5, 0x2800))),
        "math": assigned(
            [0xB1, 0xD7, 0xF7, 0xAC, 0xB0, 0xB5, 0xB9, 0xB2, 0xB3, 0xBC, 0xBD, 0xBE, 0x2032, 0x2033, 0x2034]
            + list(range(0x2070, 0x208F))
            + list(range(0x2150, 0x215F))
            + [0x2103, 0x2109, 0x2189]
            + annotated_in(0x2200, 0x22FF)
            + annotated_in(0x27C0, 0x27EF)
            + annotated_in(0x2980, 0x2AFF)
        ),
        "greek": assigned(list(range(0x391, 0x3AA)) + list(range(0x3B1, 0x3CA)), kinds="L"),
        "currency": assigned([0x24, 0xA2, 0xA3, 0xA4, 0xA5] + list(range(0x20A0, 0x20C1))),
        "punctuation": assigned(
            [0xA1, 0xA6, 0xA7, 0xAB, 0xB6, 0xB7, 0xBB, 0xBF]
            + list(range(0x2010, 0x2028))
            + list(range(0x2030, 0x205F))
            + [0x2105, 0x2116, 0x2117, 0x2120, 0x212E, 0x2E18]
        ),
        "shapes": annotated_in(0x25A0, 0x25FF) + [0x2605, 0x2606],
        "box": assigned(list(range(0x2500, 0x25A0))),
    }
    taken = set(emoji_cps)
    result = {}
    # Keyboard first, so its symbols leave the arrows; then the order of SYMBOL_SETS.
    for name in ["keyboard"] + [s for s in SYMBOL_SETS if s != "keyboard"]:
        cps = []
        for cp in sets[name]:
            if cp in taken or cp in UNDRAWN_SYMBOLS or categories.get(cp, "Z")[0] in "ZC":
                continue
            taken.add(cp)
            cps.append(cp)
        result[name] = cps
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", help="the folder with the downloaded files")
    parser.add_argument("--fetch", action="store_true", help="download the files into the folder first")
    parser.add_argument("--output", default=None, help="the Swift file to write")
    args = parser.parse_args()
    if args.fetch:
        fetch(args.folder)
    here = os.path.dirname(os.path.abspath(__file__))
    output = args.output or os.path.join(here, "..", "Sources", "Emoji", "Catalog", "EmojiData.swift")

    keywords, names = parse_annotations(os.path.join(args.folder, "annotations-en.xml"))
    derived_keywords, derived_names = parse_annotations(os.path.join(args.folder, "annotationsDerived-en.xml"))
    unicode_names, categories = parse_unicode_data(os.path.join(args.folder, "UnicodeData.txt"))
    emoji = parse_emoji_test(os.path.join(args.folder, "emoji-test.txt"))

    common = {}
    for rank, glyph in enumerate(COMMON, start=1):
        common.setdefault(glyph.replace("️", ""), rank)

    lines = []
    emoji_cps = set()
    skipped = 0
    for entry in emoji:
        if version_tuple(entry["version"]) > MAX_EMOJI_VERSION:
            skipped += 1
            continue
        glyph = text(entry["cps"])
        bare = glyph.replace("️", "")
        if len(bare) == 1:
            emoji_cps.add(ord(bare))
        name = title_case(entry["name"])
        words = keywords.get(bare) or derived_keywords.get(bare) or []
        line = [
            glyph,
            name,
            str(entry["group"]),
            entry["version"],
            str(common.get(bare, 0)),
            "|".join(clean_keywords(words, entry["name"])),
            " ".join(lay_out_tones(entry)),
        ]
        lines.append(line)
    found = {line[0].replace("️", "") for line in lines}
    missing = [glyph for glyph in common if glyph not in found]
    if missing:
        raise SystemExit(f"common emoji not in the data: {missing}")

    symbol_count = 0
    for set_name, cps in symbol_sets(names, unicode_names, categories, emoji_cps).items():
        group = GROUPS.index(set_name)
        for cp in cps:
            glyph = chr(cp)
            unicode_name = unicode_names[cp].lower()
            if cp in KEY_NAMES:
                name, extra = KEY_NAMES[cp]
            else:
                name, extra = title_case(names.get(glyph) or unicode_name), []
            words = extra + (keywords.get(glyph) or []) + [unicode_name]
            lines.append([glyph, name, str(group), "", "0", "|".join(clean_keywords(words, name)), ""])
            symbol_count += 1
    lines.sort(key=lambda line: int(line[2]))  # stable: file order inside a group

    for line in lines:
        for field in line:
            if "\n" in field or '"""#' in field:
                raise SystemExit(f"unsafe field in {line}")
        if any(";" in field for field in line[:2]):
            raise SystemExit(f"separator in {line}")

    body = "\n".join("        " + ";".join(line) for line in lines)
    limit = ".".join(str(part) for part in MAX_EMOJI_VERSION)
    cldr = CLDR_RELEASE.split("-")[1]
    quotes = '"' * 3
    swift = "\n".join(
        [
            "// Generated by Tools/generate-data.py. Do not edit by hand: run the script again.",
            "//",
            f"// Sources: Emoji {EMOJI_VERSION} (emoji-test.txt), Unicode {UNICODE_VERSION} (UnicodeData.txt) and",
            f"// CLDR {cldr} (annotations/en.xml, annotationsDerived/en.xml). Emoji newer than {limit} are left out.",
            "// Data license: Unicode License v3, in DATA-LICENSE.txt.",
            "//",
            "// One entry per line: glyph;name;group;version;common rank;keywords;skin tone variants",
            "",
            "extension EmojiData {",
            "    /// The releases the data came from.",
            f'    nonisolated static let sourceVersion = "Emoji {EMOJI_VERSION}, Unicode {UNICODE_VERSION}, CLDR {cldr}"',
            "",
            "    /// The newest Emoji version in the data.",
            f'    nonisolated static let newestEmojiVersion = "{limit}"',
            "",
            f"    /// {len(lines)} entries: {len(lines) - symbol_count} emoji and {symbol_count} symbols.",
            f"    nonisolated static let text = #{quotes}",
            body,
            f"        {quotes}#",
            "}",
            "",
        ]
    )
    with open(output, "w", encoding="utf-8") as file:
        file.write(swift)
    license_source = os.path.join(args.folder, "unicode-license.txt")
    if os.path.exists(license_source):
        with open(os.path.join(here, "..", "DATA-LICENSE.txt"), "w", encoding="utf-8") as file:
            file.write(open(license_source, encoding="utf-8").read())
    print(
        f"wrote {len(lines)} entries: {len(lines) - symbol_count} emoji, {symbol_count} symbols; "
        f"left out {skipped} emoji newer than {limit}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
