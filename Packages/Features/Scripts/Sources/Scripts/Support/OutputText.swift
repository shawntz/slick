import Foundation

/// Picks the lines of a script's output that toasts, HUDs and subtitles show.
nonisolated enum OutputText {
    /// A toast or subtitle line longer than this is cut, so a script that prints one huge line
    /// cannot flood the panel.
    static let maximumLineLength = 300

    /// The first line with visible text, without escape sequences.
    static func firstLine(_ text: String) -> String? {
        lines(text).first { !$0.isEmpty }
    }

    /// The first line with visible text, as written, escape sequences included.
    static func firstRawLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first { !ANSI.strip(String($0)).trimmed.isEmpty }.map(String.init)
    }

    /// The last line with visible text, without escape sequences.
    static func lastLine(_ text: String) -> String? {
        lines(text).last { !$0.isEmpty }
    }

    /// Up to `count` last lines with visible text, for an error message.
    static func lastLines(_ text: String, count: Int) -> String? {
        let visible = lines(text).filter { !$0.isEmpty }.suffix(count)
        return visible.isEmpty ? nil : visible.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        ANSI.strip(text).split(whereSeparator: \.isNewline).map { line in
            let trimmed = line.trimmed
            return trimmed.count > maximumLineLength ? String(trimmed.prefix(maximumLineLength)) + "…" : trimmed
        }
    }
}

nonisolated extension StringProtocol {
    /// The text without leading and trailing spaces, tabs and line breaks.
    var trimmed: String {
        String(self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
