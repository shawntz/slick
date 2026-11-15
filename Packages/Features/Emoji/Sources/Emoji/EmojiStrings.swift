/// Every string of the feature that a person reads, in one place so it can be translated. Emoji
/// and symbol names come from the data file instead.
nonisolated enum EmojiStrings {
    // MARK: Feature and command

    static let featureName = "Emoji and Symbols"
    static let summary = "Find emoji and symbols by name and paste them into any app."
    static let accessibilityReason = "Paste the chosen emoji or symbol into the frontmost app."
    static let searchCommand = "Search Emoji and Symbols"
    static let searchKeywords = ["emoji", "emoticon", "smiley", "symbol", "character", "unicode", "arrow", "math"]

    // MARK: Grid

    static let pageTitle = "Emoji and Symbols"
    static let searchPlaceholder = "Search emoji and symbols"
    static let pinnedSection = "Pinned"
    static let recentlyUsed = "Recently Used"
    static let categoryFilter = "Category"
    static let allCategories = "All Categories"
    static let emojiFilterSection = "Emoji"
    static let symbolsFilterSection = "Symbols"
    static let noMatchesTitle = "No Matching Emoji or Symbols"
    static let noMatchesMessage = "Try another word, such as heart or arrow."
    static let dataUnreadable = "The emoji data could not be read."

    static func groupTitle(_ group: EmojiGroup) -> String {
        switch group {
        case .smileys: "Smileys & Emotion"
        case .people: "People & Body"
        case .animals: "Animals & Nature"
        case .food: "Food & Drink"
        case .travel: "Travel & Places"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        case .arrows: "Arrows"
        case .math: "Math"
        case .greek: "Greek Letters"
        case .currency: "Currency"
        case .punctuation: "Punctuation"
        case .keyboard: "Keyboard"
        case .shapes: "Shapes"
        case .boxDrawing: "Box Drawing"
        }
    }

    // MARK: Root search

    static let emojiSubtitle = "Emoji"
    static let symbolSubtitle = "Symbol"

    // MARK: Actions

    static func paste(_ name: String) -> String { "Paste \(name)" }
    static func copy(_ name: String) -> String { "Copy \(name)" }
    static func copied(_ glyph: String) -> String { "Copied \(glyph)" }
    static let pasteWithSkinTone = "Paste with Skin Tone"
    static let copyWithSkinTone = "Copy with Skin Tone"
    static let twoSkinTones = "Two Skin Tones"
    static let copyName = "Copy Name"
    static let copiedName = "Copied the name"
    static let copyCodePoints = "Copy Code Points"
    static let copiedCodePoints = "Copied the code points"
    static let pin = "Pin to Top"
    static let unpin = "Unpin"
    static func pinnedToast(_ glyph: String) -> String { "Pinned \(glyph) to the top of the grid" }
    static func unpinnedToast(_ glyph: String) -> String { "Unpinned \(glyph)" }

    static func toneTitle(_ tone: SkinTone) -> String {
        switch tone {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-Light"
        case .medium: "Medium"
        case .mediumDark: "Medium-Dark"
        case .dark: "Dark"
        }
    }

    /// One tone for each of two people, such as "Light and Dark".
    static func toneTitle(_ first: SkinTone, _ second: SkinTone) -> String {
        "\(toneTitle(first)) and \(toneTitle(second))"
    }

    // MARK: Settings

    static let behaviorSection = "Behavior"
    static let skinTone = "Skin tone"
    static let skinToneInfo = "Applies to every emoji that comes in skin tones."
    static let returnAction = "Return"
    static let returnPastes = "Pastes into the frontmost app"
    static let returnCopies = "Copies to the clipboard"
    static let includeSymbols = "Show symbols"
    static let includeSymbolsInfo =
        "Adds arrows, math, currency, punctuation, keyboard and box drawing symbols to the grid."
    static let colonSearch = "Find emoji in the main search with a colon"
    static let colonSearchInfo = "Type a colon and a name, such as :smile, to see matching emoji at the top."
    static let recentSection = "Recently Used"
    static let recentCount = "Emoji to show"
    static let recentCountInfo = "Set to 0 to hide the Recently Used section."
    static let clearRecents = "Clear Recently Used"
    static let clearRecentsQuestion = "Clear recently used emoji?"
    static let clearRecentsMessage = "The grid and the colon search forget which emoji and symbols you used."
    static let clearRecentsConfirm = "Clear"
    static let clearedRecents = "Cleared recently used emoji"
    static func dataNote(_ version: String) -> String { "Data from Unicode: \(version)." }
}
