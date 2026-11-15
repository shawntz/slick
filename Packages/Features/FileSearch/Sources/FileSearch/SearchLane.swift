import CoreBridge
import Foundation
import Kit
import Synchronization

/// One search request, made on the main actor and carried to the search queue as is.
nonisolated struct SearchRequest: Sendable {
    var query: String
    /// The most rows to build.
    var limit: Int
    /// Only rows of this kind, or every kind.
    var kind: FileKind?
    var includesHidden = false
    var patterns = NamePatterns([])
    var style: FileRows.Style
}

/// What one search found.
nonisolated struct SearchResult: Sendable {
    var rows: [Row]
    /// A folder query named a folder the index does not hold.
    var notIndexed = false
}

/// One search field: its own sessions and the serial queue they run on, at user-initiated
/// priority, so the Rust core's parallel parts run on the performance cores.
///
/// A session narrows as the query grows, so each field keeps its own: root search and the Search
/// Files page never share one. Each field has one session for name searches and one for folder
/// listings, because a listing returns many more rows than a search needs.
///
/// A request that a newer one overtook, or whose task was cancelled, is dropped before it starts.
/// A search that has started runs to its end, which takes about a millisecond.
nonisolated final class SearchLane: @unchecked Sendable {
    private let queue: DispatchQueue
    private let clock: any ClockService
    private let searchCapacity: Int
    private let browseCapacity: Int
    private let latest = Atomic<UInt64>(0)
    /// Touched only on `queue`.
    private var searchSession: FileSearchSession?
    /// Touched only on `queue`.
    private var browseSession: FileSearchSession?
    /// Touched only on `queue`.
    private var sessionHome: String?

    init(label: String, clock: any ClockService, searchCapacity: Int, browseCapacity: Int) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.clock = clock
        self.searchCapacity = searchCapacity
        self.browseCapacity = browseCapacity
    }

    /// True for a query that lists a folder.
    static func isBrowse(_ query: String) -> Bool {
        guard let first = query.utf8.first else { return false }
        return first == UInt8(ascii: "/") || first == UInt8(ascii: "~")
    }

    /// Searches `index` on the lane's queue and builds the rows there.
    func search(_ request: SearchRequest, in index: FileIndex) async throws -> SearchResult {
        try await run { [self] in try perform(request, in: index) }
    }

    /// Rows for remembered items that the index still holds, in the order given.
    func recents(_ paths: [String], in index: FileIndex, kind: FileKind?, style: FileRows.Style) async throws -> [Row] {
        try await run {
            let snapshot = try index.snapshot()
            var rows: [Row] = []
            for path in paths {
                guard let id = snapshot.lookup(path: path), let entry = snapshot.entry(id) else { continue }
                if let kind, FileKind.of(name: Paths.name(of: path), flags: entry.flags) != kind { continue }
                rows.append(
                    FileRows.row(path: path, flags: entry.flags, modified: entry.modified, highlights: [], style: style)
                )
            }
            return rows
        }
    }

    /// Drops the sessions, and with them the snapshots they hold, so the memory returns while the
    /// feature is off. The next search makes new ones.
    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                searchSession = nil
                browseSession = nil
                sessionHome = nil
                continuation.resume()
            }
        }
    }

    /// Runs `work` on the queue unless a newer request or a cancellation overtook it first.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let ticket = latest.add(1, ordering: .relaxed).newValue
        let cancelled = Atomic<Bool>(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async { [self] in
                    guard !cancelled.load(ordering: .relaxed), latest.load(ordering: .relaxed) == ticket else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
        }
    }

    /// Runs on the queue.
    private func perform(_ request: SearchRequest, in index: FileIndex) throws -> SearchResult {
        let browsing = Self.isBrowse(request.query)
        let session = try self.session(browsing: browsing)
        if sessionHome != request.style.home {
            searchSession?.setHome(request.style.home)
            browseSession?.setHome(request.style.home)
            sessionHome = request.style.home
        }
        let options = FileSearchOptions(
            now: UInt32(clamping: Int(clock.now.timeIntervalSince1970)), kinds: request.kind?.indexKinds ?? .all,
            includeHidden: request.includesHidden)
        let count = try session.search(request.query, in: index, options: options)
        var style = request.style
        style.absoluteCompletions = request.query.utf8.first == UInt8(ascii: "/")
        var rows: [Row] = []
        var ranges: [HighlightRange] = []
        var position = 0
        while position < count && rows.count < request.limit {
            let hit = session[position]
            position += 1
            guard let path = session.path(of: hit.id) else { continue }
            let name = Paths.name(of: path)
            if request.patterns.hides(name) { continue }
            if let kind = request.kind, FileKind.of(name: name, flags: hit.flags) != kind { continue }
            try session.highlightRanges(for: hit, into: &ranges)
            let highlights = ranges.map { $0.location..<($0.location + $0.length) }
            rows.append(
                FileRows.row(
                    path: path, flags: hit.flags, modified: session.entry(hit.id)?.modified, highlights: highlights,
                    style: style))
        }
        return SearchResult(rows: rows, notIndexed: browsing && session.stats.notIndexed)
    }

    /// Runs on the queue. Sessions are made on first use, so a field nobody types in costs nothing.
    private func session(browsing: Bool) throws -> FileSearchSession {
        if browsing {
            if let browseSession { return browseSession }
            let made = try FileSearchSession(capacity: browseCapacity)
            if let sessionHome { made.setHome(sessionHome) }
            browseSession = made
            return made
        }
        if let searchSession { return searchSession }
        let made = try FileSearchSession(capacity: searchCapacity)
        if let sessionHome { made.setHome(sessionHome) }
        searchSession = made
        return made
    }
}
