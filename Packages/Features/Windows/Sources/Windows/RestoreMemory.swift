/// The frame each window had before the feature moved it, for Restore.
///
/// A window that the user moves by hand after a command starts over: its next command records the
/// frame the user chose, so Restore returns to the user's own placement and never to a frame the
/// feature picked. The memory holds the most recent windows only.
nonisolated struct RestoreMemory: Hashable, Sendable {
    private struct Entry: Hashable, Sendable {
        var original: Frame
        /// Where the feature last put the window.
        var placed: Frame
        /// Larger is more recent.
        var use: Int
    }

    /// How many windows it remembers. The least recently moved is forgotten first.
    static let capacity = 64

    private var entries: [String: Entry] = [:]
    private var uses = 0

    /// The frame Restore returns each window to, by window key.
    var frames: [String: Frame] { entries.mapValues(\.original) }

    var count: Int { entries.count }

    /// Notes a move. The first move of a window, or the first since the user moved it, records where
    /// it was.
    mutating func record(_ moved: Moved) {
        uses += 1
        if var entry = entries[moved.window], entry.placed.isClose(to: moved.before) {
            entry.placed = moved.after
            entry.use = uses
            entries[moved.window] = entry
        } else {
            entries[moved.window] = Entry(original: moved.before, placed: moved.after, use: uses)
        }
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.use < $1.value.use })?.key {
            entries[oldest] = nil
        }
    }

    /// Forgets a window, after it was restored.
    mutating func forget(_ window: String) {
        entries[window] = nil
    }
}
