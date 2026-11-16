import Foundation
import Kit

/// The words the feature sends to models. People do not read these in the panel, so they live apart
/// from ``Strings``. The selected text is always fenced at the end, so the instruction comes first.
nonisolated enum Prompts {
    /// The system prompt until the user writes their own.
    static let defaultSystem =
        "You answer questions asked from a Mac launcher. Be brief and direct. Use Markdown when it helps, "
        + "and put code in fenced code blocks."

    /// Introduces the earlier turns for the on-device model, which keeps no conversation itself.
    static let historyIntro = "Here is the conversation so far."
    static let historyUser = "User: "
    static let historyAssistant = "Assistant: "
    static let historyQuestion = "Answer the user's next message:"

    /// The instruction for a command on text, before the text itself.
    static func instruction(for kind: TextCommandKind, tone: String, language: String) -> String {
        switch kind {
        case .improveWriting:
            "Improve the writing of the text below. Keep its meaning, its language and its tone. Make it clear "
                + "and concise. Reply with only the improved text, without quotes or comments."
        case .fixSpellingAndGrammar:
            "Fix the spelling, grammar and punctuation of the text below and change nothing else. Keep its "
                + "language. Reply with only the corrected text, without quotes or comments."
        case .makeShorter:
            "Make the text below about half as long. Keep the key points, its language and its tone. Reply "
                + "with only the new text, without quotes or comments."
        case .makeLonger:
            "Make the text below about twice as long by adding useful detail. Keep its language and its tone. "
                + "Reply with only the new text, without quotes or comments."
        case .changeTone:
            "Rewrite the text below in a \(tone.lowercased()) tone. Keep its meaning and its language. Reply "
                + "with only the rewritten text, without quotes or comments."
        case .summarize:
            "Summarize the text below in a few sentences or short bullet points, in the language of the text."
        case .explain:
            "Explain the text below in simple terms. If it is code, say what it does and how."
        case .translate:
            "Translate the text below into \(language). Keep its formatting. Reply with only the translation, "
                + "without quotes or comments."
        }
    }

    /// The whole prompt for a command: the instruction, then the text between two fence lines of
    /// double quotes. The text may come from any web page or email, so it must not be able to close
    /// the fence and go on as if it were the instruction: the fence is longer than any run of
    /// double quotes in the text.
    static func textCommand(_ instruction: String, text: String) -> String {
        let fence = fence(for: text)
        return instruction + "\n\nText:\n" + fence + "\n" + text + "\n" + fence
    }

    /// Double quotes, one more than the longest run of them in `text`, and at least three.
    static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if scalar == "\"" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return String(repeating: "\"", count: max(3, longest + 1))
    }
}
