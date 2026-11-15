import Kit

/// What a row stands for, carried in its payload, so its actions can be made from the row alone.
nonisolated struct WordRow: Codable, Hashable, Sendable {
    nonisolated enum Role: String, Codable, Hashable, Sendable {
        /// An entry that was found. Return shows its definition.
        case definition
        /// A spelling suggested for a word with no entry. Return shows its definition.
        case suggestion
        /// A word in Check Spelling. Return copies or pastes it.
        case spelling
    }

    var word: String
    var role: Role
}

/// The rows the feature shows, in its pages and in root search. Pure.
///
/// Every row is an answer to one query, so root search remembers none of them, and every row
/// stands for its word, so other features' actions on text apply to it.
nonisolated enum WordRows {
    static let namespace = "dictionary"

    static let definitionIcon = Icon.symbol("character.book.closed")
    static let spellingIcon = Icon.symbol("textformat.abc")

    static func id(_ role: WordRow.Role, _ word: String) -> ItemID {
        ItemID(namespace, role.rawValue + ":" + word)
    }

    /// The row for a found entry: its headword, with the first meaning as the subtitle.
    static func definition(_ definition: Definition) -> Row {
        Row(
            id: id(.definition, definition.headword), title: definition.headword,
            subtitle: definition.summary.isEmpty ? nil : definition.summary, icon: definitionIcon,
            payload: Payload(WordRow(word: definition.headword, role: .definition)), memory: .never,
            represents: .text(definition.headword))
    }

    /// Spellings suggested for a word that has no entry.
    static func suggestions(_ guesses: [String]) -> [Row] {
        guesses.map { guess in
            Row(
                id: id(.suggestion, guess), title: guess, subtitle: DefineStrings.suggestedSpelling, icon: spellingIcon,
                payload: Payload(WordRow(word: guess, role: .suggestion)), memory: .never, represents: .text(guess))
        }
    }

    /// Check Spelling's sections: the word as typed with the spell checker's verdict, then the
    /// suggestions.
    static func spelling(_ term: LookupTerm, _ spelling: Spelling) -> [ListSection] {
        let typed = Row(
            id: id(.spelling, term.text), title: term.text, subtitle: verdictText(spelling.verdict),
            icon: verdictIcon(spelling.verdict), payload: Payload(WordRow(word: term.text, role: .spelling)),
            titleHighlights: [0..<term.text.utf16.count], memory: .never, represents: .text(term.text))
        let guesses = spelling.guesses.map { guess in
            Row(
                id: id(.spelling, guess), title: guess, icon: spellingIcon,
                payload: Payload(WordRow(word: guess, role: .spelling)), memory: .never, represents: .text(guess))
        }
        var sections = [ListSection(id: "typed", rows: [typed])]
        if !guesses.isEmpty {
            sections.append(ListSection(DefineStrings.suggestionsSection, id: "suggestions", rows: guesses))
        }
        return sections
    }

    static func verdictText(_ verdict: Spelling.Verdict) -> String {
        switch verdict {
        case .correct: DefineStrings.spelledCorrectly
        case .misspelled: DefineStrings.notInDictionary
        case .unchecked: DefineStrings.unchecked
        }
    }

    static func verdictIcon(_ verdict: Spelling.Verdict) -> Icon {
        switch verdict {
        case .correct: .symbol("checkmark.circle")
        case .misspelled: .symbol("xmark.circle")
        case .unchecked: .symbol("questionmark.circle")
        }
    }
}

/// A root search query that names a keyword: "define <term>" or "spell <word>". Pure, and cheap
/// enough for every keystroke: anything that does not start with a keyword's first letter is
/// turned away on its first byte.
nonisolated enum RootQuery: Hashable, Sendable {
    case define(String)
    case spell(String)

    /// The most UTF-8 bytes after a keyword that still count as a lookup. A term has at most 80
    /// characters; this leaves room for spaces and characters of several bytes.
    static let maximumBytes = 1_024

    private static let define = Array("define ".utf8)
    private static let spell = Array("spell ".utf8)

    /// The keyword and the text after it, or nil. The keyword may be in any case and needs a space
    /// and some text after it.
    static func keyword(in query: String) -> RootQuery? {
        let bytes = query.utf8
        guard let first = bytes.first else { return nil }
        let prefix: [UInt8]
        switch first | 0x20 {
        case UInt8(ascii: "d"): prefix = define
        case UInt8(ascii: "s"): prefix = spell
        default: return nil
        }
        guard bytes.count > prefix.count, bytes.count <= prefix.count + maximumBytes else { return nil }
        var index = bytes.startIndex
        for expected in prefix {
            let byte = bytes[index]
            guard expected == 0x20 ? byte == 0x20 : byte | 0x20 == expected else { return nil }
            index = bytes.index(after: index)
        }
        let rest = query[index...]
        guard rest.utf8.contains(where: { $0 != 0x20 }) else { return nil }
        return prefix == define ? .define(String(rest)) : .spell(String(rest))
    }

    /// The shortest and longest single word root search looks up without a keyword.
    static let singleWordLengths = 3...40

    /// The query as a term when it is one word of letters, such as "lantern" or "naïve", with
    /// hyphens or apostrophes only inside it. Nil for anything else, such as "safari 2" or "~/".
    static func singleWord(_ query: String) -> LookupTerm? {
        guard query.utf8.count <= singleWordLengths.upperBound * 8, let term = LookupTerm.make(query),
            term.isSingleWord, singleWordLengths.contains(term.text.count),
            term.text.first?.isLetter == true, term.text.last?.isLetter == true,
            term.text.allSatisfy({ $0.isLetter || "-'’".contains($0) })
        else { return nil }
        return term
    }
}
