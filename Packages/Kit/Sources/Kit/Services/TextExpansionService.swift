/// Watches what the user types in any app and replaces keywords with text, for snippets.
///
/// The service owns the keyboard tap and the typing; the feature owns the keywords and decides what
/// each one becomes, at the moment it is typed, so placeholders such as `{date}` are fresh. Calls are
/// applied in the order they are made, so the last ``start(keywords:options:expand:)`` or
/// ``stop()`` wins even when they overlap.
public protocol TextExpansionService: Sendable {
    /// Starts watching for the keywords. Never prompts: when ``Permission/inputMonitoring`` or
    /// ``Permission/accessibility`` is missing it returns ``TextExpansionStatus/needsPermission(_:)``
    /// and does nothing. Calling it again replaces the keywords, options and handler.
    ///
    /// `expand` runs when a keyword is typed and says what happens to it.
    func start(
        keywords: Set<String>,
        options: ExpansionOptions,
        expand: @escaping @Sendable (String) async -> ExpansionResult
    ) async -> TextExpansionStatus

    /// Replaces the keywords without restarting.
    func updateKeywords(_ keywords: Set<String>) async

    /// Stops watching.
    func stop() async

    func status() async -> TextExpansionStatus

    /// The status each time it changes from now on: a start or stop, a permission granted or taken
    /// away, secure input beginning or ending. It ends when the consuming task is cancelled.
    func statusChanges() -> AsyncStream<TextExpansionStatus>
}

/// What happens to a keyword the user typed.
public enum ExpansionResult: Hashable, Sendable {
    /// The keyword is replaced with the text.
    case insert(Expansion)
    /// The keyword stays as typed.
    case ignore
    /// The keyword is deleted and the panel opens on the command, launched as
    /// ``LaunchSource/textExpansion`` with these arguments, so it can ask for values in a form. A
    /// paste from there goes back to the same app. For a snippet with `{argument}` placeholders.
    case runCommand(ItemID, arguments: [String: String] = [:])
}

/// When and where keywords expand.
public struct ExpansionOptions: Hashable, Sendable {
    public enum Trigger: Hashable, Sendable {
        /// As soon as the last character of the keyword is typed.
        case immediately
        /// After the next space, tab, return or punctuation mark, which is kept.
        case afterDelimiter
    }

    public var trigger: Trigger
    /// When false, a keyword expands only at the start of a word.
    public var expandsWithinWords: Bool
    /// Apps where nothing expands, by bundle ID, such as password managers.
    public var excludedBundleIDs: Set<String>

    public init(trigger: Trigger = .immediately, expandsWithinWords: Bool = false, excludedBundleIDs: Set<String> = [])
    {
        self.trigger = trigger
        self.expandsWithinWords = expandsWithinWords
        self.excludedBundleIDs = excludedBundleIDs
    }
}

/// Text to insert, with where the insertion point goes afterwards.
public struct Expansion: Hashable, Sendable {
    public var text: String
    /// How many characters, counted as Swift `Character`s (grapheme clusters), to leave after the
    /// insertion point: one Left-arrow press each. Zero leaves it at the end.
    public var charactersAfterCursor: Int

    public init(_ text: String, charactersAfterCursor: Int = 0) {
        self.text = text
        self.charactersAfterCursor = charactersAfterCursor
    }
}

/// Whether text expansion is running.
public enum TextExpansionStatus: Hashable, Sendable {
    case running
    case stopped
    /// The service did not start because the permission is missing.
    case needsPermission(Permission)
    /// Running, but another app holds secure input, so keystrokes are hidden. Carries that app's name
    /// when known.
    case blockedBySecureInput(owner: String?)
}
