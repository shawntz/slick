import Foundation
import Kit

/// A note's text taken apart: front matter, the title and how it is written, the body, and the tags
/// on the last line. Pure, so it runs on any thread.
///
/// The title is the first line with visible text, after any front matter. When that line is a
/// heading, the title is the heading's text. So a note that starts with a heading is titled by it,
/// and any other note by its first line. A heading further down never becomes the title, because
/// a note such as a list with a "Later" heading at the end is not about "Later".
///
/// Tags live in the file, on the note's last line, as `#tag` words and nothing else. Bear,
/// Obsidian and iA Writer read such a line as tags, and every other editor shows it as plain text.
/// A `#word` anywhere else is text, so `#42` in a sentence or `#include` in code is never a tag.
nonisolated struct NoteText: Hashable, Sendable {
    /// How the title line is written.
    nonisolated enum TitleStyle: Hashable, Sendable {
        /// `# Title`, at this heading level.
        case heading(Int)
        /// `Title` over a line of `=` or `-`.
        case underlined(Character)
        /// A plain first line.
        case line
        /// No title line: the note shows no text, or the user left the title empty.
        case none
    }

    /// Front matter at the top, kept as it was, ending with a line break. Empty when there is none.
    var frontMatter: String
    /// The title as written, without heading marks. It may hold Markdown such as emphasis.
    var title: String
    var style: TitleStyle
    /// Everything between the title and the tag line, without blank lines around it.
    var body: String
    /// The tags of the tag line, without "#", in their order.
    var tags: [String]

    init(frontMatter: String = "", title: String, style: TitleStyle, body: String, tags: [String] = []) {
        self.frontMatter = frontMatter
        self.title = title
        self.style = style
        self.body = body
        self.tags = tags
    }

    // MARK: Reading

    /// The parts of a note's text. Reads only line starts and the lines it needs, so a large note
    /// costs one pass over its bytes.
    static func parse(_ text: String) -> NoteText {
        let lines = LineIndex(text)
        let layout = Layout(lines)
        let frontMatter = layout.frontMatterEnd.map { String(text[..<lines.nextStart($0)]) } ?? ""
        guard let titleLine = layout.titleLine else {
            return NoteText(frontMatter: frontMatter, title: "", style: .none, body: "")
        }
        let first = lines[titleLine]
        let title: String
        let style: TitleStyle
        if let heading = atxHeading(first) {
            (title, style) = (heading.text, .heading(heading.level))
        } else if let mark = layout.underline {
            (title, style) = (trimmed(first), .underlined(mark))
        } else {
            (title, style) = (trimmed(first), .line)
        }
        let bodyEnd = layout.tagLine ?? lines.count
        return NoteText(
            frontMatter: frontMatter, title: title, style: style,
            body: lines.text(from: layout.bodyStart, to: bodyEnd),
            tags: layout.tagLine.flatMap { tagLine(lines[$0]) } ?? [])
    }

    /// Where the parts of a note lie, by line.
    nonisolated struct Layout {
        /// The last line of the front matter.
        var frontMatterEnd: Int?
        /// The title's line, or nil when no line shows text.
        var titleLine: Int?
        /// The underline's character when the title is a setext heading.
        var underline: Character?
        /// The first line after the title.
        var bodyStart: Int
        /// The tag line, when the note ends with one.
        var tagLine: Int?

        init(_ lines: LineIndex) {
            frontMatterEnd = lines.frontMatterEnd()
            var index = frontMatterEnd.map { $0 + 1 } ?? 0
            while index < lines.count, !NoteText.isVisible(lines[index]) { index += 1 }
            guard index < lines.count else {
                bodyStart = lines.count
                return
            }
            titleLine = index
            bodyStart = index + 1
            let first = lines[index]
            if NoteText.atxHeading(first) == nil, index + 1 < lines.count, NoteText.canBeUnderlined(first),
                let mark = NoteText.underline(lines[index + 1])
            {
                underline = mark
                bodyStart = index + 2
            }
            if let last = lines.lastVisible(from: bodyStart), NoteText.tagLine(lines[last]) != nil,
                !lines.isInsideFence(line: last, from: bodyStart)
            {
                tagLine = last
            }
        }
    }

    // MARK: Changing in place

    /// The text with its title line replaced and every other byte kept. A heading keeps its level
    /// and a setext title its underline. A note with no title line gets a heading at the top, after
    /// any front matter.
    static func retitled(_ text: String, title: String) -> String {
        let line = titleLine(title)
        let lines = LineIndex(text)
        let layout = Layout(lines)
        guard let index = layout.titleLine else {
            let head = layout.frontMatterEnd.map { String(text[..<lines.nextStart($0)]) } ?? ""
            return head + (head.isEmpty || head.hasSuffix("\n") ? "" : "\n") + "# " + line + "\n"
        }
        let first = lines[index]
        var replacement = line
        if let heading = atxHeading(first) {
            replacement = String(first.prefix { $0 == " " }) + String(repeating: "#", count: heading.level) + " " + line
        }
        var changed = text
        changed.replaceSubrange(lines.range(index), with: replacement)
        return changed
    }

    /// The text with `addition` at its end, before the tag line so the tags stay tags, and every
    /// other byte kept. A list item added after a list item joins the list; anything else starts a
    /// paragraph of its own.
    static func appending(_ addition: String, to text: String) -> String {
        let addition = addition.trimmingTrailingWhitespace
        let lines = LineIndex(text)
        let layout = Layout(lines)
        var head = text.trimmingTrailingWhitespace
        var tail = ""
        if let tagLine = layout.tagLine {
            let start = lines.range(tagLine).lowerBound
            head = text[..<start].trimmingTrailingWhitespace
            tail = "\n\n" + text[start...].trimmingTrailingWhitespace
        }
        guard !head.isEmpty else { return addition + tail + "\n" }
        let lastLine = head.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let firstLine = addition.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let joiner = isListItem(lastLine) && isListItem(firstLine) ? "\n" : "\n\n"
        return head + joiner + addition + tail + "\n"
    }

    /// True for a line that starts a list item: a bullet or a number, then a space.
    static func isListItem(_ line: Substring) -> Bool {
        let content = line.drop { $0 == " " || $0 == "\t" }
        if ["- ", "* ", "+ "].contains(where: { content.hasPrefix($0) }) { return true }
        let digits = content.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = content.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    // MARK: Writing

    /// The note's text as a file holds it: front matter, the title line, a blank line, the body, a
    /// blank line and the tag line, ending with a line break. Reading it back gives the same parts.
    var composed: String {
        var blocks: [String] = []
        let line = Self.titleLine(title)
        if !line.isEmpty {
            switch style {
            case .heading(let level):
                blocks.append(String(repeating: "#", count: min(max(level, 1), 6)) + " " + line)
            case .underlined(let mark):
                blocks.append(line + "\n" + String(repeating: mark, count: max(3, min(line.count, 40))))
            case .line:
                blocks.append(line)
            case .none:
                break
            }
        }
        let body = body.trimmingTrailingWhitespace
        if !body.isEmpty { blocks.append(body) }
        if !tags.isEmpty { blocks.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        var text = frontMatter
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += blocks.joined(separator: "\n\n")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// A title as it can stand on one line of a file: line breaks become spaces, and the ends are
    /// trimmed. Every other character stays as the user typed it.
    static func titleLine(_ title: String) -> String {
        let scalars = title.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: " "
            default: scalar
            }
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Tags

    /// The most tags one note keeps, and the longest tag.
    static let maximumTags = 32
    static let maximumTagLength = 64

    /// A tag as the user typed it, made into the form a tag line holds: without "#", with spaces
    /// turned into "-". Nil when it still holds anything but letters, digits, "_", "-" and "/", is
    /// only digits, or is too long.
    static func cleanTag(_ raw: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return isTag(tag[...]) ? tag : nil
    }

    /// True for the text after "#" in a tag.
    static func isTag(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.count <= maximumTagLength else { return false }
        var hasNonDigit = false
        for character in text {
            if character.isLetter || character == "_" || character == "-" || character == "/" {
                hasNonDigit = true
            } else if !character.isNumber {
                return false
            }
        }
        return hasNonDigit
    }

    /// The tags of a line that holds only `#tag` words, or nil.
    static func tagLine(_ line: Substring) -> [String]? {
        guard line.utf8.count <= 4_096 else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maximumTags else { return nil }
        var tags: [String] = []
        for word in words {
            guard word.first == "#", isTag(word.dropFirst()) else { return nil }
            let tag = String(word.dropFirst())
            if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
        }
        return tags
    }

    // MARK: Lines

    /// True when the text shows something: a character that is neither white space nor invisible,
    /// such as a zero-width space.
    static func isVisible(_ text: Substring) -> Bool {
        text.unicodeScalars.contains { !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint }
    }

    /// True when one of the first `limit` scalars is visible. Stops at the first one, so it costs
    /// little on a long text.
    static func showsText(_ text: Substring, within limit: Int) -> Bool {
        var seen = 0
        for scalar in text.unicodeScalars {
            if !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint { return true }
            seen += 1
            if seen >= limit { return false }
        }
        return false
    }

    static func trimmed(_ line: Substring) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    /// The level and text of an ATX heading: up to three spaces, one to six "#", then a space or the
    /// end of the line. A closing run of "#" is dropped.
    static func atxHeading(_ line: Substring) -> (level: Int, text: String)? {
        let content = line.drop { $0 == " " }
        guard line.distance(from: line.startIndex, to: content.startIndex) <= 3 else { return nil }
        let marks = content.prefix { $0 == "#" }
        guard (1...6).contains(marks.count) else { return nil }
        let rest = content.dropFirst(marks.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if text.allSatisfy({ $0 == "#" }) {
            text = ""
        } else if let closing = text.lastIndex(where: { $0 != "#" }), closing < text.index(before: text.endIndex),
            text[closing] == " " || text[closing] == "\t"
        {
            text = String(text[...closing]).trimmingCharacters(in: .whitespaces)
        }
        return (marks.count, text)
    }

    /// The character of a setext underline: a line of two or more "=" or "-" and nothing else.
    static func underline(_ line: Substring) -> Character? {
        let content = line.trimmingCharacters(in: .whitespaces)
        guard content.count >= 2, let mark = content.first, mark == "=" || mark == "-",
            content.allSatisfy({ $0 == mark })
        else { return nil }
        return mark
    }

    /// False for a line that cannot be a setext heading's text: a list item, a quote, a fence or a
    /// table row.
    static func canBeUnderlined(_ line: Substring) -> Bool {
        let content = line.drop { $0 == " " }
        let starts = ["- ", "* ", "+ ", ">", "```", "~~~", "|"]
        return !starts.contains { content.hasPrefix($0) }
    }
}

/// Where each line of a text starts and ends, found in one pass over its UTF-8 bytes. A "\r\n"
/// ending is a line break like "\n".
nonisolated struct LineIndex {
    private let text: String
    /// Each line's content, without its line break.
    private var ranges: [Range<String.Index>] = []

    init(_ text: String) {
        self.text = text
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex {
            let newline = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) ?? utf8.endIndex
            var end = newline
            if end > start, utf8[utf8.index(before: end)] == UInt8(ascii: "\r") { end = utf8.index(before: end) }
            ranges.append(start..<end)
            start = newline == utf8.endIndex ? newline : utf8.index(after: newline)
        }
    }

    var count: Int { ranges.count }

    subscript(index: Int) -> Substring {
        text[ranges[index]]
    }

    /// The line's content in the text, without its line break.
    func range(_ index: Int) -> Range<String.Index> {
        ranges[index]
    }

    /// Where the line after `index` starts, or the end of the text.
    func nextStart(_ index: Int) -> String.Index {
        index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
    }

    /// The last line of a front matter block that opens the text with `---` and closes with `---`
    /// or `...` within its first 200 lines.
    func frontMatterEnd() -> Int? {
        guard count > 1, self[0].trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for index in 1..<min(count, 200) {
            let line = self[index].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." { return index }
        }
        return nil
    }

    /// The last line at or after `start` that shows text.
    func lastVisible(from start: Int) -> Int? {
        var index = count - 1
        while index >= start {
            if NoteText.isVisible(self[index]) { return index }
            index -= 1
        }
        return nil
    }

    /// True when `line` lies inside a fenced code block that opens at or after `start`.
    func isInsideFence(line: Int, from start: Int) -> Bool {
        var fence: Character?
        for index in start..<line {
            let line = self[index]
            let content = line.drop { $0 == " " }
            guard line.distance(from: line.startIndex, to: content.startIndex) <= 3 else { continue }
            for mark in ["```", "~~~"] where content.hasPrefix(mark) {
                let character = mark.first ?? "`"
                if fence == nil {
                    fence = character
                } else if fence == character {
                    fence = nil
                }
            }
        }
        return fence != nil
    }

    /// The text of the lines `from..<to` without the blank lines at either end or white space at
    /// the very end.
    func text(from start: Int, to end: Int) -> String {
        var first = start
        while first < end, !NoteText.isVisible(self[first]) { first += 1 }
        var last = end - 1
        while last >= first, !NoteText.isVisible(self[last]) { last -= 1 }
        guard first <= last else { return "" }
        return String(text[ranges[first].lowerBound..<ranges[last].upperBound]).trimmingTrailingWhitespace
    }
}

extension StringProtocol {
    /// The text without white space and line breaks at its end.
    nonisolated var trimmingTrailingWhitespace: String {
        var end = endIndex
        while end > startIndex {
            let before = index(before: end)
            guard self[before].isWhitespace else { break }
            end = before
        }
        return String(self[startIndex..<end])
    }
}
