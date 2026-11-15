# Dictionary

Looks up words in the Mac's own dictionaries and checks spelling. Read it next to `docs/FEATURES.md`.

The package and module are called `Define` because `Dictionary` is a Swift type. The feature ID is `dictionary`.

## What it declares

| Kind | What |
|---|---|
| Command `define` | Define Word, with one optional argument, `word`. A found entry opens a readable page: the word, its syllables and pronunciation, and its senses in paragraphs. A word with no entry gets a list of spelling suggestions. No word opens a page that looks up what you type. It is also the fallback: Define "typed text". |
| Command `spell` | Check Spelling, with one optional argument, `word`. The word as typed with the spell checker's verdict, then its suggestions. Return copies the chosen word and Command-Return pastes it. Settings can swap the two. |
| Async provider, namespace `dictionary` | `define <term>` and `spell <word>` in root search claim the query, as in Alfred. With the single-word setting on, a word's entry shows under the other results. |
| Universal actions | Define Word for selected text, and Check Spelling for a selected word. |
| Settings pane | the keywords, single words in root search, what Return does on a spelling, Accessibility for pasting, where the dictionaries come from, and what the feature stores and sends. |

The actions are Show Definition, Copy Definition, Paste Definition, Open in Dictionary, Copy Word and Paste Word. Open in Dictionary opens a `dict://` link through the workspace service. Pasting needs Accessibility, and the host asks for it only when the user picks a paste action.

## Where to look

| File | Shows |
|---|---|
| `Lookup/LookupService.swift` | the feature's own service, its `FeatureServiceKey` and the spelling verdict |
| `Lookup/SystemLookup.swift` | the live service: Dictionary Services and the shared spell checker, called one at a time on an actor off the main thread |
| `Lookup/FixtureLookup.swift` | the isolated service: entries and spellings written by hand in the system's shape |
| `Lookup/Lookup.swift` | how typed text becomes a term, and lookups parsed off the main thread |
| `Definition/DefinitionParser.swift` | the pure parser from the system's plain text to headword, pronunciation and paragraphs |
| `Definition/DefinitionText.swift` | the summary, the plain text for copying and the escaped Markdown for the page |
| `WordRows.swift` | rows and their payloads, and the parsing of root queries |
| `DictionaryPages.swift` | pages and actions, shared by commands, lists, root search and universal actions |
| `WordList.swift` | the list that filters itself, behind Define Word's typing page and Check Spelling |
| `KeywordProvider.swift` | root search |
| `DefineSettings.swift`, `DefineStrings.swift` | settings, and every string a person reads |

## Rules this feature follows

- No lookup runs on the main actor. The live service makes `NSSpellChecker.shared` on the main actor the first time it is needed, once per launch. Every other call runs on one actor, so the two system APIs are never called from two of the feature's threads at once.
- Each lookup checks for cancellation before and after the system call. When root search or a list cancels a task because the query changed, its answer never shows.
- Typed text is cleaned before any lookup: one line, single spaces, no control or direction characters, no characters made only of invisible marks such as a zero-width space, at most 80 characters. Longer text is refused after reading 320 characters, so a pasted paragraph costs the same as a word.
- The parser cuts the text at parts of speech, sense numbers in order, bullets and the dictionary's section labels. Every character lands in some paragraph. Text it cannot split, such as an entry from a dictionary in another language, is shown whole.
- The dictionary's text is escaped before it becomes Markdown, so brackets and asterisks show as written.
- Nothing happens at activation. Nothing is stored. Rows are answers to one query, so root search remembers none of them.
- The feature makes no network request. Dictionary Services ships a Wikipedia source that a user can turn on in the Dictionary app, and whether the text API then asks wikipedia.org has not been checked live, so the settings pane says that macOS may.
- Tests use `FixtureLookup` and a recording double. Only the opt-in suite `Live` calls the system, with `DEFINE_LIVE_TEST=1`. `DEFINE_BENCHMARK=1` runs the benchmarks.
