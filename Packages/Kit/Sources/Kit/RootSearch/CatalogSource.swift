/// Rows that join root search's catalog, which the engine matches synchronously with apps and
/// commands, ranks with learning, and shows when they match. Use it for items people search for by
/// name, such as quicklinks with no arguments, bookmarks or system settings panes.
///
/// For rows that depend on the query, such as files or a calculation, use a ``LiveProvider``.
@MainActor public protocol CatalogSource: RowSource {
    /// The ``ItemID`` namespace of every row the source makes. Unique across features, except that
    /// one object may serve as several kinds of source under one namespace. Root uses it to find the
    /// source of a remembered row.
    var namespace: String { get }

    /// Every row. Called at launch and after each ``RowSource/changes`` signal or settings change,
    /// off the keystroke path. A row whose ``Row/expires`` has passed drops out without a reload.
    func rows() async throws -> [Row]
}
