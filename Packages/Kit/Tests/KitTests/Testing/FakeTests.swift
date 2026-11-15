import Foundation
import Kit
import KitTesting
import Testing

@Suite("Fakes")
struct FakeTests {
    @Test func clockWakesSleepersWhenTheirDeadlinePassesAndHonorsCancellation() async throws {
        let clock = FakeClock()
        let start = clock.now
        var woke: [Int] = []
        let late = Task { @MainActor in
            try await clock.sleep(for: .seconds(2))
            woke.append(2)
        }
        let early = Task { @MainActor in
            try await clock.sleep(for: .seconds(1))
            woke.append(1)
        }
        let cancelled = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(3)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        clock.advance(by: .seconds(1))
        try await early.value
        #expect(woke == [1])
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(4))
        try await late.value
        #expect(woke == [1, 2])
        #expect(clock.now == start + 5)
        try await clock.sleep(for: .zero)
    }

    @Test func simpleIndexRanksByTierThenLength() {
        let index = SimpleFuzzyIndex([
            FuzzyEntry(title: "Terminal"), FuzzyEntry(title: "Term"), FuzzyEntry(title: "Google Chrome"),
            FuzzyEntry(title: "Mode Dark"), FuzzyEntry(title: "Determine"), FuzzyEntry(title: "Café"),
            FuzzyEntry(title: "Notes", keywords: ["terminal notes"]),
        ])
        #expect(index.search("term", limit: 10).map(\.index) == [1, 0, 6, 4])
        #expect(index.search("term", limit: 10).map(\.tier) == [.exact, .prefix, .wordPrefix, .substring])
        #expect(index.search("gc", limit: 10).map(\.tier) == [.wordPrefix])
        #expect(index.search("dark mode", limit: 10).map(\.tier) == [.unordered])
        #expect(index.search("cafe", limit: 10).map(\.index) == [5])
        #expect(index.search("trml", limit: 10).first?.tier == .subsequence)
        #expect(MatchTier.allCases.last == .subsequence && MatchTier.typo < .subsequence)
        #expect(index.search("rmin", limit: 10).map(\.tier) == [.substring, .substring, .subsequence])
        #expect(index.search("term", limit: 1).count == 1)
        #expect(index.search("Term", limit: 10).first?.highlights == [0..<4])
        #expect(index.search("   ", limit: 10).isEmpty)
    }

    @Test func processesAndHTTPRefuseAnythingNotStubbed() async throws {
        let fakes = FakeServices()
        await #expect(throws: ProcessError.launchFailed("no fake for tool")) {
            try await fakes.processes.run(ProcessRequest(executable: URL(filePath: "/bin/tool")))
        }
        let url = try #require(URL(string: "https://example.test/x"))
        await #expect(throws: FakeHTTPError.notStubbed(url)) { try await fakes.http.send(HTTPRequest(url)) }
        fakes.http.stub(url, response: HTTPResponse(status: 404, body: Data("missing".utf8)))
        #expect(try await fakes.http.send(HTTPRequest(url)).text == "missing")
        #expect(fakes.http.requests.count == 2)
    }

    @Test func pasteboardStreamsCopiesFromOtherAppsWithTheirSource() async {
        let pasteboard = FakePasteboard(clock: FakeClock())
        var entries = pasteboard.entries().makeAsyncIterator()
        pasteboard.simulateCopy("one", from: "com.example.a")
        let entry = await entries.next()
        #expect(entry?.plainText == "one")
        #expect(entry?.sourceBundleID == "com.example.a")
        #expect(pasteboard.changeCount == 1)
        await pasteboard.copy("two")
        #expect(await pasteboard.recentText(offset: 0) == "two")
        #expect(await pasteboard.recentText(offset: 1) == "one")
        pasteboard.pasteFailure = .permissionMissing(.accessibility)
        await #expect(throws: PasteError.permissionMissing(.accessibility)) { try await pasteboard.paste("x") }
    }

    @Test func hotkeysRefuseConflictsAndRunOnPress() async throws {
        let hotkeys = FakeHotkeys()
        let combo = KeyCombo(.space, .command)
        hotkeys.addConflict(HotkeyConflict(owner: "Spotlight", canOverride: false), for: combo)
        #expect(throws: HotkeyError.conflict([HotkeyConflict(owner: "Spotlight", canOverride: false)])) {
            try hotkeys.register(combo, id: "launcher") {}
        }
        var pressed = 0
        try hotkeys.register(KeyCombo(.space, .option), id: "launcher") { pressed += 1 }
        #expect(await hotkeys.press("launcher"))
        hotkeys.unregister(id: "launcher")
        #expect(await !hotkeys.press("launcher"))
        #expect(pressed == 1)
    }

    @Test func storageLivesInATemporaryFolderThatGoesAway() throws {
        var root: URL?
        do {
            let storage = FakeStorage()
            root = storage.root
            let data = storage.dataDirectory(for: "demo")
            #expect(data.path.hasPrefix(storage.root.path))
            #expect(!FileManager.default.fileExists(atPath: data.path), "paths only; the writer makes the folder")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(root).path))
    }

    @Test func fileWatcherReportsOnlyChangesInsideWatchedFolders() async {
        let watcher = FakeFileWatcher()
        var changes = watcher.watch([URL(filePath: "/tmp/kit-example/scripts")]).makeAsyncIterator()
        watcher.simulateChange([URL(filePath: "/tmp/elsewhere/a"), URL(filePath: "/tmp/kit-example/scripts/b.sh")])
        #expect(await changes.next() == [URL(filePath: "/tmp/kit-example/scripts/b.sh")])
    }
}
