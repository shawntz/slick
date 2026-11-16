import Foundation

/// Markdown made into plain text, for Copy as Plain Text and for titles shown in rows. Pure, so it
/// runs on any thread.
///
/// Headings, quotes, fences and emphasis lose their marks. List items keep a bullet. A link keeps
/// its text and, when they differ, its address in parentheses, so nothing the note says is lost.
/// An image keeps its description. Code keeps its text exactly.
nonisolated enum PlainText {
    /// The whole note as plain text.
    static func of(_ markdown: String) -> String {
        let lines = LineIndex(markdown)
        var output: [String] = []
        var fence: Character?
        for index in 0..<lines.count {
            let line = lines[index]
            let content = line.drop { $0 == " " }
            let indent = line.distance(from: line.startIndex, to: content.startIndex)
            if indent <= 3, let mark = ["```", "~~~"].first(where: { content.hasPrefix($0) }) {
                let character = mark.first ?? "`"
                if fence == nil {
                    fence = character
                    continue
                } else if fence == character {
                    fence = nil
                    continue
                }
            }
            if fence != nil {
                output.append(String(line))
                continue
            }
            output.append(block(line))
        }
        return output.joined(separator: "\n").trimmingTrailingWhitespace
    }

    /// One line outside code, without its block marks.
    static func block(_ line: Substring) -> String {
        var content = line.drop { $0 == " " }
        let indent = String(line[line.startIndex..<content.startIndex])
        if let heading = NoteText.atxHeading(line) { return inline(heading.text[...]) }
        if isRule(content) { return "" }
        var quoted = false
        while content.first == ">" {
            content = content.dropFirst().drop { $0 == " " }
            quoted = true
        }
        if quoted, let heading = NoteText.atxHeading(content) { return inline(heading.text[...]) }
        for bullet in ["- ", "* ", "+ "] where content.hasPrefix(bullet) {
            return indent + "• " + inline(content.dropFirst(2))
        }
        return (quoted ? "" : indent) + inline(content)
    }

    /// True for a thematic break or a setext underline: three or more of one of "-", "*", "_" or
    /// "=", with spaces between at most.
    static func isRule(_ content: Substring) -> Bool {
        let marks = content.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 2, let mark = marks.first, "-*_=".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark } && (marks.count >= 3 || mark == "=" || mark == "-")
    }

    /// Text without inline marks: emphasis, strike-through, code spans, links, images, autolinks and
    /// escapes.
    static func inline(_ text: Substring) -> String {
        let characters = Array(text)
        var removed = Set<Int>()
        var output = ""
        markEmphasis(characters, removed: &removed)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if removed.contains(index) {
                index += 1
                continue
            }
            if character == "\\", index + 1 < characters.count, characters[index + 1].isPunctuationOrSymbol {
                output.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`", let span = codeSpan(characters, at: index) {
                output += span.text
                index = span.end
                continue
            }
            if character == "!", index + 1 < characters.count, characters[index + 1] == "[",
                let link = link(characters, at: index + 1)
            {
                output += link.text
                index = link.end
                continue
            }
            if character == "[", let link = link(characters, at: index) {
                let text = inline(link.text[...])
                output += text == link.target || link.target.isEmpty ? text : text + " (" + link.target + ")"
                index = link.end
                continue
            }
            if character == "<", let end = characters[index...].firstIndex(of: ">") {
                let inside = String(characters[(index + 1)..<end])
                if ["http://", "https://", "mailto:"].contains(where: { inside.lowercased().hasPrefix($0) }),
                    !inside.contains(where: \.isWhitespace)
                {
                    output += inside
                    index = end + 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// A code span opening at `start`: a run of backticks closed by a run of the same length.
    private static func codeSpan(_ characters: [Character], at start: Int) -> (text: String, end: Int)? {
        var run = 0
        while start + run < characters.count, characters[start + run] == "`" { run += 1 }
        var index = start + run
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var closing = 0
            while index + closing < characters.count, characters[index + closing] == "`" { closing += 1 }
            if closing == run {
                var text = String(characters[(start + run)..<index])
                if text.count >= 2, text.hasPrefix(" "), text.hasSuffix(" "), text.contains(where: { $0 != " " }) {
                    text = String(text.dropFirst().dropLast())
                }
                return (text, index + closing)
            }
            index += closing
        }
        return nil
    }

    /// A link opening at `start`: `[text](target "title")`, with no brackets inside the text.
    private static func link(_ characters: [Character], at start: Int) -> (text: String, target: String, end: Int)? {
        guard characters[start] == "[", let close = characters[(start + 1)...].firstIndex(of: "]"),
            !characters[(start + 1)..<close].contains("["), close + 1 < characters.count,
            characters[close + 1] == "(", let end = characters[(close + 2)...].firstIndex(of: ")")
        else { return nil }
        let inside = String(characters[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
        let target = inside.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let cleaned = target.hasPrefix("<") && target.hasSuffix(">") ? String(target.dropFirst().dropLast()) : target
        return (String(characters[(start + 1)..<close]), cleaned, end + 1)
    }

    /// Marks the runs of `*`, `_` and `~~` that open and close emphasis, so they are left out. A run
    /// opens when text follows it and closes when text comes before it; an underscore inside a word,
    /// as in `snake_case`, is never a mark.
    private static func markEmphasis(_ characters: [Character], removed: inout Set<Int>) {
        var openers: [(mark: Character, length: Int, start: Int)] = []
        var index = 0
        var inCode = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\", !inCode {
                index += 2
                continue
            }
            if character == "`" { inCode.toggle() }
            guard !inCode, character == "*" || character == "_" || character == "~" else {
                index += 1
                continue
            }
            var length = 1
            while index + length < characters.count, characters[index + length] == character { length += 1 }
            let before: Character? = index > 0 ? characters[index - 1] : nil
            let after: Character? = index + length < characters.count ? characters[index + length] : nil
            let isWordBefore = before.map { $0.isLetter || $0.isNumber } ?? false
            let isWordAfter = after.map { $0.isLetter || $0.isNumber } ?? false
            var canOpen = after.map { !$0.isWhitespace } ?? false
            var canClose = before.map { !$0.isWhitespace } ?? false
            if character == "_" {
                canOpen = canOpen && !isWordBefore
                canClose = canClose && !isWordAfter
            }
            if character == "~" && length != 2 {
                canOpen = false
                canClose = false
            }
            if canClose, let match = openers.lastIndex(where: { $0.mark == character && $0.length == length }) {
                let opener = openers[match]
                for offset in 0..<length {
                    removed.insert(opener.start + offset)
                    removed.insert(index + offset)
                }
                openers.removeSubrange(match...)
            } else if canOpen, length <= 3 {
                openers.append((character, length, index))
            }
            index += length
        }
    }
}

extension Character {
    /// True for ASCII punctuation and symbols, which a backslash escapes in Markdown.
    nonisolated var isPunctuationOrSymbol: Bool {
        isASCII && (isPunctuation || isSymbol)
    }
}
