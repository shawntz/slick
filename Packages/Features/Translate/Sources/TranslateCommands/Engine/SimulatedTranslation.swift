import Foundation

/// The isolated engine, for tests, scenarios, self-tests and benchmarks. It touches nothing on the
/// Mac and answers from a small table of made-up phrases, with all three states a pair of
/// languages can be in:
///
/// - English, French, Spanish and Japanese are installed, so any pair of them translates.
/// - German and British English are supported but not installed, so a pair with one of them asks
///   for a download.
/// - A phrase in Icelandic is recognized, and the simulated Mac cannot translate Icelandic at all.
///
/// Text that is not in the table is not recognized, as a real recognizer does with noise.
nonisolated final class SimulatedTranslation: TranslationEngine {
    /// The languages the simulated Mac offers.
    static let standardSupported = ["en-US", "en-GB", "fr-FR", "es-ES", "de-DE", "ja-JP"]
    /// The languages the simulated Mac has installed.
    static let standardInstalled = ["en-US", "fr-FR", "es-ES", "ja-JP"]

    /// Made-up phrases, each one in every language the table knows, keyed by language code.
    static let phrases: [[String: String]] = [
        [
            "en": "The blue kettle sings", "fr": "La bouilloire bleue chante", "es": "La tetera azul canta",
            "de": "Der blaue Kessel singt", "ja": "青いやかんが歌う",
        ],
        [
            "en": "Seven paper boats", "fr": "Sept bateaux en papier", "es": "Siete barcos de papel",
            "de": "Sieben Papierboote", "ja": "七つの紙の船",
        ],
        [
            "en": "Good morning", "fr": "Bonjour", "es": "Buenos días", "de": "Guten Morgen",
            "ja": "おはようございます",
        ],
        [
            "en": "The lighthouse keeps a quiet garden", "fr": "Le phare garde un jardin tranquille",
            "es": "El faro guarda un jardín tranquilo", "de": "Der Leuchtturm hütet einen stillen Garten",
            "ja": "灯台は静かな庭を守る",
        ],
    ]

    /// Phrases in languages the simulated Mac recognizes but cannot translate.
    static let unsupportedPhrases = ["Bláa ketillinn syngur": "is"]

    private let supported: [LanguageTag]
    private let installed: Set<LanguageTag>
    private let preferred: [String]
    private let unsupportedPairs: Set<[String]>

    /// - Parameters:
    ///   - supported: The languages offered, as identifiers.
    ///   - installed: The languages installed, as identifiers.
    ///   - preferred: The user's preferred languages, best first.
    ///   - unsupportedPairs: Pairs of language codes, source first, the Mac refuses although it
    ///     offers both languages.
    init(
        supported: [String] = standardSupported, installed: [String] = standardInstalled,
        preferred: [String] = ["en-US"], unsupportedPairs: Set<[String]> = []
    ) {
        self.supported = supported.map(LanguageTag.init)
        self.installed = Set(installed.map(LanguageTag.init))
        self.preferred = preferred
        self.unsupportedPairs = unsupportedPairs
    }

    @concurrent func supportedLanguages() async -> [LanguageTag] {
        supported
    }

    @concurrent func preferredLanguages() async -> [String] {
        preferred
    }

    @concurrent func guesses(for text: String, hint: LanguageTag?) async -> [LanguageGuess] {
        let key = Self.folded(text)
        if let code = Self.unsupportedPhrases.first(where: { Self.folded($0.key) == key })?.value {
            return [LanguageGuess(code, probability: 0.9)]
        }
        guard let group = Self.phrases.first(where: { $0.values.contains { Self.folded($0) == key } }) else {
            return []
        }
        let codes = group.filter { Self.folded($0.value) == key }.map(\.key).sorted()
        return codes.map { LanguageGuess($0, probability: 0.9 / Double(codes.count)) }
    }

    @concurrent func status(from source: LanguageTag, to target: LanguageTag) async -> PairStatus {
        pairStatus(source, target)
    }

    @concurrent func translate(_ text: String, from source: LanguageTag, to target: LanguageTag) async throws
        -> String
    {
        try Task.checkCancellation()
        switch pairStatus(source, target) {
        case .unsupported: throw EngineFailure.unsupported
        case .notInstalled: throw EngineFailure.notInstalled
        case .installed: break
        }
        let key = Self.folded(text)
        guard let group = Self.phrases.first(where: { $0[source.code].map(Self.folded) == key }),
            let translation = group[target.code]
        else { throw EngineFailure.failed("The simulated table has no translation for this text.") }
        return translation
    }

    private func pairStatus(_ source: LanguageTag, _ target: LanguageTag) -> PairStatus {
        let offered = Set(supported)
        guard offered.contains(source), offered.contains(target), !source.isSameLanguage(as: target),
            !unsupportedPairs.contains([source.code, target.code])
        else { return .unsupported }
        return installed.contains(source) && installed.contains(target) ? .installed : .notInstalled
    }

    /// Lowercased, without accents or punctuation, with single spaces.
    static func folded(_ text: String) -> String {
        let plain = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = plain.split { !$0.isLetter && !$0.isNumber }
        return words.joined(separator: " ")
    }
}
