import Foundation

/// A word or short phrase, cleaned for a lookup: trimmed, on one line, with single spaces and no
/// control or direction characters. Pure.
nonisolated struct LookupTerm: Hashable, Sendable {
    /// The longest term, in characters. Dictionary headwords and phrases are shorter.
    static let maximumLength = 80
    /// How many characters of a text are read before it counts as too long, so a pasted
    /// paragraph costs the same as a short one.
    static let readLimit = 4 * maximumLength

    /// Why a text cannot be looked up.
    nonisolated enum Problem: Error, Hashable, Sendable {
        case empty
        case tooLong
    }

    let text: String
    /// How many words the term has, counted at spaces.
    let wordCount: Int

    var isSingleWord: Bool { wordCount == 1 }

    /// Cleans a text for a lookup. Reads at most ``readLimit`` characters of it.
    static func read(_ raw: String) -> Result<LookupTerm, Problem> {
        var text = ""
        var length = 0
        var words = 0
        var pendingSpace = false
        var read = 0
        for character in raw {
            read += 1
            if read > readLimit { return .failure(.tooLong) }
            if character.isWhitespace || character.unicodeScalars.contains(where: DefinitionParser.isControl) {
                pendingSpace = !text.isEmpty
                continue
            }
            let kept = String(character.unicodeScalars.filter { !DefinitionParser.isDirectionControl($0) })
            // A character made only of invisible marks, such as a zero-width space or a soft
            // hyphen, adds nothing a dictionary can look up. A joiner inside an emoji stays.
            guard kept.unicodeScalars.contains(where: { !$0.properties.isDefaultIgnorableCodePoint }) else { continue }
            if pendingSpace || text.isEmpty { words += 1 }
            if pendingSpace {
                text += " "
                length += 1
            }
            pendingSpace = false
            text += kept
            length += 1
            if length > maximumLength { return .failure(.tooLong) }
        }
        guard !text.isEmpty else { return .failure(.empty) }
        return .success(LookupTerm(text: text, wordCount: words))
    }

    /// The term for a text, or nil when it is empty or too long.
    static func make(_ raw: String) -> LookupTerm? {
        try? read(raw).get()
    }
}

/// The feature's lookups: the service's raw answers, parsed and cleaned off the main thread.
nonisolated struct Lookup: Sendable {
    /// The most spelling suggestions shown for one word.
    static let maximumGuesses = 15

    let service: any LookupService

    /// The entry for a term, parsed, or nil when no active dictionary has one.
    @concurrent func definition(of term: LookupTerm) async throws -> Definition? {
        guard let raw = try await service.definitionText(for: term.text) else { return nil }
        try Task.checkCancellation()
        let definition = DefinitionParser.parse(raw, term: term.text)
        try Task.checkCancellation()
        return definition.paragraphs.isEmpty ? nil : definition
    }

    /// The spell checker's verdict on a word, with its guesses cleaned: no repeats, not the word
    /// itself, at most ``maximumGuesses``.
    @concurrent func spelling(of term: LookupTerm) async throws -> Spelling {
        let spelling = try await service.spelling(of: term.text)
        try Task.checkCancellation()
        return Spelling(spelling.verdict, guesses: Self.cleaned(spelling.guesses, for: term.text))
    }

    static func cleaned(_ guesses: [String], for word: String) -> [String] {
        var seen: Set<String> = [word]
        var result: [String] = []
        for guess in guesses {
            guard let term = LookupTerm.make(guess), seen.insert(term.text).inserted else { continue }
            result.append(term.text)
            if result.count == maximumGuesses { break }
        }
        return result
    }
}
