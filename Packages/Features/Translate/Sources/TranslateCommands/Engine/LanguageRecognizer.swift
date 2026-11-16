import Foundation
import NaturalLanguage

/// Which language a text is in, from the NaturalLanguage framework's recognizer. It reads only
/// the text it is given and the model that ships with macOS, so it runs anywhere.
nonisolated enum LanguageRecognizer {
    /// How many characters the recognizer reads. A few sentences tell a language, so a long text
    /// costs the same as a short one.
    static let readLimit = 2_000
    /// The prior given to a hinted language, such as the one a text was just translated into.
    static let hintWeight = 0.8
    /// The most guesses returned.
    static let maximumGuesses = 5

    /// The recognizer's guesses for a text, the most likely first. Empty when it recognizes no
    /// language.
    static func guesses(for text: String, hint: LanguageTag?) -> [LanguageGuess] {
        let recognizer = NLLanguageRecognizer()
        if let hint {
            recognizer.languageHints = [NLLanguage(rawValue: recognizerCode(for: hint)): hintWeight]
        }
        recognizer.processString(String(text.prefix(readLimit)))
        let guesses = recognizer.languageHypotheses(withMaximum: maximumGuesses)
            .filter { $0.key != .undetermined && $0.value > 0 }
            .map { LanguageGuess($0.key.rawValue, probability: $0.value) }
        return sorted(guesses)
    }

    /// Most likely first, then by identifier, so equal guesses always come in the same order.
    static func sorted(_ guesses: [LanguageGuess]) -> [LanguageGuess] {
        guesses.sorted { lhs, rhs in
            lhs.probability != rhs.probability ? lhs.probability > rhs.probability : lhs.identifier < rhs.identifier
        }
    }

    /// The recognizer names Chinese by script, "zh-Hans" or "zh-Hant", and every other language
    /// by its code alone.
    static func recognizerCode(for tag: LanguageTag) -> String {
        tag.code == "zh" && !tag.script.isEmpty ? "zh-" + tag.script : tag.code
    }
}
