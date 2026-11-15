import AppKit
import CoreServices
import Foundation

/// The live lookup service: Dictionary Services for definitions and the shared spell checker for
/// spelling. Both read only what ships with macOS: the dictionaries turned on in the Dictionary
/// app and the spelling languages chosen in System Settings. Neither prompts.
///
/// No lookup runs on the main actor. Every call goes through one ``SystemLookupWorker``, so the
/// two system APIs are never called from two of this feature's threads at once. The only hop to
/// the main actor fetches the shared spell checker the first time, since AppKit makes it there.
nonisolated final class SystemLookup: LookupService {
    private let worker = SystemLookupWorker()

    @concurrent func definitionText(for term: String) async throws -> String? {
        try await worker.definitionText(for: term)
    }

    @concurrent func spelling(of word: String) async throws -> Spelling {
        try await worker.spelling(of: word)
    }
}

/// Runs the system calls one at a time, off the main thread, and checks for cancellation before
/// and after each one. A cancelled lookup that waited its turn returns without calling the system.
actor SystemLookupWorker {
    private var checker: SharedSpellChecker?

    func definitionText(for term: String) throws -> String? {
        try Task.checkCancellation()
        let text = SystemDictionary.definition(of: term)
        try Task.checkCancellation()
        return text
    }

    func spelling(of word: String) async throws -> Spelling {
        try Task.checkCancellation()
        let checker = await sharedChecker()
        try Task.checkCancellation()
        let spelling = checker.spelling(of: word)
        try Task.checkCancellation()
        return spelling
    }

    private func sharedChecker() async -> SharedSpellChecker {
        if let checker { return checker }
        let made = await MainActor.run { SharedSpellChecker(NSSpellChecker.shared) }
        checker = made
        return made
    }
}

/// Dictionary Services, a plain Core Foundation API.
nonisolated enum SystemDictionary {
    /// The definition the active dictionaries give for the whole of `term`, as plain text.
    static func definition(of term: String) -> String? {
        let length = (term as NSString).length
        guard length > 0 else { return nil }
        guard let definition = DCSCopyTextDefinition(nil, term as CFString, CFRange(location: 0, length: length))
        else { return nil }
        return definition.takeRetainedValue() as String
    }
}

/// The shared spell checker, handed to the worker. `NSSpellChecker` is not marked `Sendable`;
/// the worker actor is its only user in this feature, so calls never overlap.
nonisolated final class SharedSpellChecker: @unchecked Sendable {
    private let checker: NSSpellChecker

    init(_ checker: NSSpellChecker) {
        self.checker = checker
    }

    /// Checks the word with unified text checking, which finds its language among the spelling
    /// languages the user chose, then asks for guesses in that language.
    func spelling(of word: String) -> Spelling {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let types: NSTextCheckingTypes =
            NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.orthography.rawValue
        var orthography: NSOrthography?
        var wordCount = 0
        let results = checker.check(
            word, range: range, types: types, options: nil, inSpellDocumentWithTag: 0, orthography: &orthography,
            wordCount: &wordCount)
        let misspelled = results.contains { $0.resultType == .spelling }
        let language = checker.language(forWordRange: range, in: word, orthography: orthography)
        let guesses = checker.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0)
        let verdict = Self.verdict(
            misspelled: misspelled, detected: orthography?.dominantLanguage, available: checker.availableLanguages)
        return Spelling(verdict, guesses: guesses ?? [])
    }

    /// Misspelled when the check found a mistake. Unchecked when the word's language was
    /// recognized but no spelling language covers it. Correct otherwise.
    static func verdict(misspelled: Bool, detected: String?, available: [String]) -> Spelling.Verdict {
        if misspelled { return .misspelled }
        guard let detected, detected != "und", let base = baseLanguage(detected) else { return .correct }
        return available.contains { baseLanguage($0) == base } ? .correct : .unchecked
    }

    /// "en_GB" and "en-GB" give "en".
    static func baseLanguage(_ code: String) -> String? {
        let base = code.prefix { $0 != "_" && $0 != "-" }.lowercased()
        return base.isEmpty ? nil : base
    }
}
