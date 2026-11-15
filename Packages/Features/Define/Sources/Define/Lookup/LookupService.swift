import Foundation
import Kit

/// What the feature asks the Mac: the text a dictionary gives for a term, and the spell checker's
/// verdict on a word. It lives in this package because no other feature needs it.
///
/// Both requirements are `@concurrent`, so the work runs off the main thread whoever calls it. The
/// live service reads only the dictionaries and the spell checker that come with macOS, and never
/// prompts. It makes no request itself. Dictionary Services ships a Wikipedia source the user can
/// turn on in the Dictionary app; whether the text API then asks wikipedia.org is not verified, so
/// the settings pane says that macOS may. The isolated one answers from fixtures written by hand.
nonisolated protocol LookupService: Sendable {
    /// The plain text the active dictionaries give for a term, or nil when none has an entry.
    /// Throws `CancellationError` when the calling task was cancelled before the answer came back.
    @concurrent func definitionText(for term: String) async throws -> String?

    /// Whether the word is spelled correctly, with the spell checker's guesses, best first.
    /// Throws `CancellationError` when the calling task was cancelled before the answer came back.
    @concurrent func spelling(of word: String) async throws -> Spelling
}

/// The spell checker's verdict on one word.
nonisolated struct Spelling: Hashable, Sendable {
    nonisolated enum Verdict: Hashable, Sendable {
        /// The spell checker knows the word.
        case correct
        /// The spell checker does not know the word.
        case misspelled
        /// The word is in a language the spell checker has no dictionary for, such as Japanese
        /// on a Mac without a Japanese spelling language.
        case unchecked
    }

    var verdict: Verdict
    /// Words the spell checker suggests, best first. Empty when it has none. For a word it knows,
    /// these are words spelled alike.
    var guesses: [String]

    init(_ verdict: Verdict, guesses: [String] = []) {
        self.verdict = verdict
        self.guesses = guesses
    }
}

/// The lookup service for each kind of run. Scenarios, self-tests and benchmarks get fixtures, so
/// their output never depends on which dictionaries a Mac has.
nonisolated enum LookupServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any LookupService { SystemLookup() }
    static func isolated(_ context: FeatureContext) -> any LookupService { FixtureLookup() }
}
