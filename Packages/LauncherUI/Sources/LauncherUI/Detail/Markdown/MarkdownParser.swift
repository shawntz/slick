import Foundation

/// A run of inline Markdown text with one style.
nonisolated struct MarkdownRun: Sendable, Equatable {
    struct Style: OptionSet, Sendable, Hashable {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let code = Style(rawValue: 1 << 2)
    }

    var text: String
    var style: Style = []
    /// The link target, for link text.
    var link: String?
}

/// One block of a Markdown document.
nonisolated enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, [MarkdownRun])
    case paragraph([MarkdownRun])
    /// A list item: its marker as drawn ("•" or "3."), its nesting depth from 0, and its text.
    case listItem(marker: String, depth: Int, [MarkdownRun])
    case quote([MarkdownRun])
    /// A fenced code block's text, without the fences.
    case code(String)
    case rule
}

/// Parses the Markdown that answers and notes use: ATX headings, paragraphs, bulleted and numbered
/// lists, block quotes, fenced code, rules, hard line breaks, and inline strong, emphasis, code and
/// links.
///
/// Each line is classified on its own, so a block can only grow at the end of the document. That
/// is what makes streaming cheap: `MarkdownDocument` re-parses only the last block.
nonisolated enum MarkdownParser {
    /// What a hard line break becomes in a block's text: a line separator, which breaks the line
    /// inside the paragraph, so the paragraph keeps its indents and adds no spacing.
    static let hardBreak: Character = "\u{2028}"

    /// A block and the UTF-8 offset of the line it starts on.
    typealias PlacedBlock = (block: MarkdownBlock, start: Int)

    /// The blocks of `source`, each with the UTF-8 offset of the line it starts on.
    static func blocks(_ source: Substring, lineBreaks: MarkdownLineBreaks = .standard) -> [PlacedBlock] {
        var result: [PlacedBlock] = []
        var paragraph: (lines: [Substring], start: Int)?
        var item: (marker: String, depth: Int, lines: [Substring], start: Int)?
        var quote: (lines: [Substring], start: Int)?
        var code: (lines: [Substring], start: Int, fence: Character, length: Int, indent: Int)?

        func flush() {
            if let open = paragraph {
                result.append((.paragraph(inlines(joined(open.lines, lineBreaks))), open.start))
            }
            if let open = item {
                result.append(
                    (
                        .listItem(marker: open.marker, depth: open.depth, inlines(joined(open.lines, lineBreaks))),
                        open.start
                    ))
            }
            if let open = quote { result.append((.quote(inlines(joined(open.lines, lineBreaks))), open.start)) }
            paragraph = nil
            item = nil
            quote = nil
        }

        let base = source.utf8.startIndex
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let start = source.utf8.distance(from: base, to: rawLine.startIndex)
            if let open = code {
                if let fence = fence(in: line), fence.char == open.fence, fence.length >= open.length,
                    fence.info.isEmpty
                {
                    result.append((.code(open.lines.joined(separator: "\n")), open.start))
                    code = nil
                } else {
                    code?.lines.append(dropIndent(line, upTo: open.indent))
                }
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.dropFirst(indent)
            if indent <= 3, let fence = fence(in: line) {
                flush()
                code = ([], start, fence.char, fence.length, indent)
            } else if trimmed.allSatisfy(\.isWhitespace) {
                flush()
            } else if indent <= 3, let heading = heading(trimmed) {
                flush()
                result.append((.heading(level: heading.level, inlines(String(heading.text))), start))
            } else if indent <= 3, isRule(trimmed) {
                flush()
                result.append((.rule, start))
            } else if let marker = listMarker(trimmed) {
                flush()
                item = (marker.marker, indent / 2, [marker.text], start)
            } else if indent <= 3, trimmed.hasPrefix(">") {
                let text = trimmed.dropFirst().drop { $0 == " " }
                if quote != nil {
                    quote?.lines.append(text)
                } else {
                    flush()
                    quote = ([text], start)
                }
            } else if item != nil {
                item?.lines.append(trimmed)
            } else if quote != nil {
                quote?.lines.append(trimmed)
            } else if paragraph != nil {
                paragraph?.lines.append(trimmed)
            } else {
                paragraph = ([trimmed], start)
            }
        }
        // An unclosed fence runs to the end, as it does while an answer is still streaming in.
        if let open = code { result.append((.code(open.lines.joined(separator: "\n")), open.start)) }
        flush()
        return result
    }

    // MARK: Block syntax

    /// The lines of one paragraph, list item or quote as one text. A line joins the next with a
    /// space, as Markdown's soft line break does, unless it ends in a hard break: two or more
    /// spaces, or a backslash that is not itself escaped. With `.everyNewline` every line break is
    /// hard. The last line never ends in a break, so its trailing spaces and backslash stay as
    /// Markdown says: the spaces are dropped and the backslash is literal.
    private static func joined(_ lines: [Substring], _ lineBreaks: MarkdownLineBreaks) -> String {
        var text = ""
        for (index, line) in lines.enumerated() {
            var trimmed = line.trimmingTrailingWhitespace()
            guard index < lines.count - 1 else {
                text += trimmed
                break
            }
            var isHard = lineBreaks == .everyNewline || line.reversed().prefix { $0 == " " }.count >= 2
            let backslashes = line.last == "\\" ? line.reversed().prefix { $0 == "\\" }.count : 0
            if backslashes % 2 == 1 {
                trimmed = trimmed.dropLast()
                isHard = true
            }
            text += trimmed
            text.append(isHard ? hardBreak : " ")
        }
        return text
    }

    private static func fence(in line: Substring) -> (char: Character, length: Int, info: Substring)? {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingTrailingWhitespace().drop { $0 == " " }
        // A backtick fence's info string may not contain a backtick.
        if first == "`", info.contains("`") { return nil }
        return (first, length, info)
    }

    private static func heading(_ line: Substring) -> (level: Int, text: Substring)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.drop { $0 == " " }.trimmingTrailingWhitespace()
        // An optional closing run of #s, after a space, is not part of the text.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0, closing == text.count || text.dropLast(closing).last == " " {
            text = text.dropLast(closing).trimmingTrailingWhitespace()
        }
        return (level, text)
    }

    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listMarker(_ line: Substring) -> (marker: String, text: Substring)? {
        guard let first = line.first else { return nil }
        if "-*+".contains(first), line.dropFirst().first == " " {
            return ("•", line.dropFirst(2).drop { $0 == " " })
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else {
            return nil
        }
        return ("\(digits).", rest.dropFirst(2).drop { $0 == " " })
    }

    private static func dropIndent(_ line: Substring, upTo count: Int) -> Substring {
        line.dropFirst(min(count, line.prefix { $0 == " " }.count))
    }

    // MARK: Inline syntax

    /// The runs of one block's text: `**strong**`, `*emphasis*`, `` `code` ``, `[text](url)` and
    /// backslash escapes. A delimiter with no closer later in the text stays literal, so an
    /// unfinished `**` mid-stream shows as typed until its closer arrives.
    static func inlines(_ text: String) -> [MarkdownRun] {
        let chars = Array(text)
        var runs: [MarkdownRun] = []
        var buffer = ""
        var style: MarkdownRun.Style = []

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(MarkdownRun(text: buffer, style: style))
            buffer = ""
        }
        func occurs(_ needle: [Character], after index: Int) -> Bool {
            guard index < chars.count, needle.count <= chars.count - index else { return false }
            var position = index
            while position + needle.count <= chars.count {
                if chars[position] == needle[0], Array(chars[position..<position + needle.count]) == needle {
                    return true
                }
                position += 1
            }
            return false
        }

        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count, chars[index + 1].isPunctuation || chars[index + 1].isSymbol {
                buffer.append(chars[index + 1])
                index += 2
                continue
            }
            if char == "`" {
                let length = chars[index...].prefix { $0 == "`" }.count
                if let close = closingBackticks(chars, from: index + length, length: length) {
                    flush()
                    // A line break inside a code span is a space, as Markdown says.
                    var code = String(chars[(index + length)..<close].map { $0 == hardBreak ? " " : $0 })
                    if code.count >= 2, code.first == " ", code.last == " " {
                        code = String(code.dropFirst().dropLast())
                    }
                    runs.append(MarkdownRun(text: code, style: style.union(.code)))
                    index = close + length
                } else {
                    buffer.append(String(repeating: "`", count: length))
                    index += length
                }
                continue
            }
            if char == "[", let link = link(chars, from: index) {
                flush()
                runs.append(MarkdownRun(text: link.text, style: style, link: link.url))
                index = link.end
                continue
            }
            if char == "*" || char == "_" {
                let length = min(3, chars[index...].prefix { $0 == char }.count)
                let before = index > 0 ? chars[index - 1] : " "
                let after = index + length < chars.count ? chars[index + length] : " "
                // An underscore inside a word, as in snake_case, is literal.
                if char == "_", before.isLetter || before.isNumber, after.isLetter || after.isNumber {
                    buffer.append(String(repeating: "_", count: length))
                    index += length
                    continue
                }
                var consumed = 0
                for (trait, size) in [(MarkdownRun.Style.bold, 2), (.italic, 1)] where length - consumed >= size {
                    let delimiter = Array(repeating: char, count: size)
                    if style.contains(trait), !before.isWhitespace {
                        flush()
                        style.remove(trait)
                        consumed += size
                    } else if !style.contains(trait), !after.isWhitespace,
                        occurs(delimiter, after: index + length)
                    {
                        flush()
                        style.insert(trait)
                        consumed += size
                    }
                }
                if consumed == 0 {
                    buffer.append(String(repeating: char, count: length))
                    index += length
                } else {
                    index += consumed
                }
                continue
            }
            buffer.append(char)
            index += 1
        }
        flush()
        return runs
    }

    private static func closingBackticks(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < chars.count {
            if chars[index] == "`" {
                let run = chars[index...].prefix { $0 == "`" }.count
                if run == length { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func link(_ chars: [Character], from start: Int) -> (text: String, url: String, end: Int)? {
        guard let close = chars[(start + 1)...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
            let end = chars[(close + 2)...].firstIndex(of: ")")
        else { return nil }
        let url = String(chars[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return nil }
        return (String(chars[(start + 1)..<close]), url, end + 1)
    }
}

extension Substring {
    nonisolated fileprivate func trimmingTrailingWhitespace() -> Substring {
        var result = self
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return result
    }
}
