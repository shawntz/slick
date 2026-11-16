import Foundation

/// File names for notes: made from a title, safe on every Mac volume and in every editor, and
/// unique in the folder. Pure, so it runs on any thread.
nonisolated enum NoteFileName {
    /// The extension of every note the feature writes.
    static let pathExtension = "md"
    /// Extensions the feature reads as notes, compared without case.
    static let readExtensions = ["md", "markdown"]
    /// The longest base name, in characters and in UTF-8 bytes. A volume allows 255 bytes, so a
    /// number and the extension always fit.
    static let maximumCharacters = 80
    static let maximumBytes = 200
    /// The base name of a note whose title shows nothing.
    static let untitled = "Untitled"

    /// A base name, without the extension, made from a title. Slashes and colons become "-",
    /// because Finder shows a colon as a slash; line breaks, other control characters and the
    /// invisible characters that reorder or hide text are dropped, except the joiner inside emoji
    /// sequences; runs of white space become one
    /// space; dots and spaces leave both ends, so the file is never hidden. The result is cut to
    /// ``maximumCharacters`` and ``maximumBytes`` and composed as volumes store it.
    static func base(for title: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in title.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            let category = scalar.properties.generalCategory
            // The zero-width joiner stays, so an emoji sequence keeps its shape.
            if category == .control || (category == .format && scalar != "\u{200D}") || category == .surrogate
                || category == .privateUse || category == .unassigned
            {
                continue
            }
            lastWasSpace = false
            scalars.append(scalar == "/" || scalar == ":" || scalar == "\\" ? "-" : scalar)
        }
        var name = trimmedEnds(String(scalars))
        var cut = ""
        var bytes = 0
        for character in name.prefix(maximumCharacters) {
            let size = character.utf8.count
            guard bytes + size <= maximumBytes else { break }
            cut.append(character)
            bytes += size
        }
        name = trimmedEnds(cut)
        return name.isEmpty ? untitled : name
    }

    /// `base.md`, or `base 2.md`, `base 3.md` and so on: the first name `isTaken` refuses.
    static func unique(_ base: String, isTaken: (String) -> Bool) -> String {
        let first = base + "." + pathExtension
        guard isTaken(first) else { return first }
        var number = 2
        while true {
            let candidate = base + " \(number)." + pathExtension
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// The form two names take when a volume would hold them as one file: case folded and composed.
    /// Mac volumes ignore case and Unicode composition by default.
    static func comparable(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// True for a name the feature reads as a note: one path component, not hidden, ending in
    /// ".md" or ".markdown", with no NUL. Anything else, such as "../x.md" in a crafted row, is
    /// refused before it reaches the disk.
    static func isNoteFile(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.contains("/"),
            !name.utf8.contains(0)
        else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let last = parts.last, !parts.dropLast().joined(separator: ".").isEmpty else {
            return false
        }
        return readExtensions.contains(last.lowercased())
    }

    /// The name without its extension, for a note with no text to take a title from.
    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        return String(name[..<dot])
    }

    private static func trimmedEnds(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
    }
}
