import Foundation

/// The text forms of a definition: a one-line summary, plain text for copying, and Markdown for
/// the detail page. Pure.
nonisolated enum DefinitionText {
    /// The longest summary, in characters, before it is cut at a word with an ellipsis.
    static let summaryLimit = 120

    // MARK: Summary

    static func summary(of paragraphs: [DefinitionParagraph]) -> String {
        for paragraph in paragraphs {
            let text: String
            switch paragraph {
            case .sense(_, let sense): text = sense
            case .text(let body) where !isVariantNote(body): text = body
            case .subsense(let body): text = body
            default: continue
            }
            let meaning = shortened(withoutExamplesOrGrammar(text))
            if !meaning.isEmpty { return meaning }
        }
        return ""
    }

    /// Where a meaning ends and an example or a second sentence begins.
    static let meaningEnds = [": ", ". ", " | "]

    /// "[no object] move at a speed: she ran" becomes "move at a speed". Only the first sentence
    /// is kept.
    static func withoutExamplesOrGrammar(_ text: String) -> String {
        var rest = Substring(text)
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        let ends = meaningEnds.compactMap { rest.range(of: $0)?.lowerBound }
        if let end = ends.min() { rest = rest[..<end] }
        var result = String(rest).trimmingCharacters(in: [" "])
        if result.hasSuffix(":") || result.hasSuffix(".") || result.hasSuffix(";") { result.removeLast() }
        return result
    }

    static func shortened(_ text: String) -> String {
        guard text.count > summaryLimit else { return text }
        let cut = text.prefix(summaryLimit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: [" ", ",", ";", ":"]) + "…"
    }

    /// A note such as "(also naïve)", which says how else the word is written.
    static func isVariantNote(_ text: String) -> Bool {
        text.hasPrefix("(") && text.hasSuffix(")")
    }

    // MARK: Plain text

    static func plain(
        headword: String, syllables: String?, pronunciation: String?, paragraphs: [DefinitionParagraph]
    ) -> String {
        var blocks: [String] = []
        var head = headword
        if let line = soundLine(syllables: syllables, pronunciation: pronunciation, escaped: false) {
            head += "\n" + line
        }
        blocks.append(head)
        var group: [String] = []
        func flush() {
            if !group.isEmpty { blocks.append(group.joined(separator: "\n")) }
            group = []
        }
        for paragraph in paragraphs {
            switch paragraph {
            case .partOfSpeech(let word, let note):
                flush()
                group.append(note.map { "\(word) \($0)" } ?? word)
            case .sense(let number, let text):
                group.append("\(number). \(text)")
            case .subsense(let text):
                group.append("• \(text)")
            case .section(let label, let text):
                flush()
                group.append(label)
                group.append(text)
            case .text(let text):
                group.append(text)
            }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Markdown

    static func markdown(
        headword: String, syllables: String?, pronunciation: String?, paragraphs: [DefinitionParagraph]
    ) -> String {
        var blocks = ["# " + escaped(headword)]
        if let line = soundLine(syllables: syllables, pronunciation: pronunciation, escaped: true) {
            blocks.append(line)
        }
        var lastWasSense = false
        for paragraph in paragraphs {
            switch paragraph {
            case .partOfSpeech(let word, let note):
                blocks.append("### " + escaped(word))
                if let note { blocks.append(escapedParagraph(note)) }
                lastWasSense = false
            case .sense(let number, let text):
                blocks.append("\(number). " + escaped(text))
                lastWasSense = true
            case .subsense(let text):
                // Two spaces nest the bullet under the sense above it.
                blocks.append((lastWasSense ? "  - " : "- ") + escaped(text))
            case .section(let label, let text):
                blocks.append("### " + escaped(label))
                blocks.append(escapedParagraph(text))
                lastWasSense = false
            case .text(let text):
                blocks.append(escapedParagraph(text))
                lastWasSense = false
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// "lan·tern | ˈlan(t)ərn |", or whichever of the two the entry has.
    private static func soundLine(syllables: String?, pronunciation: String?, escaped: Bool) -> String? {
        let bar = escaped ? "\\|" : "|"
        let sound = pronunciation.map { "\(bar) \(escaped ? Self.escaped($0) : $0) \(bar)" }
        let parts = [syllables.map { escaped ? Self.escaped($0) : $0 }, sound].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Characters the detail page's Markdown reads as syntax anywhere in a line.
    static let inlineSyntax: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "|", "#", "~"]

    /// The text with every Markdown syntax character escaped, so the dictionary's brackets,
    /// asterisks and underscores show as written.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if inlineSyntax.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The text escaped as a paragraph of its own: also escapes what would start a list, a heading,
    /// a quote, a rule or a fence at the start of a line, such as "1. " or "- ".
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
