import Foundation
import Kit

/// How conversations read as Markdown: on a detail page, in a preview and in an exported file.
/// Every function is pure and `nonisolated`, so long transcripts render off the main thread.
nonisolated enum Transcript {
    /// Between one answer and the next question.
    static let separator = "\n\n---\n\n"

    /// The conversation as a detail page shows it: each question quoted, then its answer and a note
    /// when the answer ended early. With `hidesFirstQuestion`, the first question is left out, as for
    /// a command on selected text, whose question is the whole prompt.
    static func render(_ messages: [ChatMessage], hidesFirstQuestion: Bool = false) -> String {
        var output = ""
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                if index == 0 && hidesFirstQuestion { continue }
                if !output.isEmpty { output += separator }
                output += quote(message.label ?? message.text) + "\n\n"
            case .assistant:
                output += message.text
                if let note = note(for: message.ending) { output += note }
            }
        }
        return output
    }

    /// Text as a Markdown block quote, line by line.
    static func quote(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { "> " + $0 }.joined(
            separator: "\n")
    }

    /// The note after an answer that ended early, starting with a blank line. Nil for a whole answer.
    static func note(for ending: AnswerEnding?) -> String? {
        switch ending {
        case nil: nil
        case .stopped: "\n\n" + bold(Strings.Notes.stopped)
        case .lengthLimit: "\n\n" + bold(Strings.Notes.lengthLimit) + "\n\n" + Strings.Notes.lengthLimitMessage
        case .refused: "\n\n" + bold(Strings.Notes.refused) + "\n\n" + Strings.Notes.refusedMessage
        case .failed(let failure): "\n\n" + bold(failure.title) + "\n\n" + failure.message
        }
    }

    /// The note under a question that was kept without an answer and is not sent until the user
    /// asks. It follows a rendered transcript, which ends with a blank line after a question.
    static var heldNote: String {
        bold(Strings.Notes.notSent) + "\n\n" + Strings.Notes.notSentMessage
    }

    private static func bold(_ text: String) -> String { "**" + text + "**" }

    /// The metadata a detail page shows for the provider that answers.
    static func metadata(model: String, host: String?) -> [MetadataItem] {
        [
            .label(Strings.Detail.model, value: model),
            .label(Strings.Detail.sentTo, value: host ?? Strings.Detail.thisMac),
        ]
    }

    // MARK: - Code blocks

    /// The contents of the last fenced code block in Markdown text, without its fences and info
    /// string. Only blocks with a closing fence count, so a cut-off block is not copied as if whole.
    static func lastCodeBlock(in text: String) -> String? {
        var last: String?
        var open: (marker: Character, length: Int)?
        var lines: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let fence = Self.fence(line)
            if let current = open {
                if let fence, fence.marker == current.marker, fence.length >= current.length, fence.isBare {
                    last = lines.joined(separator: "\n")
                    open = nil
                    lines = []
                } else {
                    lines.append(line)
                }
            } else if let fence {
                open = (fence.marker, fence.length)
            }
        }
        return last
    }

    /// The fence a line starts with: three or more backticks or tildes after at most three spaces.
    private static func fence(_ line: Substring) -> (marker: Character, length: Int, isBare: Bool)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
        return (marker, length, info.isEmpty)
    }

    // MARK: - Titles

    /// A one-line title from free text: the first line with words, white space collapsed, at most 60
    /// characters.
    static func title(from text: String, limit: Int = 60) -> String {
        let firstLine =
            text.prefix(2_000).split(whereSeparator: \.isNewline).first {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            } ?? ""
        let words = firstLine.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.allSatisfy(Self.isControl) })
        let collapsed = words.joined(separator: " ")
        guard !collapsed.isEmpty else { return Strings.Chat.untitled }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Free text on one line: every run of white space, line breaks and invisible characters becomes
    /// one space, cut at `limit` characters. Empty when there are no words.
    static func oneLine(_ text: String, limit: Int) -> String {
        let words = text.prefix(4_000).split(whereSeparator: {
            $0.isWhitespace || $0.unicodeScalars.allSatisfy(Self.isControl)
        })
        let collapsed = words.joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
    }

    /// A short single-line preview of an answer, for a list subtitle.
    static func preview(_ text: String) -> String {
        title(from: text, limit: 100)
    }

    // MARK: - Export

    /// A conversation as a Markdown document, with what was sent and what came back.
    static func export(_ conversation: Conversation, clock: any ClockService) -> String {
        let style = Date.FormatStyle(
            date: .abbreviated, time: .shortened, locale: clock.locale, calendar: clock.calendar,
            timeZone: clock.timeZone)
        var output = "# " + conversation.displayTitle + "\n\n"
        output += Strings.Export.started(conversation.created.formatted(style)) + "\n"
        for message in conversation.messages {
            switch message.role {
            case .user:
                output += "\n## " + Strings.Export.you + "\n\n" + message.text + "\n"
            case .assistant:
                let heading =
                    message.model.map { Strings.Export.assistant + " (" + $0 + ")" } ?? Strings.Export.assistant
                output += "\n## " + heading + "\n\n" + message.text
                if let note = note(for: message.ending) { output += note }
                output += "\n"
            }
        }
        return output
    }

    /// A file name for an exported conversation: the title without characters a file name cannot
    /// hold, and the Markdown extension.
    static func fileName(for conversation: Conversation) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = conversation.displayTitle.unicodeScalars.map { unsafe.contains($0) ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .-")).prefix(80)
        return (trimmed.isEmpty ? Strings.Chat.untitled : String(trimmed)) + ".md"
    }
}
