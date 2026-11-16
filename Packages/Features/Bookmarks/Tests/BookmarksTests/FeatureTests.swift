import Foundation
import Kit
import KitTesting
import Testing

@testable import Bookmarks

@MainActor
@Suite("Choosing browsers and privacy", .timeLimit(.minutes(1)))
struct ChoosingTests {
    static func sampleFiles(_ home: URL) -> IsolatedBookmarkFiles {
        let files = IsolatedBookmarkFiles(home: home)
        files.set(.chrome, profile: "Default", contents: [Samples.chromeDefault])
        files.set(.chrome, profile: "Profile 1", contents: [Samples.chromeSecond])
        files.set(.safari, contents: [Samples.safari])
        files.set(.firefox, profile: "ab12cd34.default-release", contents: [Samples.firefox])
        return files
    }

    @Test func declaresWhatItNeedsAndStartsWithEverythingOff() {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles)
        #expect(bookmarks.harness.issues.isEmpty)
        #expect(bookmarks.harness.pendingIssues.isEmpty)
        let manifest = BookmarksFeature.manifest
        #expect(manifest.id == "bookmarks")
        #expect(manifest.permissions.map(\.permission) == [.fullDiskAccess])
        #expect(manifest.permissions.allSatisfy { $0.reason.hasPrefix("Read ") && $0.reason.hasSuffix(".") })
        #expect(bookmarks.feature.commands.map(\.id) == ["search", "choose-browsers"])
        for browser in Browser.allCases {
            #expect(bookmarks.harness.context.settings[BookmarkSettings.includes(browser)] == false)
        }
        #expect(bookmarks.harness.context.settings[BookmarkSettings.showsInRootSearch] == false)
        #expect(bookmarks.harness.context.settings[BookmarkSettings.opensIn] == .defaultBrowser)
    }

    @Test func activationReadsNothingAndAsksForNothing() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, permissions: .denied)
        await bookmarks.harness.activate()
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.listed.isEmpty)
        #expect(bookmarks.files.reads.isEmpty)
        #expect(try await bookmarks.harness.catalogRows().isEmpty)
        #expect(bookmarks.files.reads.isEmpty, "root search asks, but bookmarks are not in root search")
        #expect(bookmarks.fakes.permissions.requests.isEmpty)
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
        #expect(bookmarks.fakes.fileWatcher.watchedDirectories.isEmpty)
    }

    @Test func theSearchPageNamesTheBrowsersFoundAndOffersToChoose() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, installed: [.safari, .chrome, .firefox])
        await bookmarks.harness.activate()
        try await bookmarks.open()
        let notice = try #require(bookmarks.harness.page?.notice)
        #expect(notice.title == "Choose Browsers to Search")
        #expect(
            notice.message == "Found Safari, Google Chrome and Firefox on this Mac. Nothing is read until you choose.")
        #expect(notice.action?.title == "Choose Browsers")
        #expect(bookmarks.harness.rows.isEmpty)
        #expect(bookmarks.files.reads.isEmpty)

        // The button opens the form, which offers the installed browsers.
        try await bookmarks.harness.perform(try #require(notice.action), row: nil)
        let form = try #require(bookmarks.harness.page?.form)
        let checkboxes = form.fields.filter {
            if case .checkbox = $0.kind { return true }
            return false
        }
        #expect(checkboxes.map(\.id) == ["safari", "chrome", "firefox", "root-search"])
        #expect(checkboxes[0].info?.contains("Full Disk Access") == true)

        try bookmarks.harness.fill("chrome", .bool(true))
        try bookmarks.harness.fill("firefox", .bool(true))
        try await bookmarks.harness.submit()
        try await bookmarks.harness.settle()
        #expect(bookmarks.harness.context.settings[BookmarkSettings.includes(.chrome)])
        #expect(!bookmarks.harness.context.settings[BookmarkSettings.includes(.safari)])
        #expect(bookmarks.harness.page?.notice == nil)
        #expect(
            bookmarks.harness.rows.map(\.title) == [
                "Team Wiki", "Release Checklist", "Example Domain", "Garden Planner", "Example Domain",
                "Library Catalog",
                "Status Page",
            ])
        #expect(!bookmarks.files.reads.contains("safari"))
        #expect(bookmarks.harness.issues.isEmpty)
    }

    @Test func noBrowserInstalledStillExplains() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, installed: [])
        await bookmarks.harness.activate()
        try await bookmarks.open()
        #expect(bookmarks.harness.page?.notice?.message?.hasPrefix("No supported browser is installed.") == true)
        let form = bookmarks.feature.chooseForm()
        #expect(form.fields.filter { Browser(rawValue: $0.id) != nil }.count == Browser.allCases.count)
    }

    @Test func safariIsNeverReadWithoutFullDiskAccess() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, permissions: .denied)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.safari, .chrome)
        try await bookmarks.open()
        #expect(!bookmarks.files.listed.contains(.safari))
        #expect(!bookmarks.files.reads.contains("safari"))
        #expect(bookmarks.fakes.permissions.requests.isEmpty)
        #expect(bookmarks.fakes.permissions.openStreamCount == 0, "no stream waits for the grant")
        #expect(!bookmarks.fakes.fileWatcher.watchedDirectories.contains(bookmarks.files.watchFolder(for: .safari)))
        let notice = try #require(bookmarks.harness.page?.notice)
        #expect(notice.title == "Safari Needs Full Disk Access")
        #expect(notice.action?.requires == [.fullDiskAccess])
        #expect(bookmarks.feature.status?.requires == [.fullDiskAccess])
        #expect(bookmarks.harness.rows.count == 5, "Chrome still shows")

        // The user grants it in settings: Safari is read and watched.
        try await bookmarks.harness.grantInSettings(.fullDiskAccess)
        #expect(bookmarks.files.reads.contains("safari"))
        #expect(bookmarks.harness.rows.contains { $0.title == "Project Board" })
        #expect(bookmarks.harness.page?.notice == nil)
        #expect(bookmarks.feature.status == nil)
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
        #expect(bookmarks.fakes.fileWatcher.watchedDirectories.contains(bookmarks.files.watchFolder(for: .safari)))
    }

    @Test func aGrantMadeInSystemSettingsIsReadAtTheNextOpen() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, permissions: .denied)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.safari)
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.isEmpty)
        bookmarks.fakes.permissions.set(.fullDiskAccess, to: .granted)
        bookmarks.harness.pop()
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.map(\.title) == ["Project Board", "Rye Bread", "A Long Read"])
        #expect(bookmarks.feature.status == nil)
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
    }

    @Test func theGrantButtonAsksOnlyWhenPressed() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, permissions: .denied)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.safari)
        try await bookmarks.open()
        #expect(bookmarks.fakes.permissions.requests.isEmpty)
        bookmarks.harness.grantsMissingPermissions = true
        try await bookmarks.harness.perform(try #require(bookmarks.harness.page?.notice?.action), row: nil)
        #expect(bookmarks.fakes.permissions.requests == [.fullDiskAccess])
        try await bookmarks.harness.settle()
        #expect(bookmarks.harness.rows.map(\.title) == ["Project Board", "Rye Bread", "A Long Read"])
    }

    @Test func turningSafariOffClearsTheStatus() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, permissions: .denied)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.safari)
        #expect(bookmarks.feature.status?.requires == [.fullDiskAccess])
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
        bookmarks.harness.context.settings[BookmarkSettings.includes(.safari)] = false
        try await bookmarks.harness.settle()
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
        #expect(bookmarks.feature.status == nil)
    }

    @Test func accessTakenAwayDropsSafariOnTheNextOpen() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.safari)
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.count == 3)
        bookmarks.fakes.permissions.set(.fullDiskAccess, to: .denied)
        bookmarks.harness.pop()
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.isEmpty)
        #expect(bookmarks.harness.page?.notice?.title == "Safari Needs Full Disk Access")
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
        #expect(bookmarks.feature.status?.requires == [.fullDiskAccess])
    }

    @Test func offAndOnLeavesNothingRunning() async throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, permissions: .denied)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.safari, .chrome)
        #expect(!bookmarks.fakes.fileWatcher.watchedDirectories.isEmpty)
        await bookmarks.harness.deactivate()
        try await bookmarks.harness.settle()
        #expect(bookmarks.fakes.fileWatcher.watchedDirectories.isEmpty)
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
        #expect(bookmarks.feature.library.snapshot.bookmarks.isEmpty, "bookmarks are let go")
        let readsWhileOff = bookmarks.files.reads.count
        await bookmarks.harness.activate()
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.reads.count == readsWhileOff, "activation reads nothing")
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.count == 5)
        await bookmarks.harness.deactivate()
        await bookmarks.harness.activate()
        await bookmarks.harness.deactivate()
        try await bookmarks.harness.settle()
        #expect(bookmarks.fakes.fileWatcher.watchedDirectories.isEmpty)
        #expect(bookmarks.fakes.permissions.openStreamCount == 0)
    }

    @Test func theSettingsPaneSaysWhatIsReadStoredAndSent() throws {
        let bookmarks = BookmarksHarness(files: Self.sampleFiles, installed: [.safari, .chrome])
        let pane = try #require(bookmarks.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        let toggles = items.compactMap { item -> String? in
            if case .toggle(let key) = item.control { return key.name }
            return nil
        }
        #expect(toggles.first == "browser.safari")
        for browser in Browser.allCases { #expect(toggles.contains("browser." + browser.rawValue)) }
        let safariIndex = try #require(items.firstIndex { $0.title == "Safari" })
        if case .permission(let permission) = items[safariIndex + 1].control {
            #expect(permission == .fullDiskAccess)
        } else {
            Issue.record("the grant button belongs beside Safari's switch")
        }
        #expect(items.first { $0.title == "Brave" }?.info?.hasSuffix("Not installed on this Mac.") == true)
        let notes = items.filter {
            if case .note = $0.control { return true }
            return false
        }.map(\.title)
        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.contains(Brand.name) || $0.hasPrefix("Nothing") })
        #expect(notes.contains { $0.contains("~/") || $0.contains("cache") })
        #expect(notes.contains { $0.hasPrefix("Nothing is sent") })
    }
}

@MainActor
@Suite("Search Bookmarks", .timeLimit(.minutes(1)))
struct SearchPageTests {
    @Test func typingFindsTitlesAndHosts() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        try await bookmarks.open()
        try await bookmarks.harness.setQuery("checklist")
        #expect(bookmarks.harness.rows.map(\.title) == ["Release Checklist"])
        #expect(bookmarks.harness.rows.first?.subtitle == "Bookmarks bar \u{203A} Work")
        try await bookmarks.harness.setQuery("garden.example")
        #expect(bookmarks.harness.rows.map(\.title) == ["Garden Planner"])
    }

    @Test func theDropdownFiltersByBrowserAndProfile() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome, .safari, .firefox)
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.count == 10)
        let options = try #require(bookmarks.harness.page?.dropdown?.options.map(\.id))
        #expect(options.contains("profile:chrome/Profile 1"))
        try await bookmarks.harness.setFilter("profile:chrome/Profile 1")
        #expect(bookmarks.harness.rows.map(\.title) == ["Garden Planner", "Example Domain"])
        try await bookmarks.harness.setFilter("reading-list")
        #expect(bookmarks.harness.rows.map(\.title) == ["A Long Read"])
        try await bookmarks.harness.setFilter("browser:firefox")
        #expect(bookmarks.harness.rows.map(\.title) == ["Library Catalog", "Status Page"])
        #expect(bookmarks.harness.rows.allSatisfy { $0.icon == .app(bundleID: "org.mozilla.firefox") })
    }

    @Test func theDetailShowsTheWholeLink() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        try await bookmarks.open()
        try bookmarks.harness.select(title: "Garden Planner")
        let detail = try #require(try await bookmarks.harness.loadDetail())
        #expect(detail.body == nil, "no link preview, which could fetch the page")
        #expect(detail.metadata.contains(.label("Link", value: "https://garden.example.net/")))
        #expect(detail.metadata.contains(.label("Profile", value: "Profile 1")))
    }

    @Test func aChangedFileIsReadAgainAndOtherChangesAreIgnored() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        try await bookmarks.open()
        let reads = bookmarks.files.reads.count

        // Chrome writes its history: nothing to read.
        let folder = bookmarks.files.watchFolder(for: .chrome)
        bookmarks.fakes.fileWatcher.simulateChange([folder.appending(path: "Default/History")])
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.reads.count == reads)

        // A bookmark is added in the second profile: only that profile is read again.
        bookmarks.files.set(
            .chrome, profile: "Profile 1",
            contents: [
                Samples.chromium([
                    ("Garden Planner", "https://garden.example.net/"), ("Seed List", "https://seeds.example.net/"),
                ])
            ])
        bookmarks.fakes.fileWatcher.simulateChange([bookmarks.file(.chrome, profile: "Profile 1")])
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.reads.suffix(from: reads) == ["chrome/Profile 1"])
        #expect(bookmarks.harness.rows.contains { $0.title == "Seed List" })

        // A new profile appears.
        bookmarks.files.set(
            .chrome, profile: "Profile 2", contents: [Samples.chromium([("Third", "https://third.example.com/")])])
        bookmarks.fakes.fileWatcher.simulateChange([bookmarks.file(.chrome, profile: "Profile 2")])
        try await bookmarks.harness.settle()
        #expect(bookmarks.harness.rows.contains { $0.title == "Third" })
    }

    @Test func firefoxIsReadAtMostEveryTenSecondsWhileItIsBusy() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.firefox)
        try await bookmarks.open()
        let profile = "ab12cd34.default-release"
        #expect(bookmarks.files.reads == ["firefox/" + profile])

        bookmarks.files.set(
            .firefox, profile: profile,
            contents: [BookmarkFixtures.firefox(menu: [.link("New One", "https://new.example.com/")])])
        bookmarks.fakes.fileWatcher.simulateChange([bookmarks.file(.firefox, profile: profile)])
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.reads.count == 1, "too soon after the last read")
        #expect(!bookmarks.harness.rows.contains { $0.title == "New One" })

        await bookmarks.fakes.clock.waitForSleepers()
        bookmarks.fakes.clock.advance(by: .seconds(10))
        try await bookmarks.harness.waitForChange()
        #expect(bookmarks.files.reads.count == 2)
        #expect(bookmarks.harness.rows.map(\.title) == ["New One"])
    }

    @Test func aFirefoxWriteThatChangesNoBookmarkAnnouncesNothing() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.firefox)
        let generation = bookmarks.feature.library.changes.generation
        bookmarks.fakes.clock.advance(by: .seconds(60))
        // A page visit: the database changes, its bookmarks do not.
        bookmarks.files.set(.firefox, profile: "ab12cd34.default-release", contents: [Samples.firefox])
        bookmarks.fakes.fileWatcher.simulateChange([bookmarks.file(.firefox, profile: "ab12cd34.default-release")])
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.reads.count == 2)
        #expect(bookmarks.feature.library.changes.generation == generation, "root search is not asked again")
    }

    @Test func aDamagedFileIsReportedAndTheLastGoodBookmarksStay() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        try await bookmarks.open()
        let profile = bookmarks.files.set(.chrome, profile: "Profile 1", contents: [Data("{\"roots\": ".utf8)])
        bookmarks.fakes.fileWatcher.simulateChange([bookmarks.file(.chrome, profile: "Profile 1")])
        try await bookmarks.harness.settle()
        let notice = try #require(bookmarks.harness.page?.notice)
        #expect(notice.title == "Some Bookmarks Could Not Be Read")
        #expect(
            notice.message
                == "Could not read Google Chrome, Profile 1. The file is damaged, or in a format this version cannot read."
        )
        #expect(bookmarks.harness.rows.contains { $0.title == "Garden Planner" }, "the last good read stays")
        #expect(bookmarks.feature.status?.title == "Some Bookmarks Could Not Be Read")

        bookmarks.files.fail(profile, with: .accessDenied)
        try await bookmarks.harness.perform("reload")
        #expect(bookmarks.harness.page?.notice?.message?.contains("macOS refused access to the file.") == true)

        bookmarks.files.set(.chrome, profile: "Profile 1", contents: [Samples.chromeSecond])
        try await bookmarks.harness.perform("reload")
        #expect(bookmarks.harness.page?.notice == nil)
        #expect(bookmarks.feature.status == nil)
    }

    @Test func emptyBrowsersShowAnEmptyState() async throws {
        let bookmarks = BookmarksHarness(files: { IsolatedBookmarkFiles(home: $0) })
        await bookmarks.harness.activate()
        try await bookmarks.choose(.vivaldi)
        try await bookmarks.open()
        #expect(bookmarks.harness.rows.isEmpty)
        #expect(bookmarks.harness.page?.notice == nil)
        #expect(bookmarks.harness.page?.emptyState?.title == "No Bookmarks")
    }

    @Test func theFallbackOpensThePageWithTheTypedText() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        let command = try bookmarks.harness.command("search")
        #expect(command.fallback?.title("wiki") == "Search Bookmarks for \u{201C}wiki\u{201D}")
        #expect(command.fallback?.startsOn == false, "a fallback starts off unless it is the feature's own web search")
        try await bookmarks.harness.runFallback("search", text: "wiki")
        #expect(bookmarks.harness.page?.listPage?.initialQuery == "wiki")
    }
}
