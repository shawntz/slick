# Emoji and Symbols

Find emoji and symbols by name and paste them into the app you were using.

## What it declares

| Kind | What |
|---|---|
| Command `search` | Search Emoji and Symbols: a grid with Pinned, Recently Used, Unicode's emoji groups and eight symbol sets |
| Instant provider `emoji` | `:name` in root search, such as `:smile`, offers up to six matches at the top |
| Settings pane | default skin tone, what Return does, symbols on or off, colon search on or off, how many recent emoji, Clear Recently Used |
| Permission | Accessibility, to paste into the frontmost app |

Rows use the namespace `emoji` and the key of the emoji without a skin tone: its code points in lowercase hex without U+FE0F, joined by "-", such as `emoji:1f44d`. Rows are `.learnOnly`, so root learns from them but keeps no snapshot.

## Actions

| Action | ID | Shortcut |
|---|---|---|
| Paste the emoji, titled with its name | `paste` | Return, or Command-Return when Return copies |
| Copy the emoji | `copy` | Command-Return, or Return |
| Paste with Skin Tone | `paste-with-skin-tone` | Option-Command-V |
| Copy with Skin Tone | `copy-with-skin-tone` | Option-Command-C |
| Pin to Top, or Unpin | `pin`, `unpin` | Command-Period |
| Copy Name | `copy-name` | Shift-Command-C |
| Copy Code Points | `copy-code-points` | Option-Shift-Command-C |

The skin tone menus show only for emoji that take a tone. Two-person emoji also offer every mix of two tones.

Pins are kept in the `pinned` setting as keys, in the order they were pinned. They show under Pinned above Recently Used, and rank first among equal matches in the grid and the colon search.

## Ranking

Inside one match tier, pins come first, then recent use, then the ten most used emoji in their order. Every other common emoji shares one score and the rest share another, so the matcher's own order decides among them: a name that starts with the query comes before a keyword match, and a shorter name comes first. So "grinning" finds Grinning Face before Beaming Face with Smiling Eyes, which only has the keyword, and "heart" still finds Red Heart. Colon search applies the same order itself. In the grid the host filters, and KitTesting's fake index orders equal tiers by title length alone, so `gridOrder` in the tests applies the engine's title-first rule.

## The data

`Sources/Emoji/Catalog/EmojiData.swift` is generated. It holds one line per emoji or symbol: glyph, name, group, Emoji version, common rank, keywords and skin tone variants. The data is Swift source rather than a resource file because the app bundle does not carry SwiftPM resource bundles.

| Source | Release |
|---|---|
| `emoji-test.txt` | Emoji 18.0 |
| `UnicodeData.txt` | Unicode 18.0.0 |
| CLDR `annotations/en.xml`, `annotationsDerived/en.xml` | CLDR 49 |

Emoji newer than 16.0 are left out, because macOS 26.0 draws Emoji 16.0. The data is under the Unicode License v3, in `DATA-LICENSE.txt`.

To regenerate, from this folder:

```
python3 -I Tools/generate-data.py --fetch <an empty folder>
```

`--fetch` downloads the five files from unicode.org and the CLDR repository into that folder, then writes the Swift file and the license. Without `--fetch`, the script reads files already in the folder. Then run the tests: `DataTests` measures every emoji and symbol with the system font and fails for one that does not draw.

## Where to look

| File | Holds |
|---|---|
| `EmojiFeature.swift` | the feature: manifest, command, provider, settings pane, activation |
| `EmojiLibrary.swift` | the loaded catalog and index, built off the main thread |
| `EmojiGrid.swift` | the grid's list source, filtered by the host |
| `EmojiRows.swift` | rows and sections, and the ranking within a match tier |
| `EmojiActions.swift` | actions from the row's key alone |
| `ColonSearch.swift`, `ColonIndex.swift` | the instant provider and its byte-level prefix index |
| `EmojiStrings.swift` | every string a person reads |
| `Catalog/` | the entry type, the parser and the generated data |
| `Tests/EmojiTests/Benchmark.swift` | the budgets; run with `EMOJI_BENCHMARK=1` in release |
