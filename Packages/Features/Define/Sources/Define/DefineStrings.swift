/// Every string of the feature that a person reads, in one place so it can be translated later.
/// Command, action, section, empty-state, toast and HUD titles use title case, as macOS menus do,
/// and end without a full stop. Everything else is a plain sentence. Definitions themselves come
/// from the dictionaries, in their own language.
nonisolated enum DefineStrings {
    // MARK: Feature

    static let featureName = "Dictionary"
    static let summary = "Look up words in the Mac's own dictionaries and check their spelling."
    static let accessibilityReason = "Paste a definition or a chosen word into the frontmost app."

    // MARK: Commands

    static let defineCommand = "Define Word"
    static let defineKeywords = ["define", "dictionary", "definition", "meaning", "look up", "lookup", "word"]
    static let spellCommand = "Check Spelling"
    static let spellKeywords = ["spell", "spelling", "spellcheck", "spell check", "misspelling", "suggestions"]
    static let wordPlaceholder = "Word"

    /// The most characters of the typed text a fallback title shows.
    static let fallbackTextLimit = 60

    /// A fallback row under root results. Root search builds it on every keystroke, so it reads
    /// only the start of what was typed.
    static func fallback(_ text: String) -> String {
        let shown = text.prefix(fallbackTextLimit)
        let more = text.dropFirst(fallbackTextLimit).isEmpty ? "" : "…"
        return "Define \"\(shown)\(more)\""
    }

    // MARK: Pages

    static let defineSearchPlaceholder = "Type a word to define"
    static let spellSearchPlaceholder = "Type a word to check"
    static let definitionSection = "Definition"
    static let didYouMeanSection = "Did You Mean"
    static let suggestionsSection = "Suggestions"
    static let suggestedSpelling = "Suggested spelling"
    static let spelledCorrectly = "Spelled correctly"
    static let notInDictionary = "Not in the spell checker's dictionary"
    static let unchecked = "No spelling language on this Mac covers this word"

    static let typeAWordTitle = "Type a Word"
    static let defineHint = "Definitions come from the dictionaries turned on in the Dictionary app."
    static let spellHint = "Suggestions come from the spell checker in macOS."
    static let tooLongTitle = "Too Long to Look Up"
    static let tooLongMessage = "Type a word or a short phrase of up to 80 characters."
    static let noDefinitionTitle = "No Definition Found"
    static func noDefinitionMessage(_ term: String) -> String {
        "None of the dictionaries turned on in the Dictionary app has an entry for “\(term)”."
    }
    static let oneWordTitle = "Type One Word"
    static let oneWordMessage = "The spell checker suggests spellings for one word at a time."

    // MARK: Actions

    static let showDefinition = "Show Definition"
    static let copyDefinition = "Copy Definition"
    static let copiedDefinition = "Copied Definition"
    static let pasteDefinition = "Paste Definition"
    static let openInDictionary = "Open in Dictionary"
    static let copyWord = "Copy Word"
    static let copiedWord = "Copied Word"
    static let pasteWord = "Paste Word"
    static let defineAction = "Define Word"
    static let spellAction = "Check Spelling"

    // MARK: Root search

    static let rootDefinitionSection = "Definition"
    static let rootSpellingSection = "Spelling"
    static let rootDictionarySection = "Dictionary"

    // MARK: Settings

    static let mainSearchSection = "Root Search"
    static let keywordsToggle = "Use the define and spell keywords"
    static let keywordsInfo =
        "Type define or spell, a space and a word to see a definition or spelling suggestions in root search."
    static let singleWordsToggle = "Show a definition when you type a single word"
    static let singleWordsInfo =
        "The definition appears under the other results after a short pause. Each pause looks the word up in the dictionaries on this Mac."
    static let spellingSection = "Spelling"
    static let spellingReturn = "Return on a spelling"
    static let spellingReturnCopies = "Copies it to the clipboard"
    static let spellingReturnPastes = "Pastes it into the frontmost app"
    static let spellingReturnInfo = "Command-Return does the other."
    static let accessibilityInfo = "Paste Definition and Paste Word need it to paste into the frontmost app."
    static let dictionariesSection = "Dictionaries"
    static let sourcesNote =
        "Definitions come from the dictionaries turned on in the Dictionary app's settings. Spelling suggestions come from the spell checker in macOS and the spelling languages chosen in System Settings."
    static let openDictionary = "Open Dictionary"
    static let openDictionaryInfo = "Opens the Dictionary app, where its settings choose which dictionaries to use."
    static let privacySection = "Privacy"
    static let privacyNote =
        "Dictionary stores nothing and keeps no history of what you look up, and it sends nothing over the network itself. Lookups use the dictionaries and the spell checker on this Mac. If you turn on Wikipedia in the Dictionary app's settings, macOS may look words up on wikipedia.org."
}
