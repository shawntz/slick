import Foundation
import Kit

/// Quick capture in root search: `note`, a space and some text shows Create Note with that text at
/// the top, and Return saves it.
///
/// It runs on every keystroke on the main thread, so it refuses any query that does not start with
/// "n" or "N" on its first byte, reads at most a few bytes more to match the keyword, and builds its
/// title from the first characters of the text only.
final class QuickCapture: InstantProvider {
    let namespace = NoteIDs.captureNamespace
    private unowned let feature: NotesFeature

    /// The most characters of the text the row's title shows.
    static let titleLength = 60
    /// The most bytes a captured note keeps, so a pasted book does not become one note and the
    /// keystroke never copies more than this.
    static let maximumBytes = 100_000

    init(feature: NotesFeature) {
        self.feature = feature
    }

    func answer(for query: String) -> InstantAnswer? {
        guard let text = Self.text(in: query), feature.context.settings[NotesSettings.quickCapture] else { return nil }
        let shown = DisplayText.oneLine(String(text.prefix(Self.titleLength + 1)))
        let title = shown.count > Self.titleLength ? String(shown.prefix(Self.titleLength - 1)) + "…" : shown
        let row = Row(
            id: ItemID(namespace, "new"), title: Strings.captureTitle(title), subtitle: Strings.captureSubtitle,
            icon: .symbol("square.and.pencil"), payload: Payload(String(Self.capped(text, bytes: Self.maximumBytes))),
            memory: .never)
        return InstantAnswer(rows: [row], claimsTop: true)
    }

    /// The text after the keyword and a space, or nil when the query is not a capture.
    static func text(in query: String) -> Substring? {
        let keyword = NoteIDs.captureKeyword.utf8
        let bytes = query.utf8
        guard let first = bytes.first, first | 0x20 == UInt8(ascii: "n"), bytes.count > keyword.count + 1 else {
            return nil
        }
        var position = bytes.startIndex
        for expected in keyword {
            guard bytes[position] | 0x20 == expected else { return nil }
            position = bytes.index(after: position)
        }
        guard bytes[position] == UInt8(ascii: " ") else { return nil }
        // The blanks after the keyword, at most ``blankLimit`` of them: a pasted run of blanks must
        // not cost the keystroke a pass over all of it.
        let rest = query[position...]
        var start = rest.startIndex
        var blanks = 0
        while start < rest.endIndex, rest[start].isWhitespace {
            blanks += 1
            guard blanks <= blankLimit else { return nil }
            start = rest.index(after: start)
        }
        let text = rest[start...]
        guard NoteText.showsText(text, within: 4_096) else { return nil }
        return text
    }

    /// The most blanks quick capture skips after `note`. A query with more is not a capture.
    static let blankLimit = 1_024

    /// The text cut to at most `bytes` UTF-8 bytes, at the start of a character's scalar. Constant
    /// time on the keystroke path.
    static func capped(_ text: Substring, bytes: Int) -> Substring {
        let utf8 = text.utf8
        guard var end = utf8.index(utf8.startIndex, offsetBy: bytes, limitedBy: utf8.endIndex), end < utf8.endIndex
        else { return text }
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 { end = utf8.index(before: end) }
        return text[..<end]
    }

    /// Built from the row's payload, which holds the text.
    func actions(for row: Row) -> [Action] {
        guard row.id.namespace == namespace, let text = row.payload?.string, NoteText.isVisible(text[...]) else {
            return []
        }
        let feature = feature
        return [
            Action(Strings.saveCapture, id: "save", icon: .symbol("square.and.arrow.down")) { _ in
                _ = try await feature.library.create(text.trimmingTrailingWhitespace + "\n")
                return .close(hud: .success(Strings.saved))
            },
            Action(Strings.editBeforeSaving, id: "edit", icon: .symbol("pencil"), shortcut: .secondaryAction) { _ in
                .push(.form(feature.forms.create(body: text)))
            },
            Action(Strings.appendCommand, id: "append", icon: .symbol("text.append")) { _ in
                .push(.list(feature.pickerPage(text: text)))
            },
        ]
    }
}
