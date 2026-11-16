import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

/// Odd and hostile input: damaged files, every kind of Unicode, queries that look like search
/// syntax, clock changes, access taken away while running, and the feature switched off and on.
@Suite("Odd and hostile input", .timeLimit(.minutes(1)))
@MainActor
struct RobustnessTests {
    // MARK: Damaged files

    @Test func aDamagedDatabaseIsSetAsideAndANewHistoryStarts() async throws {
        let fakes = FakeServices()
        let folder = fakes.storage.dataDirectory(for: ClipboardHistoryFeature.manifest.id)
        let database = folder.appending(path: "history.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8_192).write(to: database)

        let clipboard = await ClipboardHarness(fakes: fakes)
        try await clipboard.copy("after the damage")
        #expect(try await clipboard.store.text(offset: 0) == "after the damage")

        let damaged = try #require(await clipboard.store.damagedCopy)
        let kept = try Data(contentsOf: damaged.appending(path: "history.sqlite"))
        #expect(kept == Data(repeating: 0x5A, count: 8_192), "the damaged file is kept, not deleted")

        try await clipboard.openHistory()
        #expect(clipboard.harness.page?.notice?.title == Strings.List.damagedTitle)
        #expect(clipboard.harness.rows.map(\.title) == ["after the damage"])
        #expect(clipboard.harness.issues.isEmpty)
        #expect(clipboard.harness.pendingIssues.isEmpty)
    }

    @Test func aSecondDamagedDatabaseGetsItsOwnFolder() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        for round in 1...2 {
            try FileManager.default.createDirectory(at: temporary.folder, withIntermediateDirectories: true)
            try Data("not a database \(round)".utf8).write(to: temporary.store.databaseURL)
            let store = HistoryStore(folder: temporary.folder)
            try await store.record(TemporaryStore.capture("round \(round)"), at: .distantPast)
            #expect(try await store.count() == 1)
            await store.close()
            try FileManager.default.removeItem(at: temporary.store.databaseURL)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.folder.path).sorted()
        #expect(names.filter { $0.hasPrefix("damaged-") } == ["damaged-1", "damaged-2"])
    }

    @Test func aHugeImageGetsNoThumbnailButIsKept() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        try FileManager.default.createDirectory(at: temporary.folder, withIntermediateDirectories: true)
        let png = Samples.png(width: 64, height: 64)
        let small = temporary.folder.appending(path: "small.png")
        let refused = temporary.folder.appending(path: "refused.png")
        #expect(ImageFiles.writeThumbnail(of: png, to: small))
        #expect(!ImageFiles.writeThumbnail(of: png, to: refused, pixelLimit: 64 * 63))
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        #expect(!ImageFiles.writeThumbnail(of: Samples.fakeImage(bytes: 64, seed: 1), to: refused))
    }

    // MARK: Unicode and search syntax

    @Test func searchSyntaxInTheQueryIsTakenAsText() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("plain words only")
        try await clipboard.openHistory()
        let queries = [
            "\"", "\"\"\"", "***", "a*", "NEAR(plain words)", "plain XOR only", "-plain", "^plain", "body:plain",
            "plain AND", "(", ")", "%", "_", "\\", "'", "%%%", "___", "a\u{0}b", "plain\u{0}xyz",
            String(repeating: "x", count: 5_000), String(repeating: "ab ", count: 300),
        ]
        for query in queries {
            try await clipboard.harness.setQuery(query)
            #expect(clipboard.harness.rows.isEmpty, "\(query.prefix(20)) matches nothing")
        }
        for query in ["\u{0}", "\u{0}\u{0}\u{0}", "\u{1B}\u{7F}"] {
            try await clipboard.harness.setQuery(query)
            #expect(clipboard.harness.rows.count == 1, "control characters alone are an empty query")
        }
        try await clipboard.harness.setQuery("plain only")
        #expect(clipboard.harness.rows.map(\.title) == ["plain words only"])
        try await clipboard.harness.setQuery("%")
        #expect(clipboard.harness.rows.isEmpty, "a percent sign is not a wildcard")
    }

    @Test func everyKindOfUnicodeIsKeptFoundAndHighlighted() async throws {
        let clipboard = await ClipboardHarness()
        let texts = [
            "👍🏽 thumbs up with tone", "👨‍👩‍👧 family", "שלום עולם", "مرحبا بالعالم", "日本語のテキスト",
            "Cafe\u{301} au lait", "Zalgo z\u{336}\u{337}\u{338}a\u{336}l\u{337}g\u{338}o", "\u{202E}reversed",
            "tab\tseparated\tvalues", "line one\r\nline two",
        ]
        for text in texts { try await clipboard.copy(text) }
        try await clipboard.openHistory()
        #expect(clipboard.harness.rows.count == texts.count)
        #expect(clipboard.harness.rows.last?.title == "👍🏽 thumbs up with tone")
        #expect(clipboard.harness.rows.first?.title == "line one", "the first line only")

        try await clipboard.harness.setQuery("👍🏽")
        #expect(clipboard.harness.rows.map(\.title) == ["👍🏽 thumbs up with tone"])
        try await clipboard.harness.setQuery("עולם")
        #expect(clipboard.harness.rows.map(\.title) == ["שלום עולם"])
        try await clipboard.harness.setQuery("テキスト")
        #expect(clipboard.harness.rows.map(\.title) == ["日本語のテキスト"])
        try await clipboard.harness.setQuery("café")
        let cafe = try #require(clipboard.harness.rows.first)
        #expect(cafe.title == "Cafe\u{301} au lait")
        #expect(cafe.titleHighlights == [0..<5], "the highlight covers the combining accent")
        #expect(clipboard.harness.issues.isEmpty)
    }

    @Test func titlesSkipBlankLinesAndInvisibleCharacters() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("\u{200B}\u{200B}\u{FEFF}")
        try await clipboard.copy(String(repeating: "\n", count: 400) + "below many blank lines")
        try await clipboard.openHistory()
        #expect(clipboard.harness.rows.map(\.title) == ["below many blank lines", Strings.Rows.emptyText])
        try await clipboard.harness.setQuery("lines")
        #expect(clipboard.harness.rows.map(\.title) == ["below many blank lines"])
    }

    @Test func veryLongTextIsKeptWholeAndPreviewedInPart() async throws {
        let clipboard = await ClipboardHarness()
        let long = String(repeating: "word ", count: 400_000)
        try await clipboard.copy(long)
        try await clipboard.openHistory()
        let row = try #require(clipboard.harness.rows.first)
        #expect(row.title.count <= HistoryRows.titleLength)
        #expect(row.represents == nil, "long text does not travel with its row")
        guard case .text(let shown, _)? = try await clipboard.harness.loadDetail()?.body else {
            Issue.record("expected a text preview")
            return
        }
        #expect(shown.count < long.count)
        try await clipboard.harness.performSecondary()
        #expect(clipboard.pasteboard.copiedTexts == [long])
    }

    // MARK: Clock changes

    @Test func aClockSetBackKeepsNewestFirstAndSectionsDistinct() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("before the change")
        clipboard.fakes.clock.set(clipboard.fakes.clock.now.addingTimeInterval(-3 * 24 * 3_600))
        try await clipboard.copy("after the clock went back")
        try await clipboard.copy("before the change")
        try await clipboard.openHistory()
        #expect(clipboard.harness.rows.map(\.title) == ["before the change", "after the clock went back"])
        let ids = clipboard.harness.sections.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Access and activation

    @Test func accessTakenAwayWhileRunningIsFollowedUntilGrantedAgain() async throws {
        let clipboard = await ClipboardHarness()
        #expect(clipboard.feature.status == nil)
        #expect(!clipboard.feature.isWatchingAccess, "with access granted nothing polls")
        #expect(clipboard.fakes.permissions.openStreamCount == 0)
        try await clipboard.openHistory()
        #expect(clipboard.harness.page?.notice == nil)

        // Taken away in System Settings: the status says so at once, and the history page shows
        // the notice when it loads, then waits for the grant.
        clipboard.fakes.permissions.set(.pasteboard, to: .denied)
        #expect(clipboard.feature.status?.requires == [.pasteboard])
        let before = clipboard.feature.declarations.generation
        try await clipboard.harness.reloadPage()
        #expect(clipboard.harness.page?.notice?.title == Strings.List.notAllowedTitle)
        #expect(clipboard.feature.isWatchingAccess)
        #expect(clipboard.feature.declarations.generation > before, "settings learns of it")

        clipboard.fakes.permissions.set(.pasteboard, to: .granted)
        try await clipboard.harness.settle()
        #expect(clipboard.feature.status == nil)
        #expect(clipboard.harness.page?.notice == nil, "the open page follows the grant")
        #expect(!clipboard.feature.isWatchingAccess, "the watch ends with the grant")
        #expect(clipboard.fakes.permissions.openStreamCount == 0)
    }

    @Test func noAccessWatchOutlivesTheFeature() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.pasteboard, to: .denied)
        let clipboard = await ClipboardHarness(fakes: fakes)
        #expect(clipboard.feature.isWatchingAccess)
        await clipboard.harness.deactivate()
        #expect(!clipboard.feature.isWatchingAccess)
        await clipboard.harness.activate()
        await clipboard.harness.deactivate()
        fakes.permissions.set(.pasteboard, to: .granted)
        try await clipboard.harness.settle()
        #expect(!clipboard.feature.isWatchingAccess)
        #expect(fakes.permissions.openStreamCount == 0)
    }

    @Test func switchingTheFeatureOffAndOnRecordsEachCopyOnce() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("before")
        for _ in 0..<3 {
            await clipboard.harness.deactivate()
            await clipboard.harness.activate()
        }
        #expect(clipboard.feature.isMonitoring)
        try await clipboard.copy("after")
        let detail = try #require(try await clipboard.store.detail(ClipboardHarness.textKey("after")))
        #expect(detail.copyCount == 1)
        #expect(try await clipboard.store.count() == 2)
    }

    @Test func switchingOnWhilePausedStaysPausedAndResumes() async throws {
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.isPaused] = true
        try await clipboard.harness.settle()
        await clipboard.harness.deactivate()
        await clipboard.harness.activate()
        #expect(!clipboard.feature.isMonitoring)
        clipboard.settings[ClipboardSettings.isPaused] = false
        try await clipboard.harness.settle()
        #expect(clipboard.feature.isMonitoring)
        try await clipboard.copy("resumed")
        #expect(try await clipboard.store.count() == 1)
    }

    // MARK: Empty history

    @Test func anEmptyHistoryAnswersEverywhere() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.openHistory()
        #expect(clipboard.harness.rows.isEmpty)
        #expect(clipboard.harness.page?.emptyState?.title == Strings.List.emptyTitle)
        #expect(try await clipboard.feature.suggestionTriggers[0].suggestions(at: clipboard.fakes.clock.now).isEmpty)
        #expect(await HistoryReader(store: clipboard.store).text(offset: 0) == nil)
        #expect(await HistoryReader(store: clipboard.store).text(offset: -1) == nil)
        #expect(try await clipboard.feature.clearRecent(.hour) == 0)
        #expect(try await clipboard.feature.clearHistory() == 0)
    }
}
