/// A root search input that answers as the user types, either instantly or asynchronously.
public enum LiveProvider: Sendable {
    case instant(any InstantProvider)
    case async(any AsyncProvider)

    /// The ``ItemID`` namespace of the provider's rows.
    @MainActor public var namespace: String {
        switch self {
        case .instant(let provider): provider.namespace
        case .async(let provider): provider.namespace
        }
    }

    /// The provider as a source of row actions.
    @MainActor public var actionProvider: any RowActionProvider {
        switch self {
        case .instant(let provider): provider
        case .async(let provider): provider
        }
    }
}

/// Answers synchronously on the main thread, inside the keystroke, such as a calculator.
///
/// Budget: **100 microseconds** per call, measured at efficiency-core speed, every keystroke. That
/// rules out I/O, locks that may wait, and large allocations. Return nil fast when the query is not
/// for you (check the first character before parsing). Bench it with the other budget tests.
@MainActor public protocol InstantProvider: RowActionProvider {
    /// The ``ItemID`` namespace of the provider's rows.
    var namespace: String { get }

    /// The answer for the query, or nil. Called on every keystroke with the full query.
    func answer(for query: String) -> InstantAnswer?

    /// Fires when an answer the provider gave may be different now for the same query, such as a
    /// conversion that showed a loading row until exchange rates arrived. Send it from any thread.
    /// Default nil.
    ///
    /// Root search then calls ``answer(for:)`` again for the query on screen, on the main thread,
    /// and puts the new rows where the provider's old rows were: nothing above them moves. An
    /// answer that is new for this query joins as the provider's own section after the results. A
    /// nil answer takes the old rows away. Send it after the data changed, not on a timer.
    var answersChanged: ChangeSignal? { get }
}

extension InstantProvider {
    public var answersChanged: ChangeSignal? { nil }
}

/// An instant provider's answer.
public struct InstantAnswer: Sendable {
    public var rows: [Row]
    /// True puts the rows above every other result, as a calculator does for a calculation. Otherwise
    /// they appear in their own section after the engine's results.
    public var claimsTop: Bool
    /// The heading when the rows do not claim the top.
    public var sectionTitle: String?

    public init(rows: [Row], claimsTop: Bool = false, sectionTitle: String? = nil) {
        self.rows = rows
        self.claimsTop = claimsTop
        self.sectionTitle = sectionTitle
    }
}

/// Answers asynchronously in its own section of root search, such as files.
///
/// Root waits ``debounce(for:)`` after the last keystroke, then calls ``results(for:)`` in a task
/// that it cancels as soon as the query changes, so check `Task.isCancelled` or call
/// `try Task.checkCancellation()` between steps. Results only ever fill the provider's own section;
/// they never reorder what the user is looking at. Give rows ``Row/titleHighlights`` so matches are
/// drawn.
@MainActor public protocol AsyncProvider: RowActionProvider {
    /// The ``ItemID`` namespace of the provider's rows.
    var namespace: String { get }
    /// The section heading, such as "Files".
    var sectionTitle: String { get }
    /// How long the query must be still before ``results(for:)`` runs, unless
    /// ``debounce(for:)`` says otherwise. Default 60 ms.
    var debounce: Duration { get }
    /// Shorter queries are not sent, unless ``takesOver(_:)`` claims them. Default 2.
    var minimumQueryLength: Int { get }
    /// The most rows root shows in the section. Default 5.
    var maximumRows: Int { get }

    /// True when the query belongs to this provider alone, such as a path starting with "/" or "~".
    /// Root then shows only this provider's rows, without a limit. Must be as cheap as an instant
    /// provider. Default false.
    func takesOver(_ query: String) -> Bool

    /// The heading for one query, such as the folder being listed. Must be as cheap as
    /// ``takesOver(_:)``. Default ``sectionTitle``.
    func sectionTitle(for query: String) -> String

    /// The wait for one query, such as none for a folder listing that is instant. Default
    /// ``debounce``.
    func debounce(for query: String) -> Duration

    /// The rows for the query, best first.
    func results(for query: String) async throws -> [Row]
}

extension AsyncProvider {
    public func sectionTitle(for query: String) -> String { sectionTitle }
    public func debounce(for query: String) -> Duration { debounce }
    public var debounce: Duration { .milliseconds(60) }
    public var minimumQueryLength: Int { 2 }
    public var maximumRows: Int { 5 }
    public func takesOver(_ query: String) -> Bool { false }
}
