import Foundation
import Kit

/// What one key press or click means for keyword matching.
nonisolated public enum TypingEvent: Hashable, Sendable {
    /// The text a key typed. Empty for a dead key, which types nothing until the next key composes
    /// a character with it.
    case characters(String)
    case backspace
    case forwardDelete
    /// An arrow, Home, End, Page Up, Page Down or a function key: the insertion point may move.
    case navigation
    /// A key pressed with Command or Control, which may move the insertion point or edit text.
    case shortcut
    /// A modifier key alone went down or up.
    case modifiers
    case escape
    /// A mouse button went down: the insertion point may have moved.
    case click
    /// Another app or window came forward.
    case focusChanged

    /// True for events that come from the keyboard.
    public var isKey: Bool {
        switch self {
        case .click, .focusChanged: false
        default: true
        }
    }
}

/// A keyword the user just typed.
nonisolated public struct KeywordMatch: Hashable, Sendable {
    /// Tells this match from earlier ones in the same buffer.
    public var id: Int
    public var keyword: String
    /// The delimiter typed after the keyword, when the trigger waits for one.
    public var delimiter: Character?

    /// The characters to delete: the keyword and its delimiter.
    public var deleteCount: Int {
        keyword.count + (delimiter == nil ? 0 : 1)
    }
}

/// What to type in place of a keyword: delete, type, then move the insertion point left. For a
/// command, the keyword is deleted and the command runs after.
nonisolated public struct ExpansionPlan: Hashable, Sendable {
    public var deleteCount: Int
    public var text: String
    public var leftCount: Int
    /// The command to run once the keyword is gone, with its arguments.
    public var command: ItemID?
    public var arguments: [String: String] = [:]

    /// The keystrokes that carry out the plan.
    public var keystrokes: [Keystroke] {
        Keystroke.deletes(deleteCount) + (text.isEmpty ? [] : [.text(text)]) + Keystroke.lefts(leftCount)
    }
}

/// The keystroke state machine of text expansion: it keeps the last few characters typed, finds a
/// keyword at the insertion point by the trigger and word rules, and says what to delete and type.
///
/// - Characters are Swift `Character`s. A dead key types nothing; the next key's composed
///   character is what counts. A combining mark merges with the character before it.
/// - Backspace removes the last character. Arrows, shortcuts, Escape, clicks and focus changes
///   clear the buffer, because the insertion point may have moved.
/// - With ``ExpansionOptions/expandsWithinWords`` false, a keyword counts only when the character
///   before it is not a letter or digit. The start of the buffer counts as a word start.
/// - The longest keyword that matches wins.
/// - After a match the buffer waits for the feature's answer. Characters typed meanwhile are
///   counted, so they are deleted and typed again after the expansion. Anything that may move the
///   insertion point cancels the wait, and the answer is then dropped.
nonisolated public struct TypingBuffer: Sendable {
    public private(set) var keywords: Set<String>
    public var options: ExpansionOptions
    /// The recent characters before the insertion point.
    public private(set) var text = ""
    private var byLastCharacter: [Character: [String]] = [:]
    private var capacity = 8
    private var pending: Pending?
    private var nextID = 0

    private struct Pending: Sendable {
        var match: KeywordMatch
        var typedAfter = ""
    }

    public init(keywords: Set<String>, options: ExpansionOptions = ExpansionOptions()) {
        self.keywords = []
        self.options = options
        update(keywords: keywords)
    }

    /// True while a match waits for ``finish(_:with:)``.
    public var isAwaiting: Bool {
        pending != nil
    }

    /// Replaces the keywords and keeps what was typed.
    public mutating func update(keywords: Set<String>) {
        self.keywords = keywords.filter { !$0.isEmpty }
        byLastCharacter = [:]
        for keyword in self.keywords {
            byLastCharacter[keyword.last!, default: []].append(keyword)
        }
        for key in byLastCharacter.keys {
            byLastCharacter[key]!.sort { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        }
        capacity = max(8, (self.keywords.map(\.count).max() ?? 0) + 2)
    }

    /// Forgets what was typed and drops a match that waits.
    public mutating func reset() {
        text = ""
        pending = nil
    }

    /// Feeds one event. Returns a match when the event completed a keyword.
    @discardableResult public mutating func handle(_ event: TypingEvent) -> KeywordMatch? {
        switch event {
        case .characters(let typed):
            for (offset, character) in typed.enumerated() {
                if pending != nil {
                    pending!.typedAfter.append(character)
                    continue
                }
                if let match = append(character) {
                    pending = Pending(match: match, typedAfter: String(typed.dropFirst(offset + 1)))
                    return match
                }
            }
            return nil
        case .backspace:
            if pending != nil {
                if pending!.typedAfter.isEmpty {
                    // The user deleted into the keyword: the match no longer stands.
                    reset()
                } else {
                    pending!.typedAfter.removeLast()
                }
            } else if !text.isEmpty {
                text.removeLast()
            }
            return nil
        case .forwardDelete, .modifiers:
            return nil
        case .navigation, .shortcut, .escape, .click, .focusChanged:
            reset()
            return nil
        }
    }

    /// Takes the feature's answer for a match and says what to type. Nil when nothing is typed:
    /// the answer was to ignore the keyword, or the match was cancelled or is stale.
    public mutating func finish(_ match: KeywordMatch, with result: ExpansionResult) -> ExpansionPlan? {
        guard let waiting = pending, waiting.match.id == match.id else { return nil }
        pending = nil
        let delimiter = match.delimiter.map(String.init) ?? ""
        let typedAfter = waiting.typedAfter
        switch result {
        case .ignore:
            // The keyword stays as typed, and typing goes on from there.
            text += typedAfter
            trim()
            return nil
        case .insert(let expansion):
            text = ""
            return ExpansionPlan(
                deleteCount: match.deleteCount + typedAfter.count, text: expansion.text + delimiter + typedAfter,
                leftCount: max(0, expansion.charactersAfterCursor) + delimiter.count + typedAfter.count)
        case .runCommand(let id, let arguments):
            text = ""
            return ExpansionPlan(
                deleteCount: match.deleteCount + typedAfter.count, text: delimiter + typedAfter,
                leftCount: delimiter.count + typedAfter.count, command: id, arguments: arguments)
        }
    }

    /// Appends one character and returns the match it completes, if any.
    private mutating func append(_ character: Character) -> KeywordMatch? {
        switch options.trigger {
        case .immediately:
            text.append(character)
            trim()
            return match(delimiter: nil)
        case .afterDelimiter:
            let isDelimiter = character.isWhitespace || character.isNewline || character.isPunctuation
            let found = isDelimiter ? match(delimiter: character) : nil
            text.append(character)
            trim()
            return found
        }
    }

    /// The longest keyword at the end of the buffer that starts where the word rule allows.
    private mutating func match(delimiter: Character?) -> KeywordMatch? {
        guard let last = text.last, let candidates = byLastCharacter[last] else { return nil }
        for keyword in candidates where text.hasSuffix(keyword) && startsWhereAllowed(keyword) {
            nextID += 1
            return KeywordMatch(id: nextID, keyword: keyword, delimiter: delimiter)
        }
        return nil
    }

    private func startsWhereAllowed(_ keyword: String) -> Bool {
        if options.expandsWithinWords { return true }
        guard let before = text.dropLast(keyword.count).last else { return true }
        return !(before.isLetter || before.isNumber)
    }

    private mutating func trim() {
        if text.count > capacity { text = String(text.suffix(capacity)) }
    }
}
