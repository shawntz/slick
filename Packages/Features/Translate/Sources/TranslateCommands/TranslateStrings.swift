/// Every string of the feature that a person reads, in one place so it can be translated later.
/// Command, action, section, empty-state, toast and HUD titles use title case, as macOS menus do,
/// and end without a full stop. Everything else is a plain sentence. Language names come from
/// Foundation.
nonisolated enum TranslateStrings {
    // MARK: Feature

    static let featureName = "Translate"
    static let summary =
        "Translate text with the languages installed on this Mac. Translate sends nothing over the network itself."
    static let accessibilityReason = "Read the text selected in the frontmost app, and paste a translation into it."

    // MARK: Commands

    static let translateCommand = "Translate"
    static let translateKeywords = ["translate", "translation", "tr", "language"]
    static let selectionCommand = "Translate Selection"
    static let selectionKeywords = ["translate", "translation", "selection", "selected text", "language"]

    /// The most characters of the typed text a fallback title shows.
    static let fallbackTextLimit = 60

    /// A fallback row under root results. Root search builds it on every keystroke, so it reads
    /// only the start of what was typed.
    static func fallback(_ text: String) -> String {
        let shown = text.prefix(fallbackTextLimit)
        let more = text.dropFirst(fallbackTextLimit).isEmpty ? "" : "…"
        return "Translate \u{201C}\(shown)\(more)\u{201D}"
    }

    // MARK: Page

    static let searchPlaceholder = "Type text to translate"
    static let dropdownTitle = "Translate Into"
    static let typeTextTitle = "Type Text to Translate"
    static let typeTextMessage = "The translation is made on this Mac with the languages installed on it."
    static let tooLongTitle = "Text Too Long"
    static let tooLongMessage = "Translate up to 10,000 bytes of text at a time. Use less text, then try again."
    static let rootTooLongMessage = "Root search translates short text. Open Translate for longer text."
    static let unavailableTitle = "Translation Is Not Available"
    static let unavailableMessage = "This Mac offers no languages to translate between."

    // MARK: Selection

    static let noSelectionTitle = "No Text Selected"
    static let noSelectionMessage = "Select some text in the app in front, then try again."
    static let selectionTooLongTitle = "Selection Too Long"

    // MARK: Rows

    static let translating = "Translating…"

    static func direction(from source: String, to target: String) -> String {
        "\(source) \u{2192} \(target)"
    }

    static func downloadTitle(_ names: [String]) -> String {
        "Download \(list(names)) to Translate"
    }

    static func notInstalledMessage(_ names: [String]) -> String {
        names.count == 1
            ? "\(list(names)) is not installed on this Mac. Download it in System Settings."
            : "\(list(names)) are not installed on this Mac. Download them in System Settings."
    }

    static func unsupportedLanguageTitle(_ name: String) -> String {
        "Can\u{2019}t Translate \(name)"
    }

    static func unsupportedLanguageMessage(_ name: String) -> String {
        "Translation on this Mac does not support \(name)."
    }

    static func unsupportedPairTitle(_ source: String, _ target: String) -> String {
        "Can\u{2019}t Translate \(source) to \(target)"
    }

    static func unsupportedPairMessage(_ source: String, _ target: String) -> String {
        "This Mac cannot translate from \(source) into \(target)."
    }

    static func alreadyInTitle(_ name: String) -> String {
        "Already in \(name)"
    }

    static let alreadyInMessage =
        "Choose another language to translate into, or set a second language in Translate settings."
    static let notRecognizedTitle = "Language Not Recognized"
    static let notRecognizedMessage = "Type a little more text so its language can be recognized."
    static let failedTitle = "Could Not Translate"
    static let emptyTranslation = "The translation came back empty."

    // MARK: Detail

    static func detectedLine(_ source: String, _ target: String) -> String {
        "Detected \(source), translated into \(target)."
    }

    static let downloadSteps =
        "Languages are downloaded in System Settings, under Language & Region, Translation Languages. Translate never downloads a language by itself."

    // MARK: Actions

    static let copyTranslation = "Copy Translation"
    static let copiedTranslation = "Copied Translation"
    static let pasteTranslation = "Paste Translation"
    static let swapLanguages = "Swap Languages"
    static let copyOriginal = "Copy Original"
    static let copiedOriginal = "Copied Original"
    static let openInTranslate = "Open in Translate"
    static let openLanguageSettings = "Open Translation Languages"

    // MARK: Settings

    static let languagesSection = "Languages"
    static let targetPicker = "Translate into"
    static let targetInfo = "Translate and root search use this language unless you pick another one."
    static func automatic(_ name: String?) -> String {
        name.map { "Automatic, \($0)" } ?? "Automatic"
    }
    static let secondPicker = "Second language"
    static let secondInfo = "Text that is already in the first language is translated into this one."
    static let noSecondLanguage = "None"
    static let rootSearchSection = "Root Search"
    static let keywordsToggle = "Use the translate and tr keywords"
    static let keywordsInfo =
        "Type translate or tr, a space and some text to see its translation in root search. End with to and a language name, such as to French, to pick the language."
    static let downloadsSection = "Downloads"
    static let downloadsNote =
        "Translate uses only the languages installed on this Mac and never downloads one by itself. Download more in System Settings, under Language & Region."
    static let openLanguageSettingsInfo = "Opens Translation Languages in System Settings."
    static let accessibilityInfo =
        "Translate Selection needs it to read the selected text, and Paste Translation to paste."
    static let permissionsSection = "Permissions"
    static let privacySection = "Privacy"
    static let privacyNote =
        "Translate uses Apple's Translation framework with the languages installed on this Mac. Translate sends nothing over the network itself and starts no download, keeps no history of what you translate, and root search remembers none of the rows it shows for translate and tr. It stores only the languages you chose."
    static let unavailableStatus = "Translation Is Not Available"

    /// "French", "French and German", "French, German and Spanish".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}
