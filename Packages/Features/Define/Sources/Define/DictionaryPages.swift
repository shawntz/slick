import Foundation
import Kit

/// Makes the feature's pages and actions. Shared by the commands, the list pages, the root search
/// provider and the universal actions, so a word behaves the same wherever it shows.
///
/// Lookups run off the main thread in ``Lookup``. The main actor only builds rows and actions from
/// finished values.
final class DictionaryPages {
    /// Dictionary.app, for the Open in Dictionary icon and the settings button.
    nonisolated static let dictionaryBundleID = "com.apple.Dictionary"

    let context: FeatureContext
    let lookup: Lookup

    init(context: FeatureContext, lookup: Lookup) {
        self.context = context
        self.lookup = lookup
    }

    // MARK: Commands

    /// Define Word: the definition page when an entry is found, otherwise a list of spelling
    /// suggestions. With no text, a list to type into.
    func define(_ text: String) async throws -> ActionOutcome {
        switch LookupTerm.read(text) {
        case .failure(.empty):
            return .push(lookupList(initialQuery: ""))
        case .failure(.tooLong):
            throw ActionFailure(DefineStrings.tooLongTitle, message: DefineStrings.tooLongMessage)
        case .success(let term):
            if let definition = try await lookup.definition(of: term) {
                return .push(definitionPage(definition))
            }
            return .push(lookupList(initialQuery: term.text))
        }
    }

    /// Check Spelling: the spelling list, with the word already typed.
    func spell(_ text: String) throws -> ActionOutcome {
        switch LookupTerm.read(text) {
        case .failure(.empty): return .push(spellingList(initialQuery: ""))
        case .failure(.tooLong): throw ActionFailure(DefineStrings.tooLongTitle, message: DefineStrings.tooLongMessage)
        case .success(let term): return .push(spellingList(initialQuery: term.text))
        }
    }

    // MARK: Pages

    /// A readable page for one entry: the word, its pronunciation and its senses in paragraphs.
    func definitionPage(_ definition: Definition) -> Page {
        .detail(
            DetailPage(
                title: definition.headword, detail: .markdown(definition.markdown),
                actions: definitionPageActions(definition)))
    }

    /// A list that looks up what is typed: the entry with its definition beside it, or spelling
    /// suggestions when there is none.
    func lookupList(initialQuery: String) -> Page {
        .list(
            ListPage(
                WordList(mode: .define, pages: self), searchPlaceholder: DefineStrings.defineSearchPlaceholder,
                showsDetail: true,
                emptyState: EmptyState(
                    icon: WordRows.definitionIcon, title: DefineStrings.typeAWordTitle,
                    message: DefineStrings.defineHint),
                initialQuery: initialQuery))
    }

    /// A list that checks the spelling of what is typed.
    func spellingList(initialQuery: String) -> Page {
        .list(
            ListPage(
                WordList(mode: .spell, pages: self), searchPlaceholder: DefineStrings.spellSearchPlaceholder,
                emptyState: EmptyState(
                    icon: WordRows.spellingIcon, title: DefineStrings.typeAWordTitle, message: DefineStrings.spellHint),
                initialQuery: initialQuery))
    }

    // MARK: Actions

    /// A row's actions, from its payload alone.
    func actions(for row: Row) -> [Action] {
        guard let item = try? row.payload?.decode(WordRow.self) else { return [] }
        switch item.role {
        case .definition:
            return [
                showDefinition(item.word), copyDefinition(of: item.word).with(shortcut: .secondaryAction),
                pasteDefinition(of: item.word), openInDictionary(item.word), copyWord(item.word).with(shortcut: .copy),
            ]
        case .suggestion:
            return [
                showDefinition(item.word), copyWord(item.word).with(shortcut: .secondaryAction), pasteWord(item.word),
                openInDictionary(item.word),
            ]
        case .spelling:
            let copy = copyWord(item.word)
            let paste = pasteWord(item.word)
            let pair =
                context.settings[DefineSettings.spellingReturn] == .paste
                ? [paste, copy.with(shortcut: .secondaryAction)] : [copy, paste.with(shortcut: .secondaryAction)]
            return pair + [showDefinition(item.word), openInDictionary(item.word)]
        }
    }

    /// The definition page's actions. Return copies the definition.
    func definitionPageActions(_ definition: Definition) -> [Action] {
        [
            Action.copy(
                definition.plainText, title: DefineStrings.copyDefinition, hud: DefineStrings.copiedDefinition
            ).with(id: "copy-definition"),
            Action.paste(definition.plainText, title: DefineStrings.pasteDefinition, shortcut: .secondaryAction)
                .with(id: "paste-definition"),
            openInDictionary(definition.headword),
            copyWord(definition.headword).with(shortcut: .copy),
        ]
    }

    /// Selected text: Define Word, and Check Spelling for a single word.
    func universalActions(for text: String) -> [Action] {
        guard let term = LookupTerm.make(text) else { return [] }
        var actions = [
            Action(DefineStrings.defineAction, id: "define", icon: WordRows.definitionIcon) { [self] _ in
                try await define(term.text)
            }
        ]
        if term.isSingleWord {
            actions.append(
                Action(DefineStrings.spellAction, id: "spell", icon: WordRows.spellingIcon) { [self] _ in
                    try spell(term.text)
                })
        }
        return actions
    }

    func showDefinition(_ word: String) -> Action {
        Action(DefineStrings.showDefinition, id: "show-definition", icon: WordRows.definitionIcon) { [self] _ in
            let definition = try await requireDefinition(of: word)
            return .push(definitionPage(definition))
        }
    }

    func copyDefinition(of word: String) -> Action {
        Action.copy(
            title: DefineStrings.copyDefinition, hud: DefineStrings.copiedDefinition,
            content: { [self] _ in
                let definition = try await requireDefinition(of: word)
                return .text(definition.plainText)
            }
        ).with(id: "copy-definition")
    }

    func pasteDefinition(of word: String) -> Action {
        Action.paste(
            title: DefineStrings.pasteDefinition,
            content: { [self] _ in
                let definition = try await requireDefinition(of: word)
                return .text(definition.plainText)
            }
        ).with(id: "paste-definition")
    }

    func copyWord(_ word: String) -> Action {
        Action.copy(word, title: DefineStrings.copyWord, hud: DefineStrings.copiedWord).with(id: "copy-word")
    }

    func pasteWord(_ word: String) -> Action {
        Action.paste(word, title: DefineStrings.pasteWord).with(id: "paste-word")
    }

    /// Opens the word in Dictionary.app through the workspace service, with a `dict://` link.
    func openInDictionary(_ word: String) -> Action {
        Action(
            DefineStrings.openInDictionary, id: "open-in-dictionary",
            icon: .app(bundleID: Self.dictionaryBundleID), shortcut: .open
        ) { context in
            guard let url = Self.dictionaryURL(for: word) else {
                throw ActionFailure(DefineStrings.noDefinitionTitle, message: DefineStrings.noDefinitionMessage(word))
            }
            context.dismiss()
            try await context.workspace.open(url)
            return .close()
        }
    }

    /// The entry for a word, or a failure the host shows as a toast.
    func requireDefinition(of word: String) async throws -> Definition {
        guard let term = LookupTerm.make(word), let definition = try await lookup.definition(of: term) else {
            throw ActionFailure(DefineStrings.noDefinitionTitle, message: DefineStrings.noDefinitionMessage(word))
        }
        return definition
    }

    /// Characters a `dict://` link keeps as they are. Everything else, spaces and letters outside
    /// ASCII included, is percent-encoded as UTF-8.
    nonisolated static let linkCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// `dict://<word>`, which opens the word in Dictionary.app. Nil for an empty word.
    nonisolated static func dictionaryURL(for word: String) -> URL? {
        guard let term = LookupTerm.make(word),
            let encoded = term.text.addingPercentEncoding(withAllowedCharacters: linkCharacters)
        else { return nil }
        return URL(string: "dict://" + encoded)
    }
}
