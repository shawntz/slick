import Foundation
import Kit

/// What a row shows for a note: its title and the first line of its body. Pure.
nonisolated enum NoteTitles {
    /// The most characters a title or preview shows.
    static let titleLength = 200
    static let previewLength = 120

    /// The title to show: the title line without inline marks, on one line, drawn in stored order.
    /// A note with no visible text shows its file name, then "Untitled Note".
    static func title(_ text: NoteText, fileName: String?) -> String {
        let line = shown(text.title)
        if !line.isEmpty { return line }
        if let fileName {
            let name = DisplayText.fileName(NoteFileName.stem(fileName), limit: titleLength)
            if name != DisplayText.untitled { return name }
        }
        return Strings.untitledNote
    }

    /// The base of the file name for a note: its title without inline marks, before it is made
    /// safe, or the file's own name when the note shows no title.
    static func fileBase(_ text: NoteText, fileName: String?) -> String {
        let plain = PlainText.block(Substring(text.title.prefix(NoteFileName.maximumCharacters * 4)))
        let base = NoteFileName.base(for: plain)
        guard base == NoteFileName.untitled, let fileName else { return base }
        return NoteFileName.base(for: NoteFileName.stem(fileName))
    }

    /// The first line of the body with text, without marks, or empty.
    static func preview(_ text: NoteText) -> String {
        let body = text.body
        let end = body.utf8.firstIndex(of: UInt8(ascii: "\n")) ?? body.endIndex
        return String(shown(body[..<end], limit: previewLength))
    }

    /// Text as a row shows it: marks dropped, one line, trimmed, cut with an ellipsis, and empty
    /// when nothing in it is visible.
    static func shown(_ text: some StringProtocol, limit: Int = titleLength) -> String {
        let plain = PlainText.block(Substring(text.prefix(limit * 2)))
        let line = DisplayText.oneLine(plain).trimmingCharacters(in: .whitespaces)
        guard NoteText.isVisible(line[...]) else { return "" }
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }
}
