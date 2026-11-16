import Foundation
import Kit

/// What the feature asks the Mac: which languages it can translate, which language a text is in,
/// whether a pair of languages is installed, and the translation itself. It lives in this package
/// because no other feature needs it.
///
/// Every requirement is `@concurrent`, so the work runs off the main thread whoever calls it. The
/// live service uses Apple's Translation framework with the languages already installed and the
/// NaturalLanguage framework's recognizer, so nothing leaves the Mac and nothing is downloaded.
/// The isolated one answers from a small table of made-up phrases.
nonisolated protocol TranslationEngine: Sendable {
    /// Every language the Mac can translate from or into, installed or not. Empty when translation
    /// is not available.
    @concurrent func supportedLanguages() async -> [LanguageTag]

    /// The languages the user prefers, best first, as BCP 47 identifiers such as "de-DE".
    @concurrent func preferredLanguages() async -> [String]

    /// Likely languages of a text, the most likely first. Empty when no language is recognized.
    /// `hint` names a language the text is probably in, such as the one it was translated into.
    @concurrent func guesses(for text: String, hint: LanguageTag?) async -> [LanguageGuess]

    /// Whether the Mac can translate between two languages now. Never downloads anything.
    @concurrent func status(from source: LanguageTag, to target: LanguageTag) async -> PairStatus

    /// The text in the target language. Uses installed languages only and never starts a
    /// download. Throws ``EngineFailure`` when the pair cannot be used, and `CancellationError` when
    /// the calling task was cancelled before the answer came back.
    @concurrent func translate(_ text: String, from source: LanguageTag, to target: LanguageTag) async throws
        -> String
}

/// Whether a pair of languages can be used.
nonisolated enum PairStatus: Hashable, Sendable {
    /// Both languages are on this Mac.
    case installed
    /// The Mac can translate the pair once the user downloads a language.
    case notInstalled
    /// The Mac cannot translate between the two languages.
    case unsupported
}

/// Why a translation did not come back.
nonisolated enum EngineFailure: Error, Hashable, Sendable {
    /// A language of the pair is not installed.
    case notInstalled
    /// The Mac cannot translate between the two languages.
    case unsupported
    /// The system could not translate, with its own words.
    case failed(String)
}

/// The engine for each kind of run. Scenarios, self-tests and benchmarks get the simulated
/// engine, so their output never depends on which languages a Mac has.
nonisolated enum TranslationEngineKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any TranslationEngine { SystemTranslation() }
    static func isolated(_ context: FeatureContext) -> any TranslationEngine { SimulatedTranslation() }
}
