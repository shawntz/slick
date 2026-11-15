import Foundation
import Kit

/// Everything a template may read while it renders. The clipboard, selection and snippet closures
/// run only when the template contains the matching placeholder.
public struct TemplateEnvironment: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale
    /// Argument values by ``TemplateArgument/key``.
    public var arguments: [String: String]
    /// Text copied `offset` entries ago, 0 being the current clipboard.
    public var clipboard: @Sendable (_ offset: Int) async -> String?
    /// The frontmost app's selected text.
    public var selection: @Sendable () async -> String?
    /// Another snippet's template source by name.
    public var snippet: @Sendable (_ name: String) async -> String?
    public var makeUUID: @Sendable () -> UUID

    public init(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        arguments: [String: String] = [:],
        clipboard: @escaping @Sendable (_ offset: Int) async -> String? = { _ in nil },
        selection: @escaping @Sendable () async -> String? = { nil },
        snippet: @escaping @Sendable (_ name: String) async -> String? = { _ in nil },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.arguments = arguments
        self.clipboard = clipboard
        self.selection = selection
        self.snippet = snippet
        self.makeUUID = makeUUID
    }

    /// An environment over a feature's services: its clock, the pasteboard's recent text (from the
    /// clipboard history when one is on) and the selection service.
    public init(
        context: FeatureContext,
        arguments: [String: String] = [:],
        snippet: @escaping @Sendable (_ name: String) async -> String? = { _ in nil }
    ) {
        let clock = context.clock
        let pasteboard = context.pasteboard
        let selection = context.selection
        self.init(
            now: clock.now, timeZone: clock.timeZone, locale: clock.locale, arguments: arguments,
            clipboard: { await pasteboard.recentText(offset: $0) },
            selection: { await selection.currentSelection()?.text },
            snippet: snippet)
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }
}

/// How rendered values are formatted by default, before `raw` turns it off for one placeholder.
public enum TemplateStyle: Hashable, Sendable {
    /// Values are inserted as they are. For snippets. `{cursor}` sets the insertion point.
    case plain
    /// Every value is percent-encoded unless it already is. For quicklinks.
    case url
    /// Clipboard, selection, argument and snippet values are wrapped in `"""` so a model can tell them
    /// from the instructions. For AI prompts.
    case prompt
}

/// A rendered template.
public struct RenderedTemplate: Hashable, Sendable {
    public var text: String
    /// Characters before the `{cursor}` mark, when the template had one and the style is plain.
    public var cursorOffset: Int?

    public init(text: String, cursorOffset: Int? = nil) {
        self.text = text
        self.cursorOffset = cursorOffset
    }

    /// Characters (grapheme clusters) after the cursor, for ``Expansion/charactersAfterCursor``.
    public var charactersAfterCursor: Int {
        cursorOffset.map { text.count - $0 } ?? 0
    }

    /// The rendered text as a text expansion.
    public var expansion: Expansion {
        Expansion(text, charactersAfterCursor: charactersAfterCursor)
    }
}
