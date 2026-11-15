import Foundation
import Kit

/// What one load covers.
nonisolated struct LoadRequest: Hashable, Sendable {
    /// The browsers to read, in order. Safari is here only while the feature holds Full Disk Access.
    var browsers: [Browser]
    var includesReadingList: Bool
    /// True reads every file again, changed or not.
    var force = false
}

/// A profile that could not be read.
nonisolated struct SourceProblem: Hashable, Sendable {
    var browser: Browser
    var profileName: String
    var showsProfile: Bool
    var error: BookmarkReadError
}

/// What a load found.
nonisolated struct LoadResult: Sendable {
    /// Nil when nothing changed since the last load.
    var snapshot: BookmarkSnapshot?
    var problems: [SourceProblem]
    /// A Firefox profile changed too soon after its last read: load again after this delay.
    var retryAfter: Duration?
}

/// Reads and parses bookmark files off the main thread, and keeps what it found per profile, so a
/// load reads only the files whose stamp changed.
actor BookmarkLoader {
    /// Firefox writes its database each time a page is visited. Reading it at most this often keeps
    /// a busy browsing session from costing much.
    static let firefoxInterval: Duration = .seconds(10)

    private struct Loaded {
        var profile: BrowserProfile
        var stamp: FileStamp
        var bookmarks: [ParsedBookmark]
        var problem: BookmarkReadError?
        var readAt: Date
    }

    private let files: any BookmarkFileService
    private let clock: any ClockService
    private var loaded: [String: Loaded] = [:]
    private var lastRequest: LoadRequest?

    init(files: any BookmarkFileService, clock: any ClockService) {
        self.files = files
        self.clock = clock
    }

    /// Reads what changed for the request and builds a new snapshot. Returns nil when cancelled.
    func load(_ request: LoadRequest) async -> LoadResult? {
        var changed =
            request.force
            || lastRequest
                != LoadRequest(
                    browsers: request.browsers, includesReadingList: request.includesReadingList)
        var retryAfter: Duration?
        var present = Set<String>()
        for browser in request.browsers {
            for profile in await files.profiles(of: browser) {
                if Task.isCancelled { return nil }
                present.insert(profile.id)
                let stamp = await files.stamp(of: profile)
                let previous = loaded[profile.id]
                if !request.force, let previous, previous.stamp == stamp, previous.profile == profile { continue }
                if !request.force, let previous, profile.browser.format == .firefoxPlaces,
                    let wait = Self.firefoxWait(since: previous.readAt, now: clock.now)
                {
                    retryAfter = min(retryAfter ?? wait, wait)
                    continue
                }
                let fresh = await read(profile, stamp: stamp, previous: previous)
                // Firefox rewrites its database for every page visited; most reads find the same
                // bookmarks, and then nothing is rebuilt or announced.
                if fresh.bookmarks != previous?.bookmarks || fresh.problem != previous?.problem
                    || fresh.profile != previous?.profile
                {
                    changed = true
                }
                loaded[profile.id] = fresh
            }
        }
        for id in loaded.keys where !present.contains(id) {
            loaded[id] = nil
            changed = true
        }
        if Task.isCancelled { return nil }
        lastRequest = LoadRequest(browsers: request.browsers, includesReadingList: request.includesReadingList)
        let entries = loaded.values.sorted { $0.profile.id < $1.profile.id }
        let counts = Dictionary(grouping: entries, by: \.profile.browser).mapValues(\.count)
        let problems = entries.compactMap { entry in
            entry.problem.map {
                SourceProblem(
                    browser: entry.profile.browser, profileName: entry.profile.name,
                    showsProfile: (counts[entry.profile.browser] ?? 0) > 1, error: $0)
            }
        }
        let snapshot =
            changed
            ? BookmarkIndex.build(
                entries.map { ProfileBookmarks(profile: $0.profile, bookmarks: $0.bookmarks) },
                includesReadingList: request.includesReadingList) : nil
        return LoadResult(snapshot: snapshot, problems: problems, retryAfter: retryAfter)
    }

    /// How long to wait before reading a Firefox profile read at `readAt`, or nil to read it now.
    /// A clock set back puts the last read in the future. Waiting for the clock to catch up could
    /// take days, so such a read counts as old.
    nonisolated static func firefoxWait(since readAt: Date, now: Date) -> Duration? {
        let elapsed = now.timeIntervalSince(readAt)
        guard elapsed >= 0 else { return nil }
        let wait = firefoxInterval - .seconds(elapsed)
        return wait > .zero ? wait : nil
    }

    /// Forgets everything, as when the feature is turned off.
    func reset() {
        loaded = [:]
        lastRequest = nil
    }

    /// Reads and parses one profile. A file that fails keeps the bookmarks of the last good read,
    /// with the problem noted, so a file caught mid-write does not empty the list.
    private func read(_ profile: BrowserProfile, stamp: FileStamp, previous: Loaded?) async -> Loaded {
        let now = clock.now
        do {
            let contents = try await files.contents(of: profile)
            var bookmarks: [ParsedBookmark] = []
            var problem: BookmarkReadError?
            for data in contents {
                do {
                    bookmarks += try Self.parse(data, format: profile.browser.format)
                } catch {
                    problem = problem ?? error
                }
            }
            if problem != nil, bookmarks.isEmpty, let previous { bookmarks = previous.bookmarks }
            return Loaded(profile: profile, stamp: stamp, bookmarks: bookmarks, problem: problem, readAt: now)
        } catch {
            return Loaded(
                profile: profile, stamp: stamp, bookmarks: previous?.bookmarks ?? [], problem: error, readAt: now)
        }
    }

    /// Parses one file in its browser's format.
    nonisolated static func parse(_ data: Data, format: Browser.Format) throws(BookmarkReadError) -> [ParsedBookmark] {
        switch format {
        case .safariPropertyList: try SafariBookmarks.parse(data)
        case .chromiumJSON: try ChromiumBookmarks.parse(data)
        case .firefoxPlaces: try FirefoxPlaces.parse(data)
        }
    }
}
