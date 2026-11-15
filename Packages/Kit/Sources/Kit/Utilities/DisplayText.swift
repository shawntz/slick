/// Text that someone else chose, made safe to show: file names, window and menu titles, anything
/// another app or a person typed.
///
/// A name can hold a line break, which breaks a title over two lines, or a right-to-left override,
/// which makes `invoice<U+202E>fdp.app` draw as "invoiceppa.pdf". Pass such text through here
/// before it reaches a title, a subtitle, a question or a toast.
public enum DisplayText {
    /// The name shown for a file name with nothing visible in it.
    public static let untitled = "Untitled Item"

    /// Text on one line that draws in the order it is stored.
    ///
    /// Line breaks, other control characters, and the line and paragraph separators become spaces.
    /// The controls that reorder text, the embeddings, overrides and isolates from U+202A to
    /// U+202E and from U+2066 to U+2069, become U+FFFD, so the user sees that something is there.
    /// Each replaced character is one UTF-16 unit and so is its replacement, so highlight ranges
    /// stay right. Text with nothing to replace comes back unchanged, without a copy.
    public static func oneLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { replacement(for: $0) != nil }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(replacement(for: scalar) ?? scalar)
        }
        return String(scalars)
    }

    /// A file or folder name ready for a title or a question, such as "Move “name” to the Trash?".
    ///
    /// The name is put on one line as ``oneLine(_:)`` does, cut to `limit` characters with an
    /// ellipsis, and never blank: a name with nothing visible, such as a lone space or a zero-width
    /// space, shows as ``untitled``. Pass the name itself, such as `url.lastPathComponent`, not a
    /// path. Quote it with curly quotes in a sentence.
    ///
    /// - Parameter limit: The most characters shown, ellipsis included. At least 2.
    public static func fileName(_ name: String, limit: Int = 60) -> String {
        let line = oneLine(name)
        let visible = line.unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
        }
        guard visible else { return untitled }
        let limit = max(2, limit)
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }

    private static func replacement(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return " "
        default: break
        }
        let value = scalar.value
        if (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { return "\u{FFFD}" }
        return nil
    }
}
