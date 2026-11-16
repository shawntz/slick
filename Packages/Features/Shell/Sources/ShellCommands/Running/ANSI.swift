/// ANSI escape sequences in a command's output.
///
/// The page keeps them, and the host draws them as color. Copy Output and Paste Output strip them,
/// because another app would show them as text.
///
/// The rules are the host's own, so the text that is copied or pasted never holds anything the page
/// hides. Paste Output may paste into a terminal, where a hidden line would run. A feature cannot
/// import the host's parser, so the rules are restated here.
nonisolated enum ANSI {
    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"

    /// The text without escape sequences, as the page shows it:
    /// - a CSI sequence, `ESC [`, runs to its final byte, from "@" to "~";
    /// - an OSC, DCS, APC or PM string, `ESC ]`, `ESC P`, `ESC _` or `ESC ^`, runs to BEL or to
    ///   `ESC \`, and an ESC followed by anything else stays inside it;
    /// - any other ESC hides itself and the scalar after it;
    /// - a sequence the text ends inside hides everything from its start.
    static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.contains(escape) else { return text }
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index] == escape else {
                let next = scalars[index...].firstIndex(of: escape) ?? scalars.endIndex
                result.append(contentsOf: scalars[index..<next])
                index = next
                continue
            }
            guard let end = sequenceEnd(scalars, from: index) else { break }
            index = end
        }
        return String(result)
    }

    /// The index just past the sequence that starts at `start`, or nil when the text ends first.
    private static func sequenceEnd(
        _ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index? {
        let introducer = scalars.index(after: start)
        guard introducer < scalars.endIndex else { return nil }
        var index = scalars.index(after: introducer)
        switch scalars[introducer] {
        case "[":
            while index < scalars.endIndex {
                if (0x40...0x7E).contains(scalars[index].value) { return scalars.index(after: index) }
                index = scalars.index(after: index)
            }
            return nil
        case "]", "P", "_", "^":
            while index < scalars.endIndex {
                let scalar = scalars[index]
                let next = scalars.index(after: index)
                if scalar == bell { return next }
                if scalar == escape {
                    guard next < scalars.endIndex else { return nil }
                    if scalars[next] == "\\" { return scalars.index(after: next) }
                }
                index = next
            }
            return nil
        default:
            return index
        }
    }
}
