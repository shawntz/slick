import Kit

/// The list behind Define Word's typing page and Check Spelling. It filters itself: each query is
/// one lookup, run after the host's debounce in a task the host cancels when the query changes.
/// A cancelled lookup throws, so its answer never reaches the page.
final class WordList: ListSource {
    enum Mode {
        /// The entry for what is typed, with its definition beside it, or spelling suggestions.
        case define
        /// The spell checker's verdict on one word and its suggestions.
        case spell
    }

    /// Long enough that a lookup waits for a pause in typing, short enough to feel live.
    static let debounce = Duration.milliseconds(150)

    let mode: Mode
    private let pages: DictionaryPages
    /// The entry the last load found, so the detail pane can show it without looking it up again.
    private var shown: Definition?

    init(mode: Mode, pages: DictionaryPages) {
        self.mode = mode
        self.pages = pages
    }

    var filtering: ListFiltering { .custom(debounce: Self.debounce) }

    func load(_ request: ListRequest) async throws -> ListResult {
        switch LookupTerm.read(request.query) {
        case .failure(.empty):
            shown = nil
            return ListResult(rows: [])
        case .failure(.tooLong):
            shown = nil
            return ListResult(
                rows: [],
                emptyState: EmptyState(
                    icon: WordRows.definitionIcon, title: DefineStrings.tooLongTitle,
                    message: DefineStrings.tooLongMessage))
        case .success(let term):
            switch mode {
            case .define: return try await loadDefinition(term)
            case .spell: return try await loadSpelling(term)
            }
        }
    }

    private func loadDefinition(_ term: LookupTerm) async throws -> ListResult {
        let definition = try await pages.lookup.definition(of: term)
        try Task.checkCancellation()
        shown = definition
        if let definition {
            return ListResult(
                sections: [
                    ListSection(
                        DefineStrings.definitionSection, id: "definition", rows: [WordRows.definition(definition)])
                ])
        }
        let noEntry = EmptyState(
            icon: WordRows.definitionIcon, title: DefineStrings.noDefinitionTitle,
            message: DefineStrings.noDefinitionMessage(term.text))
        // Guesses for a phrase are guesses for its letters, not its words, so only a word gets them.
        guard term.isSingleWord else { return ListResult(rows: [], emptyState: noEntry) }
        let spelling = try await pages.lookup.spelling(of: term)
        try Task.checkCancellation()
        return ListResult(
            sections: [
                ListSection(
                    DefineStrings.didYouMeanSection, id: "suggestions", rows: WordRows.suggestions(spelling.guesses))
            ], emptyState: noEntry)
    }

    private func loadSpelling(_ term: LookupTerm) async throws -> ListResult {
        guard term.isSingleWord else {
            return ListResult(
                rows: [],
                emptyState: EmptyState(
                    icon: WordRows.spellingIcon, title: DefineStrings.oneWordTitle,
                    message: DefineStrings.oneWordMessage))
        }
        let spelling = try await pages.lookup.spelling(of: term)
        try Task.checkCancellation()
        return ListResult(sections: WordRows.spelling(term, spelling))
    }

    func actions(for row: Row) -> [Action] {
        pages.actions(for: row)
    }

    /// The selected word's definition beside the list, in the Define Word page only.
    func detail(for row: Row) async throws -> Detail? {
        guard case .define = mode, let item = try? row.payload?.decode(WordRow.self) else { return nil }
        if let shown, shown.headword == item.word { return .markdown(shown.markdown) }
        guard let term = LookupTerm.make(item.word), let definition = try await pages.lookup.definition(of: term)
        else { return nil }
        return .markdown(definition.markdown)
    }
}
