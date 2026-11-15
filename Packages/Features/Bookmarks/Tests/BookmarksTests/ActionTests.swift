import Foundation
import Kit
import KitTesting
import Testing

@testable import Bookmarks

@MainActor
@Suite("Bookmark actions", .timeLimit(.minutes(1)))
struct ActionTests {
    static let oddLinks: [(String?, String)] = [
        ("Docs", "https://docs.example.com/guide"), ("Bookmarklet", "javascript:alert(document.title)"),
        ("Local Report", "file:///tmp/example/report.pdf"), ("Meeting", "zoommtg://example.com/join?id=1"),
        ("Flags", "chrome://flags"), ("Inline Page", "data:text/html,<p>hi</p>"), ("Sneaky", "java\nscript:alert(1)"),
    ]

    static func harness(installed: [Browser] = Browser.allCases) async throws -> BookmarksHarness {
        let bookmarks = BookmarksHarness(
            files: { home in
                let files = IsolatedBookmarkFiles(home: home)
                files.set(.chrome, profile: "Default", contents: [Samples.chromium(oddLinks)])
                return files
            }, installed: installed)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        try await bookmarks.open()
        return bookmarks
    }

    @Test func aWebLinkOpensInTheDefaultBrowserOrWhereItCameFrom() async throws {
        let bookmarks = try await Self.harness()
        try bookmarks.harness.select(title: "Docs")
        #expect(
            bookmarks.harness.actions().map(\.id) == [
                "open-default", "open-source", "open-with", "copy-link", "copy-markdown", "copy-title", "reload",
            ])
        #expect(
            bookmarks.harness.actions().map(\.title).prefix(2) == ["Open in Default Browser", "Open in Google Chrome"])
        try await bookmarks.harness.performPrimary()
        #expect(bookmarks.fakes.workspace.opened == [URL(string: "https://docs.example.com/guide")!])
        #expect(bookmarks.harness.isClosed)

        try bookmarks.harness.select(title: "Docs")
        try await bookmarks.harness.performSecondary()
        #expect(bookmarks.fakes.workspace.openedWith.map(\.bundleID) == ["com.google.Chrome"])
        #expect(bookmarks.harness.issues.isEmpty)
    }

    @Test func theSettingSwapsWhichOpenComesFirst() async throws {
        let bookmarks = try await Self.harness()
        bookmarks.harness.context.settings[BookmarkSettings.opensIn] = .sourceBrowser
        try bookmarks.harness.select(title: "Docs")
        #expect(bookmarks.harness.actions().map(\.id).prefix(2) == ["open-source", "open-default"])
        try await bookmarks.harness.performPrimary()
        #expect(bookmarks.fakes.workspace.openedWith.map(\.urls) == [[URL(string: "https://docs.example.com/guide")!]])
        #expect(bookmarks.fakes.workspace.opened.isEmpty)
    }

    @Test func aBrowserThatIsGoneIsNotOffered() async throws {
        let bookmarks = try await Self.harness(installed: [.safari])
        try bookmarks.harness.select(title: "Docs")
        #expect(!bookmarks.harness.actions().map(\.id).contains("open-source"))
        bookmarks.harness.context.settings[BookmarkSettings.opensIn] = .sourceBrowser
        #expect(bookmarks.harness.actions().first?.id == "open-default")
    }

    @Test func copyingTheLinkTheMarkdownAndTheTitle() async throws {
        let bookmarks = try await Self.harness()
        for id in ["copy-link", "copy-markdown", "copy-title"] {
            try bookmarks.harness.select(title: "Docs")
            try await bookmarks.harness.perform(id)
        }
        #expect(
            bookmarks.fakes.pasteboard.copiedTexts == [
                "https://docs.example.com/guide", "[Docs](https://docs.example.com/guide)", "Docs",
            ])
        #expect(bookmarks.harness.huds.map(\.title) == ["Copied Link", "Copied Markdown Link", "Copied Title"])
    }

    @Test func openWithListsTheAppsForTheLink() async throws {
        let bookmarks = try await Self.harness()
        bookmarks.fakes.workspace.applications = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            AppInfo(bundleID: "org.mozilla.firefox", name: "Firefox"),
        ]
        try bookmarks.harness.select(title: "Docs")
        let apps = try await bookmarks.harness.submenu("open-with")
        #expect(apps.map(\.title) == ["Safari", "Firefox"])
        try await bookmarks.harness.perform(apps[1], row: bookmarks.harness.selectedRow)
        #expect(bookmarks.fakes.workspace.openedWith.map(\.bundleID) == ["org.mozilla.firefox"])
    }

    @Test func bookmarkletsAndInlinePagesAreNeverOpened() async throws {
        let bookmarks = try await Self.harness()
        for title in ["Bookmarklet", "Inline Page", "Sneaky", "Flags"] {
            try bookmarks.harness.select(title: title)
            let ids = bookmarks.harness.actions().map(\.id)
            #expect(!ids.contains { $0.hasPrefix("open") }, "\(title): \(ids)")
            #expect(ids.first == "copy-link")
            try await bookmarks.harness.performPrimary()
        }
        #expect(bookmarks.fakes.workspace.opened.isEmpty)
        #expect(bookmarks.fakes.workspace.openedWith.isEmpty)
        #expect(bookmarks.fakes.pasteboard.copiedTexts.contains("javascript:alert(1)"), "the cleaned link")
    }

    @Test func aFileIsShownInFinderFirstAndOpensOnlyAfterAQuestion() async throws {
        let bookmarks = try await Self.harness()
        try bookmarks.harness.select(title: "Local Report")
        #expect(bookmarks.harness.actions().map(\.id).prefix(2) == ["reveal", "open-file"])
        try await bookmarks.harness.performPrimary()
        #expect(bookmarks.fakes.workspace.revealed == [URL(filePath: "/tmp/example/report.pdf")])

        try bookmarks.harness.select(title: "Local Report")
        bookmarks.harness.confirmationAnswer = false
        try await bookmarks.harness.perform("open-file")
        #expect(bookmarks.harness.confirmations.last?.title == "Open \u{201C}report.pdf\u{201D}?")
        #expect(bookmarks.fakes.workspace.opened.isEmpty)
        bookmarks.harness.confirmationAnswer = true
        try await bookmarks.harness.perform("open-file")
        #expect(bookmarks.fakes.workspace.opened == [URL(filePath: "/tmp/example/report.pdf")])
    }

    @Test func aLinkToAnotherAppAsksFirst() async throws {
        let bookmarks = try await Self.harness()
        try bookmarks.harness.select(title: "Meeting")
        #expect(bookmarks.harness.actions().first?.id == "open-link")
        bookmarks.harness.confirmationAnswer = false
        try await bookmarks.harness.performPrimary()
        #expect(bookmarks.fakes.workspace.opened.isEmpty)
        let question = try #require(bookmarks.harness.confirmations.last)
        #expect(question.title == "Open This Link in Another App?")
        #expect(question.message?.contains("\u{201C}zoommtg:\u{201D}") == true)
    }

    @Test func titlesFollowTheHouseStyle() async throws {
        let bookmarks = try await Self.harness()
        var titles: [String] = []
        for row in bookmarks.harness.rows {
            try bookmarks.harness.select(row.id)
            titles += bookmarks.harness.actions().map(\.title)
        }
        titles += bookmarks.feature.commands.map(\.title)
        for title in Set(titles) {
            #expect(!title.hasSuffix("."), "\(title)")
            #expect(title.first?.isUppercase == true, "\(title)")
        }
        #expect(bookmarks.harness.issues.isEmpty)
    }
}

@MainActor
@Suite("Root search", .timeLimit(.minutes(1)))
struct RootSearchTests {
    @Test func bookmarksJoinRootSearchOnlyWhenTurnedOn() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome, .firefox)
        #expect(try await bookmarks.harness.catalogRows().isEmpty)
        bookmarks.harness.context.settings[BookmarkSettings.showsInRootSearch] = true
        let rows = try await bookmarks.harness.catalogRows()
        #expect(
            rows.map(\.title) == [
                "Team Wiki", "Release Checklist", "Example Domain", "Garden Planner", "Library Catalog", "Status Page",
            ])
        #expect(rows.allSatisfy { $0.id.namespace == "bookmarks" })
        let actions = bookmarks.harness.rootActions(for: rows[0])
        #expect(actions.map(\.id).prefix(2) == ["open-default", "open-source"])
        #expect(!actions.map(\.id).contains("reload"))
        try await bookmarks.harness.performRoot("open-default", on: rows[0])
        #expect(bookmarks.fakes.workspace.opened == [URL(string: "https://wiki.example.org/")!])
    }

    @Test func turningRootSearchOnReadsTheChosenBrowsers() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        bookmarks.harness.context.settings[BookmarkSettings.includes(.chrome)] = true
        bookmarks.harness.context.settings[BookmarkSettings.showsInRootSearch] = true
        await bookmarks.harness.activate()
        #expect(bookmarks.files.reads.isEmpty)
        #expect(try await bookmarks.harness.catalogRows().count == 4)
        #expect(bookmarks.files.reads == ["chrome/Default", "chrome/Profile 1"])
    }

    @Test func aRememberedRowStillWorksAfterARelaunch() async throws {
        let first = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await first.harness.activate()
        try await first.choose(.chrome)
        first.harness.context.settings[BookmarkSettings.showsInRootSearch] = true
        let row = try #require(try await first.harness.catalogRows().first)
        let snapshot = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(row))

        // A new launch, before any browser is read.
        let second = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await second.harness.activate()
        let actions = second.harness.rootActions(for: snapshot)
        #expect(actions.map(\.id).first == "open-default")
        try await second.harness.performRoot("copy-markdown", on: snapshot)
        #expect(second.fakes.pasteboard.copiedTexts == ["[Team Wiki](https://wiki.example.org/)"])
        #expect(second.files.reads.isEmpty)
    }

    @Test func aRememberedRowCannotSmuggleInAScript() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        let forged = Row(
            id: ItemID("bookmarks", "chrome/Default/forged"), title: "Looks Harmless",
            payload: Payload(
                BookmarkPayload(link: "javascript:alert(1)", title: "Looks Harmless", browser: .chrome, kind: .web)))
        let snapshot = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(forged))
        let ids = bookmarks.harness.rootActions(for: snapshot).map(\.id)
        #expect(!ids.contains { $0.hasPrefix("open") })
    }

    @Test func rowsStandForTheirLinkSoUniversalActionsApply() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.chrome)
        try await bookmarks.open()
        try bookmarks.harness.select(title: "Team Wiki")
        #expect(bookmarks.harness.selectedRow?.represents == .url(URL(string: "https://wiki.example.org/")!))
    }
}
