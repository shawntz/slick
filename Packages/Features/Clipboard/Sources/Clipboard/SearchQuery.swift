/// What the user typed on the history page, turned into conditions the store can run.
///
/// The full-text index uses SQLite's trigram tokenizer, so a word matches anywhere inside the text,
/// ignoring case and accents. A trigram needs three characters: shorter words are matched with
/// `LIKE` against the item's preview instead. Every word must match.
nonisolated struct SearchQuery: Hashable, Sendable {
    /// The words, as typed, without surrounding white space. Control characters, such as a pasted
    /// NUL, separate words too: SQLite would read a NUL as the end of the pattern.
    let words: [String]

    init(_ text: String) {
        words = text.split { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        .map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    /// The FTS5 expression for words of three or more characters: each a quoted string, all
    /// required. Nil when there is none.
    var matchExpression: String? {
        let long = words.filter { $0.unicodeScalars.count >= 3 }
        guard !long.isEmpty else { return nil }
        return long.map { "\"" + $0.replacing("\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
    }

    /// `LIKE` patterns for words shorter than three characters, escaped with a backslash.
    var likePatterns: [String] {
        words.filter { $0.unicodeScalars.count < 3 }.map { word in
            let escaped = word.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
            return "%" + escaped + "%"
        }
    }
}
