import Foundation

/// The text work an action does on a whole note, off the main thread. A note may hold a megabyte,
/// and a form or an action must open within a frame.
nonisolated enum NoteWork {
    @concurrent static func parse(_ text: String) async -> NoteText {
        NoteText.parse(text)
    }

    @concurrent static func composed(_ text: NoteText) async -> String {
        text.composed
    }

    @concurrent static func retitled(_ text: String, title: String) async -> String {
        NoteText.retitled(text, title: title)
    }

    @concurrent static func appending(_ addition: String, to text: String) async -> String {
        NoteText.appending(addition, to: text)
    }

    @concurrent static func plainText(_ markdown: String) async -> String {
        PlainText.of(markdown)
    }
}
