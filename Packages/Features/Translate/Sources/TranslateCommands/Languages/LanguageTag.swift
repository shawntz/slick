import Foundation

/// A language as the feature stores and compares it: a BCP 47 identifier with its language, script
/// and region all written out, such as "fr-Latn-FR" or "zh-Hans-CN". Pure.
///
/// Every tag is made through `Locale.Language`, so "fr", "fr-FR" and "fr-Latn-FR" give the same
/// tag and two tags compare equal when they name the same language.
nonisolated struct LanguageTag: Hashable, Sendable, Codable {
    /// The full identifier, such as "en-Latn-GB".
    let identifier: String
    /// The language code, such as "en".
    let code: String
    /// The script code, such as "Latn" or "Hans". Empty when Foundation knows none.
    let script: String
    /// The region code, such as "GB". Empty when Foundation knows none.
    let region: String

    init(_ language: Locale.Language) {
        let full = Locale.Language(identifier: language.maximalIdentifier)
        identifier = full.maximalIdentifier
        code = full.languageCode?.identifier ?? language.minimalIdentifier
        script = full.script?.identifier ?? ""
        region = full.region?.identifier ?? ""
    }

    /// A tag for an identifier such as "fr", "fr-FR", "fr_FR" or "zh-Hans".
    init(_ identifier: String) {
        self.init(Locale.Language(identifier: identifier))
    }

    /// The language as the system's frameworks take it.
    var language: Locale.Language { Locale.Language(identifier: identifier) }

    /// True for the same language in the same script, whatever the region: British and American
    /// English are the same language here, Simplified and Traditional Chinese are not.
    func isSameLanguage(as other: LanguageTag) -> Bool {
        code == other.code && script == other.script
    }
}

/// One guess at the language of a text, as a language recognizer gives it.
nonisolated struct LanguageGuess: Hashable, Sendable {
    /// What the recognizer named, such as "fr" or "zh-Hant".
    var identifier: String
    /// How likely the guess is, from 0 to 1.
    var probability: Double

    init(_ identifier: String, probability: Double) {
        self.identifier = identifier
        self.probability = probability
    }
}
