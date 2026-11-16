import Foundation

/// A command the user typed, checked before it may run.
///
/// The shell gets ``text`` as one argument after `-c`, exactly as typed. Nothing is added to it or
/// spliced around it. A command that could look different from what runs is refused: one with a
/// line break or another control character, one with a character that changes the order text is
/// drawn in, and one that starts with a hyphen or a plus sign, which zsh and bash read as an option
/// before `-c` takes its command.
///
/// A command that could hide part of itself is refused too. The row is cut at its end and the
/// one-line field shows the end after a paste, so padding in the middle would hide a second command
/// from both. So a command may not hold a character that draws as a blank or as nothing, and may
/// not hold more than ``longestRun`` spaces or tabs in a row between its words.
nonisolated struct ShellCommand: Hashable, Sendable {
    /// The most UTF-8 bytes a command may have. A longer one is refused before it is scanned.
    static let maximumBytes = 32 * 1024
    /// The most spaces and tabs in a row between words, as for the text of a link.
    static let longestRun = 3

    /// What the shell runs, as typed.
    let text: String
    /// The text without spaces and tabs at either end: what titles show and history keeps.
    let trimmed: String
    /// True when the text starts with a space or a tab. As in a shell, such a command is never saved.
    let isHidden: Bool

    /// Why a command cannot run.
    enum Problem: Error, Hashable, Sendable {
        case empty
        case tooLong
        case lineBreak
        case directionControl
        case invisibleCharacter
        case longSpace
        case startsWithHyphen
        case startsWithPlus
    }

    private init(text: String, trimmed: String) {
        self.text = text
        self.trimmed = trimmed
        isHidden = text.unicodeScalars.first.map(Self.isBlank) ?? false
    }

    /// Checks text for running. The length is checked first, so a pasted page is refused without a
    /// scan. A command with nothing visible, such as a lone no-break space, counts as empty.
    static func check(_ text: String) -> Result<ShellCommand, Problem> {
        guard text.utf8.count <= maximumBytes else { return .failure(.tooLong) }
        for scalar in text.unicodeScalars {
            if let problem = problem(with: scalar) { return .failure(problem) }
        }
        let trimmed = trimmedText(text)
        let visible = trimmed.unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint && scalar != "\u{2800}"
        }
        guard visible else { return .failure(.empty) }
        if let problem = hiddenText(in: trimmed) { return .failure(problem) }
        guard !trimmed.hasPrefix("-") else { return .failure(.startsWithHyphen) }
        guard !trimmed.hasPrefix("+") else { return .failure(.startsWithPlus) }
        return .success(ShellCommand(text: text, trimmed: trimmed))
    }

    /// The scalars a command may not hold. A tab is allowed: a shell reads it as a space.
    private static func problem(with scalar: Unicode.Scalar) -> Problem? {
        if scalar == "\t" { return nil }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return .lineBreak
        default: break
        }
        let value = scalar.value
        if (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { return .directionControl }
        return nil
    }

    /// The first way the text could hide part of itself: a character that draws as a blank or as
    /// nothing, or a long run of spaces and tabs. The text has no spaces or tabs at either end, so
    /// every run in it lies between words.
    private static func hiddenText(in trimmed: String) -> Problem? {
        var run = 0
        var previous: Unicode.Scalar?
        for scalar in trimmed.unicodeScalars {
            if isBlank(scalar) {
                run += 1
                if run > longestRun { return .longSpace }
            } else {
                run = 0
                if isInvisible(scalar, after: previous) { return .invisibleCharacter }
            }
            previous = scalar
        }
        return nil
    }

    /// True for white space other than a space or a tab, a default-ignorable code point such as a
    /// zero width space or a Hangul filler, the blank Braille pattern, and private-use and
    /// unassigned code points, which a font may draw as nothing. The zero width joiner and the
    /// variation selectors are allowed right after an emoji, where they shape it.
    private static func isInvisible(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        if shapesEmoji(scalar) {
            guard let previous else { return true }
            return !(previous.properties.isEmoji || shapesEmoji(previous))
        }
        let properties = scalar.properties
        if properties.isWhitespace || properties.isDefaultIgnorableCodePoint || scalar == "\u{2800}" { return true }
        switch properties.generalCategory {
        case .privateUse, .unassigned: return true
        default: return false
        }
    }

    /// The zero width joiner and the variation selectors, which change the emoji before them and draw
    /// nothing of their own.
    private static func shapesEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{200D}" || (0xFE00...0xFE0F).contains(scalar.value)
    }

    /// The text without spaces and tabs at either end. Other white space stays, because a shell
    /// does not read it as a space.
    private static func trimmedText(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isBlank($0) }),
            let last = scalars.lastIndex(where: { !isBlank($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }
}

/// A root search query that hands a command to this feature: ">" and a command after it.
nonisolated enum RootQuery {
    /// The prefix, as Alfred users type it.
    static let prefix = UInt8(ascii: ">")

    /// True when the query starts with ">". The prefix alone gets a hint that runs nothing, so
    /// Return never opens a web search for it. Root search asks on every keystroke, so this reads
    /// the first byte and nothing else.
    static func claims(_ query: String) -> Bool {
        query.utf8.first == prefix
    }

    /// The command in a query: everything after ">" and one space that may follow it. Nil when the
    /// query does not start with ">". A further space marks a command that is not saved.
    static func commandText(in query: String) -> String? {
        guard query.utf8.first == prefix else { return nil }
        var rest = query.unicodeScalars.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// The query that holds a command, so a second Return runs it. A command that is not saved
    /// keeps its marker: a second space after the prefix.
    static func query(for command: ShellCommand) -> String {
        (command.isHidden ? ">  " : "> ") + command.trimmed
    }
}
