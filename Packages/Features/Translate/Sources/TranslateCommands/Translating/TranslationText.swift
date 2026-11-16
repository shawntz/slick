import Foundation
import Kit

/// How text goes in and out: the limits, the cleaning before a translation, the one-line titles
/// and the Markdown of the detail. Pure.
nonisolated enum TranslationText {
    /// The most text the page translates at once, in UTF-8 bytes. Counting bytes is cheap, and a
    /// pasted paragraph or two fits.
    static let maximumBytes = 10_000
    /// The most text root search translates, in UTF-8 bytes. Longer text belongs on the page.
    static let rootMaximumBytes = 1_000
    /// The longest title, in characters, before it is cut with an ellipsis.
    static let titleLimit = 200
    /// A translation up to this many characters shows as a large heading.
    static let largeLimit = 80
    /// A translation up to this many characters shows as a smaller heading. Longer ones show as
    /// paragraphs.
    static let mediumLimit = 400

    /// True when the text has more than `limit` UTF-8 bytes. Reads at most `limit + 1` bytes, so a
    /// pasted book costs the same as a short text.
    static func exceeds(_ text: some StringProtocol, bytes limit: Int) -> Bool {
        var count = 0
        for _ in text.utf8 {
            count += 1
            if count > limit { return true }
        }
        return false
    }

    /// The text to translate: white space trimmed from both ends, control characters other than
    /// line breaks and tabs dropped. Empty when nothing is left that shows.
    static func cleaned(_ text: some StringProtocol) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control, !"\n\t\r".unicodeScalars.contains(scalar) { continue }
            scalars.append(scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return hasVisibleText(trimmed) ? trimmed : ""
    }

    /// True when the text has a character that is neither white space nor invisible, such as a
    /// zero-width space.
    static func hasVisibleText(_ text: some StringProtocol) -> Bool {
        text.unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
                && scalar.properties.generalCategory != .control
        }
    }

    /// A title on one line, drawn in the order it is stored, cut at ``titleLimit`` characters.
    static func title(_ text: String) -> String {
        let line = DisplayText.oneLine(text).split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard line.count > titleLimit else { return line }
        return String(line.prefix(titleLimit - 1)) + "…"
    }

    // MARK: Markdown

    /// The translation for the detail: one block per line, as large headings when it is short, as
    /// paragraphs when it is long. Every line is drawn in the order it is stored, and Markdown
    /// signs in it show as written.
    static func markdown(_ translation: String) -> String {
        let lines = translation.split(whereSeparator: \.isNewline)
            .map { DisplayText.oneLine(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let length = lines.reduce(0) { $0 + $1.count }
        let prefix = length <= largeLimit ? "# " : length <= mediumLimit ? "## " : nil
        return lines.map { line in prefix.map { $0 + escaped(line) } ?? escapedParagraph(line) }
            .joined(separator: "\n\n")
    }

    /// A plain sentence as a paragraph, with its Markdown signs shown as written.
    static func paragraph(_ text: String) -> String {
        escapedParagraph(DisplayText.oneLine(text))
    }

    /// Characters the detail's Markdown reads as syntax anywhere in a line.
    static let inlineSyntax: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "|", "#", "~"]

    /// The text with every Markdown syntax character escaped.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if inlineSyntax.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The text escaped as a paragraph of its own: also escapes what would start a list, a rule or
    /// a numbered item at the start of the line, such as "- " or "1. ".
    static func escapedParagraph(_ text: String) -> String {
        var result = escaped(text)
        if let first = result.first, "-+=".contains(first) {
            result.insert("\\", at: result.startIndex)
        }
        let digits = result.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count < result.count {
            let delimiter = result.index(result.startIndex, offsetBy: digits.count)
            if result[delimiter] == "." || result[delimiter] == ")" { result.insert("\\", at: delimiter) }
        }
        return result
    }
}
