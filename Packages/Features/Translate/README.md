# Translate

Translates text with Apple's Translation framework and the languages installed on the Mac. The feature sends nothing over the network itself and starts no download. Whether the system's translation service keeps everything on the Mac has not been watched in a live run. Read it next to `docs/FEATURES.md`.

The package is `Translate`, the module and product are `TranslateCommands` and the class is `TranslateFeature`. The module is not called `Translate` or `Translation`, so it can never be confused with the SDK's Translation framework. The feature ID is `translate`.

## What it declares

| Kind | What |
|---|---|
| Command `translate` | Translate. Opens a page that translates the text in the search field. A menu picks the language to translate into and opens on the one picked last. The detail shows the translation large, with the recognized language above it. It takes the root query on Tab, and is a fallback that starts off. |
| Command `translate-selection` | Translate Selection. Reads the text selected in the app in front and opens the same page with it. Needs Accessibility. Stays out of deep links. |
| Instant provider, namespace `translate` | `translate <text>` or `tr <text>`, optionally ending in `to <language>`, shows one row at the top that fills with the translation when it arrives. A query that is still the start of "Translate Selection" gets no row, so the command keeps its place and its Return. |
| Settings pane | the first and second language, the keywords, Translation Languages in System Settings, Accessibility, and what the feature stores and sends. |

The page's actions are Copy Translation on Return, Paste Translation on Command-Return, Swap Languages on Shift-Command-S and Copy Original on Shift-Command-C. A root row adds Open in Translate on Command-O. When a pair is not installed, the row names the language to download and Return opens Translation Languages in System Settings through the workspace service.

## Where to look

| File | Shows |
|---|---|
| `Engine/TranslationEngine.swift` | the feature's own service, its `FeatureServiceKey`, pair status and failures |
| `Engine/SystemTranslation.swift` | the live engine: `LanguageAvailability` and `TranslationSession(installedSource:target:)` |
| `Engine/LanguageRecognizer.swift` | the NaturalLanguage recognizer that names a text's language |
| `Engine/SimulatedTranslation.swift` | the isolated engine: made-up phrases and the three states a pair can be in |
| `Languages/LanguageTag.swift`, `Languages/LanguageCatalog.swift` | languages, their names in the user's language and in English, and how guesses and settings resolve |
| `Translating/TranslationPipeline.swift` | recognize, choose the target, check the pair, translate, all off the main thread |
| `Translating/TranslationRows.swift`, `Translating/TranslationText.swift` | rows, details, limits and Markdown |
| `Translating/Translator.swift` | the language list, loaded once per activation, and the plan each request needs |
| `Pages/TranslatePages.swift`, `Pages/TranslateList.swift` | the page and every row's actions |
| `RootSearch/RootKeyword.swift`, `RootSearch/KeywordProvider.swift` | root search |
| `TranslateSettings.swift`, `TranslateStrings.swift` | settings, and every string a person reads |

## How the engine works without a window

`TranslationSession(installedSource:target:)`, new in macOS 26, makes a session with no SwiftUI view. It translates with installed languages only, cannot ask for a download, and throws `TranslationError.notInstalled` when a language is missing. The SDKs for macOS 26.5 and 27.2 declare the same interface. So the feature needs no SwiftUI host.

- The source language comes from `NLLanguageRecognizer`, since the session needs one.
- `LanguageAvailability().status(from:to:)` says whether a pair is installed, supported or unsupported. A pair that is supported but not installed is checked against other languages to tell which side is missing; when nothing tells, both are named.
- Each translation makes its own session in a `@concurrent` function, so the session never crosses a thread. A cancelled task cancels the session's requests.
- Translation Languages opens with `x-apple.systempreferences:com.apple.Localization-Settings.extension?translation`, the link the system's own translation extension uses.

## Rules this feature follows

- Activation lists the languages off the main thread and starts one settings listener. It translates nothing, reads no selection and asks for nothing.
- Root search turns away any query that does not start with "t" on its first byte, with no allocation. A keyword query costs a few microseconds. The translation starts after a 200 ms pause, off the main thread, and the next query cancels it.
- The page filters itself with a 250 ms debounce. Each load is one translation in a task the host cancels.
- Rows are answers to one query, so root search remembers none of them.
- Titles are one line, drawn in their stored order through `DisplayText`. Markdown signs in a translation show as written.
- Root search translates up to 1,000 bytes and the page up to 10,000. Longer text is refused after reading one byte past the limit.
- Tests use `SimulatedTranslation` and doubles. The recognizer's tests run NaturalLanguage on made-up sentences. Nothing calls the Translation framework outside the app. `TRANSLATE_BENCHMARK=1` runs the benchmarks.
