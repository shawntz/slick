import Foundation
import Synchronization

/// The file service in scenarios, self-tests, benchmarks and tests: synthetic bookmarks held in
/// memory. Its paths sit under the run's synthetic home folder and are never opened.
nonisolated final class IsolatedBookmarkFiles: BookmarkFileService {
    private struct State {
        var profiles: [Browser: [BrowserProfile]] = [:]
        var contents: [String: [Data]] = [:]
        var failures: [String: BookmarkReadError] = [:]
        var versions: [String: Int] = [:]
        var reads: [String] = []
        var listed: [Browser] = []
    }

    private let home: URL
    private let state = Mutex(State())

    init(home: URL) {
        self.home = home
    }

    func watchFolder(for browser: Browser) -> URL {
        home.appending(path: browser.dataFolder, directoryHint: .isDirectory)
    }

    @concurrent func profiles(of browser: Browser) async -> [BrowserProfile] {
        state.withLock { state in
            state.listed.append(browser)
            return state.profiles[browser] ?? []
        }
    }

    @concurrent func contents(of profile: BrowserProfile) async throws(BookmarkReadError) -> [Data] {
        let result: Result<[Data], BookmarkReadError> = state.withLock { state in
            state.reads.append(profile.id)
            if let failure = state.failures[profile.id] { return .failure(failure) }
            return .success(state.contents[profile.id] ?? [])
        }
        return try result.get()
    }

    @concurrent func stamp(of profile: BrowserProfile) async -> FileStamp {
        let version = state.withLock { $0.versions[profile.id] ?? 0 }
        return FileStamp(parts: [FileStamp.Part(name: profile.id, modified: Double(version), size: 0)])
    }

    // MARK: - Setting it up

    /// Adds or replaces a profile with the bytes of its files, as if the browser wrote them. The
    /// file under the profile folder changes, so a watcher of ``watchFolder(for:)`` hears of it.
    @discardableResult
    func set(_ browser: Browser, profile key: String = "", contents: [Data]) -> BrowserProfile {
        let folder = key.isEmpty ? watchFolder(for: browser) : watchFolder(for: browser).appending(path: key)
        let name: String =
            switch browser.format {
            case .safariPropertyList: BrowserFolders.safariFile
            case .chromiumJSON: "Bookmarks"
            case .firefoxPlaces: BrowserFolders.firefoxFile
            }
        let profile = BrowserProfile(browser: browser, key: key, files: [folder.appending(path: name)])
        state.withLock { state in
            var list = state.profiles[browser] ?? []
            list.removeAll { $0.id == profile.id }
            list.append(profile)
            state.profiles[browser] = list.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            state.contents[profile.id] = contents
            state.failures[profile.id] = nil
            state.versions[profile.id, default: 0] += 1
        }
        return profile
    }

    /// Makes reading the profile fail from now on.
    func fail(_ profile: BrowserProfile, with error: BookmarkReadError) {
        state.withLock { state in
            state.failures[profile.id] = error
            state.versions[profile.id, default: 0] += 1
        }
    }

    /// Removes a profile, as if the user deleted it in the browser.
    func remove(_ profile: BrowserProfile) {
        state.withLock { state in
            state.profiles[profile.browser]?.removeAll { $0.id == profile.id }
            state.contents[profile.id] = nil
        }
    }

    /// The profile IDs read so far, in order.
    var reads: [String] { state.withLock(\.reads) }

    /// The browsers whose profiles were asked for, in order.
    var listed: [Browser] { state.withLock(\.listed) }

    // MARK: - The sample

    /// Safari with its Reading List, Chrome with two profiles and Firefox with one, for scenarios.
    /// Every link points at a reserved example domain.
    static func sample(home: URL) -> IsolatedBookmarkFiles {
        let files = IsolatedBookmarkFiles(home: home)
        files.set(
            .safari,
            contents: [
                BookmarkFixtures.safari(
                    favorites: [
                        .link("Example Domain", "https://example.com/"),
                        .link("Project Board", "https://board.example.org/projects"),
                    ],
                    menu: [
                        .folder(
                            "Recipes",
                            [
                                .link("Weeknight Soup", "https://recipes.example.net/soup"),
                                .link("Rye Bread", "https://recipes.example.net/bread"),
                            ])
                    ],
                    readingList: [.link("A Long Read About Maps", "https://news.example.com/maps")])
            ])
        files.set(
            .chrome, profile: "Default",
            contents: [
                BookmarkFixtures.chromium(
                    bar: [
                        .link("Team Wiki", "https://wiki.example.org/"),
                        .folder("Work", [.link("Release Checklist", "https://wiki.example.org/release")]),
                    ],
                    other: [.link("Example Domain", "https://example.com/")])
            ])
        files.set(
            .chrome, profile: "Profile 1",
            contents: [BookmarkFixtures.chromium(bar: [.link("Garden Planner", "https://garden.example.net/")])])
        files.set(
            .firefox, profile: "a1b2c3d4.default-release",
            contents: [
                BookmarkFixtures.firefox(
                    menu: [.link("Library Catalog", "https://library.example.org/")],
                    toolbar: [.link("Status Page", "https://status.example.com/")],
                    tags: [(tag: "reading", url: "https://library.example.org/")])
            ])
        return files
    }
}
