import Foundation
import Kit
import KitTesting
import Testing

@testable import Bookmarks

/// Timings at 50,000 bookmarks. Opt in with `BOOKMARKS_BENCHMARK=1`; run in a release build for
/// numbers worth quoting. Prints p50 and p99 with the sample count and the load average.
@MainActor
@Suite(
    "Benchmark", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["BOOKMARKS_BENCHMARK"] == "1"))
struct Benchmark {
    static let count = 50_000

    /// 50,000 links in 500 folders of 100, with titles and links of ordinary length.
    static func nodes() -> [FixtureNode] {
        (0..<500).map { folder in
            .folder(
                "Folder \(folder)",
                (0..<100).map { index in
                    let number = folder * 100 + index
                    return .link(
                        "Bookmark number \(number) about topic \(number % 97)",
                        "https://site\(number % 3_000).example.com/articles/\(number)?ref=list",
                        added: Date(timeIntervalSince1970: 1_600_000_000 + Double(number)))
                })
        }
    }

    static func measure(_ label: String, runs: Int, _ body: () throws -> Void) rethrows {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
        }
        report(label, samples)
    }

    static func report(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        print(
            String(
                format: "BENCH %@: n=%d p50=%.2f ms p99=%.2f ms max=%.2f ms load=%.1f", label, sorted.count, p50, p99,
                sorted.last ?? 0, load[0]))
    }

    @Test func parsingFiftyThousandBookmarks() throws {
        let nodes = Self.nodes()
        let chromium = BookmarkFixtures.chromium(bar: [], other: nodes)
        let safari = BookmarkFixtures.safari(favorites: [], menu: nodes)
        let firefox = BookmarkFixtures.firefox(menu: nodes)
        print(
            "BENCH sizes: chromium \(chromium.count) bytes, safari \(safari.count) bytes, firefox \(firefox.count) bytes"
        )
        #expect(try ChromiumBookmarks.parse(chromium).count == Self.count)
        #expect(try SafariBookmarks.parse(safari).count == Self.count)
        #expect(try FirefoxPlaces.parse(firefox).count == Self.count)
        try Self.measure("parse chromium 50k", runs: 15) { _ = try ChromiumBookmarks.parse(chromium) }
        try Self.measure("parse safari 50k", runs: 15) { _ = try SafariBookmarks.parse(safari) }
        try Self.measure("parse firefox 50k", runs: 15) { _ = try FirefoxPlaces.parse(firefox) }
        let parsed = try ChromiumBookmarks.parse(chromium)
        let profile = BrowserProfile(browser: .chrome, key: "Default", files: [])
        Self.measure("build rows 50k", runs: 15) {
            _ = BookmarkIndex.build([ProfileBookmarks(profile: profile, bookmarks: parsed)], includesReadingList: true)
        }
    }

    /// From asking the page for its rows to having them, with 50,000 loaded: what stands between
    /// opening Search Bookmarks and its first page, besides the host's own index.
    @Test func theFirstPageAtFiftyThousand() async throws {
        let data = BookmarkFixtures.chromium(bar: [], other: Self.nodes())
        let bookmarks = BookmarksHarness(files: { home in
            let files = IsolatedBookmarkFiles(home: home)
            files.set(.chrome, profile: "Default", contents: [data])
            return files
        })
        await bookmarks.harness.activate()
        let start = ContinuousClock.now
        try await bookmarks.choose(.chrome)
        print("BENCH first read and build of 50k, off the main thread: \(ContinuousClock.now - start)")
        #expect(bookmarks.feature.library.snapshot.rows.count == Self.count)

        let list = bookmarks.feature.list
        var samples: [Double] = []
        var filtered: [Double] = []
        for _ in 0..<200 {
            let started = ContinuousClock.now
            let result = try await list.load(ListRequest())
            let elapsed = ContinuousClock.now - started
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
            #expect(result.sections.first?.rows.count == Self.count)
            let again = ContinuousClock.now
            _ = try await list.load(ListRequest(filter: "profile:chrome/Default", reason: .filter))
            let filterElapsed = ContinuousClock.now - again
            filtered.append(
                Double(filterElapsed.components.attoseconds) / 1e15 + Double(filterElapsed.components.seconds) * 1_000)
        }
        Self.report("list load 50k, all", samples)
        Self.report("list load 50k, one profile", filtered)

        // What the main thread holds while the action panel opens.
        let row = try #require(bookmarks.feature.library.snapshot.rows.last)
        var actions: [Double] = []
        for _ in 0..<2_000 {
            let started = ContinuousClock.now
            _ = list.actions(for: row)
            let elapsed = ContinuousClock.now - started
            actions.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
        }
        Self.report("actions(for:) at 50k", actions)
    }
}
