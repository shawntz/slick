import Foundation
import Kit

/// Root search as the panel drives it.
///
/// Root implements it. Host drives it and never imports Root. One typing session runs from
/// ``begin()`` to ``end()``:
///
/// 1. The panel is about to show root search: Host calls ``begin()`` and draws what it returns.
/// 2. Each keystroke: Host calls ``update(query:)`` inside the keystroke and draws the result.
/// 3. When ``changes`` fires, Host reads ``snapshot`` and draws it. Async sections only append to
///    their own sections, so the rows the user is looking at never move.
/// 4. Root search leaves the screen, because the panel closed or a page was pushed: Host calls
///    ``end()``.
///
/// Rules for the host:
///
/// - ``RowActionProvider/actions(for:)`` returns no actions for a command row. The host runs
///   commands itself, through its own pipeline, and builds the command row's actions: Run, then
///   ``Command/rowActions``, then its own entries such as alias and hotkey.
/// - The host picks the launch source from the section a row was run from, with
///   ``RootSection/Kind/launchSource``: a suggested row runs with ``LaunchSource/suggestion``, a
///   fallback with ``LaunchSource/fallback`` and every other row with ``LaunchSource/root``.
/// - The host calls ``didRun(_:launch:)`` when the user runs a row, before ``end()``, so Root knows
///   the query the row was picked for.
@MainActor public protocol RootSource: RowActionProvider {
    /// Starts a typing session and returns the empty-query snapshot.
    ///
    /// It runs on the summon path: no I/O, no learning, nothing slow. Root prepares the empty-query
    /// snapshot earlier, when the context changed or the panel was last dismissed, and hands it back
    /// here.
    func begin() -> RootSnapshot

    /// The results for the full query, computed synchronously inside the keystroke on the main
    /// thread. It fills ``Row/titleHighlights`` for at least the first 12 rows, starts async
    /// providers, and cancels those still running for an older query.
    func update(query: String) -> RootSnapshot

    /// What ``update(query:)`` or ``begin()`` returned last, plus the sections that filled in since.
    var snapshot: RootSnapshot { get }

    /// Sent when ``snapshot`` changed without a keystroke: an async section filled in, suggestions
    /// changed, a live subtitle refreshed or the catalog changed.
    var changes: ChangeSignal { get }

    /// Root search left the screen. Cancels async providers and live subtitles. Calling it outside
    /// a session does nothing.
    func end()

    /// The matched ranges of a row's title for the current query, in UTF-16 offsets. The host asks
    /// for rows past those ``update(query:)`` filled as they scroll into view.
    func titleHighlights(for row: Row) -> [Range<Int>]

    /// The manifest ID of the feature a row came from, so the host can build the row's
    /// ``ActionContext`` from that feature's ``FeatureEntry/context``. Nil for rows Root makes
    /// itself, such as apps.
    func featureID(for row: Row) -> String?

    /// The row for an item that may not be on screen, such as the target of a hotkey or a deep
    /// link. Built from the catalog or from what Root remembered. Nil when Root does not know it.
    func row(for id: ItemID) -> Row?

    /// The user ran a row. Root records it for learning and usage as the row's ``Row/memory``
    /// allows, with the query of the current session when there is one.
    func didRun(_ row: Row, launch: LaunchSource)

    /// Forgets what was learned about one item, for "Reset Ranking": its query affinity, its use
    /// counts and its remembered row.
    func forget(_ id: ItemID)
}

/// What root search shows for one query.
public struct RootSnapshot: Sendable {
    /// The query these results are for. Empty for the empty state.
    public var query: String
    /// The sections in display order. Empty sections are left out.
    public var sections: [RootSection]
    /// What Tab completes to, drawn as ghost text after the query.
    public var completion: RootCompletion?
    /// True while an async provider is still working on this query.
    public var isLoading: Bool
    /// What the panel shows when there are no rows. Nil shows nothing.
    public var emptyState: EmptyState?
    /// Grows with every change, so a host can skip drawing a snapshot it already drew.
    public var revision: Int
    /// The command Tab runs with the typed text when neither the selected row nor the ghost text
    /// completes anything. Root fills it only with the command the user chose in
    /// ``HostSettings/tabCommand`` while that command is on and declares
    /// ``Command/takesRootQueryOnTab``. Nil runs nothing.
    public var tabCommand: ItemID?

    public init(
        query: String = "",
        sections: [RootSection] = [],
        completion: RootCompletion? = nil,
        isLoading: Bool = false,
        emptyState: EmptyState? = nil,
        revision: Int = 0,
        tabCommand: ItemID? = nil
    ) {
        self.query = query
        self.sections = sections
        self.completion = completion
        self.isLoading = isLoading
        self.emptyState = emptyState
        self.revision = revision
        self.tabCommand = tabCommand
    }

    /// Every row in display order.
    public var rows: [Row] {
        sections.flatMap(\.rows)
    }

    /// The section that holds a row, by the row's ID. The first one when a row appears twice.
    public func section(containing id: ItemID) -> RootSection? {
        sections.first { section in section.rows.contains { $0.id == id } }
    }
}

/// A titled group of rows in root search.
public struct RootSection: Identifiable, Hashable, Sendable {
    /// What a section holds, which sets the launch source of its rows.
    public enum Kind: Hashable, Sendable {
        /// Predicted items and situational suggestions, in the empty state.
        case suggested
        /// The user's favorites, in the empty state.
        case favorites
        /// Instant answers that claim the top, such as a calculation.
        case answers
        /// The engine's ranked results: apps, commands, catalog rows and remembered items.
        case results
        /// One live provider's own section: an async provider, or an instant one that does not
        /// claim the top.
        case provider(namespace: String)
        /// Commands that take the typed text, such as web search.
        case fallbacks

        /// The launch source a row run from this section gets.
        public var launchSource: LaunchSource {
            switch self {
            case .suggested: .suggestion
            case .fallbacks: .fallback
            case .favorites, .answers, .results, .provider: .root
            }
        }
    }

    /// Stable while the section shows, so the host keeps the selection when rows append.
    public var id: String
    /// The heading. Nil draws the rows without one.
    public var title: String?
    public var rows: [Row]
    public var kind: Kind

    public init(id: String, title: String?, rows: [Row], kind: Kind) {
        self.id = id
        self.title = title
        self.rows = rows
        self.kind = kind
    }
}

/// What Tab completes the query to, such as `saf` to `Safari`.
public struct RootCompletion: Hashable, Sendable {
    /// The item the completion leads to.
    public var id: ItemID
    /// The full text the query becomes, in the user's typed case for the part they typed.
    public var text: String

    public init(id: ItemID, text: String) {
        self.id = id
        self.text = text
    }

    /// The part of ``text`` after `query`, which the field draws as ghost text. Nil when the text
    /// does not start with the query, ignoring case, or adds nothing.
    public func ghostText(after query: String) -> String? {
        guard text.count > query.count,
            text.prefix(query.count).compare(query, options: [.caseInsensitive]) == .orderedSame
        else { return nil }
        return String(text.dropFirst(query.count))
    }
}
