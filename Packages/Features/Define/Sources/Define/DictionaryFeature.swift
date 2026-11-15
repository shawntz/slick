import Kit

/// Dictionary: look up a word in the Mac's own dictionaries, and check spelling.
///
/// - Define Word shows a readable page for an entry: the word, its pronunciation and its senses
///   in paragraphs. With no entry it lists spelling suggestions. With no word it opens a page that
///   looks up what is typed. It is also the fallback for typed text.
/// - Check Spelling lists the spell checker's suggestions. Return copies the chosen one, or pastes
///   it if the user chose that in settings.
/// - "define <term>" and "spell <word>" work in root search, and selected text gets Define
///   Word and Check Spelling as universal actions.
/// - Every lookup goes through ``LookupService``: Dictionary Services and the spell checker in the
///   app, fixtures elsewhere. Nothing is looked up at activation and nothing is stored.
public final class DictionaryFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "dictionary", name: DefineStrings.featureName, icon: WordRows.definitionIcon,
        summary: DefineStrings.summary,
        permissions: [PermissionNeed(.accessibility, reason: DefineStrings.accessibilityReason)])

    static let defineID = "define"
    static let spellID = "spell"
    static let wordArgument = "word"

    let pages: DictionaryPages
    let provider: KeywordProvider
    private let selectedText: UniversalActionProvider

    /// Does no I/O. The live service touches nothing until a lookup runs.
    public init(context: FeatureContext) {
        pages = DictionaryPages(context: context, lookup: Lookup(service: context.service(LookupServiceKey.self)))
        provider = KeywordProvider(pages: pages)
        selectedText = .text { [pages] text in pages.universalActions(for: text) }
    }

    public var commands: [Command] {
        [
            Command(
                id: Self.defineID, title: DefineStrings.defineCommand, icon: WordRows.definitionIcon,
                keywords: DefineStrings.defineKeywords,
                arguments: [
                    CommandArgument(Self.wordArgument, placeholder: DefineStrings.wordPlaceholder, isOptional: true)
                ],
                fallback: Fallback { DefineStrings.fallback($0) }
            ) { [pages] context in
                try await pages.define(context.arguments[Self.wordArgument] ?? "")
            },
            Command(
                id: Self.spellID, title: DefineStrings.spellCommand, icon: .symbol("textformat.abc.dottedunderline"),
                keywords: DefineStrings.spellKeywords,
                arguments: [
                    CommandArgument(Self.wordArgument, placeholder: DefineStrings.wordPlaceholder, isOptional: true)
                ]
            ) { [pages] context in
                try pages.spell(context.arguments[Self.wordArgument] ?? "")
            },
        ]
    }

    public var liveProviders: [LiveProvider] {
        [.async(provider)]
    }

    public var universalActions: [UniversalActionProvider] {
        [selectedText]
    }

    public var settingsPane: SettingsPane? {
        DefineSettings.pane { context in
            try await context.workspace.launch(bundleID: DictionaryPages.dictionaryBundleID)
        }
    }
}
