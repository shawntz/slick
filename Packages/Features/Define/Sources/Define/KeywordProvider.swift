import Kit

/// Root search's dictionary answers, as Alfred has them.
///
/// - "define <term>" and "spell <word>" claim the query, so root search shows only the entry
///   or the spellings. The settings can turn the keywords off. While the text after "define" could
///   still be the rest of the Define Word command's title, as in "define wo", the query is not
///   claimed: root search shows the command, and the entry in its own section.
/// - With the single-word setting on, a query of one word gets its entry in a section of its own
///   under the other results, at most one row. Root search does not tell a provider what else
///   matched, so the row shows under other results rather than only when nothing else matched.
///
/// ``takesOver(_:)``, ``sectionTitle(for:)`` and ``debounce(for:)`` run inside the keystroke: they
/// turn away any query that does not start with "d" or "s" on its first byte, and read one setting
/// otherwise. Lookups run after the debounce, off the main thread, and stop when root search
/// cancels them.
final class KeywordProvider: AsyncProvider {
    /// Debounce for a keyword query, which the user asked for.
    static let keywordDebounce = Duration.milliseconds(100)
    /// Debounce for a single word, which the user did not ask for: only a real pause looks it up.
    static let singleWordDebounce = Duration.milliseconds(300)

    let namespace = WordRows.namespace
    let sectionTitle = DefineStrings.rootDictionarySection
    private let pages: DictionaryPages

    init(pages: DictionaryPages) {
        self.pages = pages
    }

    var minimumQueryLength: Int { RootQuery.singleWordLengths.lowerBound }
    var maximumRows: Int { 1 }

    func takesOver(_ query: String) -> Bool {
        switch keyword(in: query) {
        case .define(let text): !RootQuery.couldBeCommandTitle(text)
        case .spell: true
        case nil: false
        }
    }

    func sectionTitle(for query: String) -> String {
        switch keyword(in: query) {
        case .define: DefineStrings.rootDefinitionSection
        case .spell: DefineStrings.rootSpellingSection
        case nil: sectionTitle
        }
    }

    func debounce(for query: String) -> Duration {
        keyword(in: query) == nil ? Self.singleWordDebounce : Self.keywordDebounce
    }

    func results(for query: String) async throws -> [Row] {
        switch keyword(in: query) {
        case .define(let text):
            guard let term = LookupTerm.make(text) else { return [] }
            if let definition = try await pages.lookup.definition(of: term) {
                try Task.checkCancellation()
                return [WordRows.definition(definition)]
            }
            guard term.isSingleWord else { return [] }
            let spelling = try await pages.lookup.spelling(of: term)
            try Task.checkCancellation()
            return WordRows.suggestions(spelling.guesses)
        case .spell(let text):
            guard let term = LookupTerm.make(text), term.isSingleWord else { return [] }
            let spelling = try await pages.lookup.spelling(of: term)
            try Task.checkCancellation()
            return WordRows.spelling(term, spelling).flatMap(\.rows)
        case nil:
            guard pages.context.settings[DefineSettings.singleWords], let term = RootQuery.singleWord(query) else {
                return []
            }
            let definition = try await pages.lookup.definition(of: term)
            try Task.checkCancellation()
            // Only the word itself: "colour" may find an entry for another word that lists it.
            guard let definition,
                DefinitionParser.folded(definition.headword) == DefinitionParser.folded(term.text)
            else { return [] }
            return [WordRows.definition(definition)]
        }
    }

    func actions(for row: Row) -> [Action] {
        pages.actions(for: row)
    }

    /// The keyword in a query while the keywords are on. The first byte turns away other queries
    /// before the setting is read.
    private func keyword(in query: String) -> RootQuery? {
        guard let keyword = RootQuery.keyword(in: query), pages.context.settings[DefineSettings.keywords] else {
            return nil
        }
        return keyword
    }
}
