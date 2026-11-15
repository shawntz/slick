import Foundation
import Kit
import KitTesting

@testable import Bookmarks

/// A harness over the isolated file service, with the browsers' apps installed in the fake
/// workspace so "found" and "Open in" work.
@MainActor
struct BookmarksHarness {
    let harness: FeatureHarness<BookmarksFeature>
    let files: IsolatedBookmarkFiles

    init(
        files make: (URL) -> IsolatedBookmarkFiles = { IsolatedBookmarkFiles(home: $0) },
        installed: [Browser] = Browser.allCases, permissions: PermissionStatus = .granted
    ) {
        let fakes = FakeServices(permissions: permissions)
        let files = make(fakes.storage.homeDirectory)
        fakes.override(BookmarkFileServiceKey.self, with: files)
        fakes.workspace.installed = installed.map { AppInfo(bundleID: $0.bundleID, name: $0.name) }
        harness = FeatureHarness(BookmarksFeature.self, fakes: fakes)
        self.files = files
    }

    var fakes: FakeServices { harness.fakes }
    var feature: BookmarksFeature { harness.feature }

    /// Switches browsers on as the settings window would, and waits until they are read.
    func choose(_ browsers: Browser...) async throws {
        for browser in browsers { harness.context.settings[BookmarkSettings.includes(browser)] = true }
        try await harness.settle()
        await feature.library.ready()
    }

    /// Opens Search Bookmarks.
    func open() async throws {
        try await harness.run("search")
    }

    /// The path of a profile's main file, for simulated file changes.
    func file(_ browser: Browser, profile: String = "") -> URL {
        let folder = files.watchFolder(for: browser)
        let base = profile.isEmpty ? folder : folder.appending(path: profile)
        switch browser.format {
        case .safariPropertyList: return base.appending(path: "Bookmarks.plist")
        case .chromiumJSON: return base.appending(path: "Bookmarks")
        case .firefoxPlaces: return base.appending(path: "places.sqlite")
        }
    }
}

/// Small synthetic files used across the tests. Every link uses a reserved example domain.
nonisolated enum Samples {
    static let chromeDefault = BookmarkFixtures.chromium(
        bar: [
            .link("Team Wiki", "https://wiki.example.org/", guid: "guid-wiki"),
            .folder("Work", [.link("Release Checklist", "https://wiki.example.org/release", guid: "guid-release")]),
        ],
        other: [.link("Example Domain", "https://example.com/", guid: "guid-example")])

    static let chromeSecond = BookmarkFixtures.chromium(
        bar: [.link("Garden Planner", "https://garden.example.net/", guid: "guid-garden")],
        other: [.link("Example Domain", "https://example.com/", guid: "guid-example-2")])

    static let safari = BookmarkFixtures.safari(
        favorites: [.link("Project Board", "https://board.example.org/projects", guid: "safari-board")],
        menu: [.folder("Recipes", [.link("Rye Bread", "https://recipes.example.net/bread", guid: "safari-bread")])],
        readingList: [.link("A Long Read", "https://news.example.com/maps", guid: "safari-read")])

    static let firefox = BookmarkFixtures.firefox(
        menu: [.link("Library Catalog", "https://library.example.org/", guid: "ff-library")],
        toolbar: [.link("Status Page", "https://status.example.com/", guid: "ff-status")])

    /// A Chromium file whose bar holds the given links, one per pair of title and link.
    static func chromium(_ links: [(String?, String)]) -> Data {
        BookmarkFixtures.chromium(bar: links.map { FixtureNode.link($0.0, $0.1) })
    }

    /// A temporary folder removed by the caller.
    static func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "bookmarks-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

extension PageState {
    /// The form on this page, if it is one.
    var form: FormPage? {
        if case .form(let form) = page { return form }
        return nil
    }

    /// The list on this page, if it is one.
    var listPage: ListPage? {
        if case .list(let list) = page { return list }
        return nil
    }
}
