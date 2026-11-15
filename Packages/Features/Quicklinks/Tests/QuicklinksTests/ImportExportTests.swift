import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Import and export as JSON", .timeLimit(.minutes(1)))
@MainActor
struct ImportExportTests {
    @Test func exportWritesEveryQuicklinkToTheChosenFile() async throws {
        var file = Samples.samplesOnly
        file.quicklinks[0].isEnabled = false
        file.quicklinks[0].openWith = Samples.browserID
        let quicklinks = try await QuicklinksHarness(file: file)
        let destination = exchangeFile(quicklinks, "export/Quicklinks.json")
        quicklinks.fakes.fileDialogs.saveLocation = destination
        try await quicklinks.harness.run("export")
        #expect(quicklinks.fakes.fileDialogs.saveRequests.first?.suggestedName == Strings.exportFileName)
        #expect(quicklinks.harness.toasts.last?.title == "Exported 3 quicklinks")

        let exported = try JSONDecoder().decode([ExchangedQuicklink].self, from: Data(contentsOf: destination))
        #expect(exported.map(\.name) == ["Sample Docs", "Sample Tracker", "Sample Search"])
        #expect(exported[0].enabled == false && exported[0].openWith == Samples.browserID)
        #expect(exported[1].enabled == nil && exported[1].keywords == ["issue"])
        #expect(exported[2].fallback == true)
    }

    @Test func aCancelledDialogDoesNothing() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let exported = try await quicklinks.harness.run("export")
        let imported = try await quicklinks.harness.run("import")
        #expect(exported.kind == .keepOpen && imported.kind == .keepOpen)
        #expect(quicklinks.harness.toasts.isEmpty)
        #expect(quicklinks.fakes.fileDialogs.openRequests.first?.allowedTypes == ["json"])
    }

    @Test func anExportImportsIntoAnotherSetupAndSkipsDuplicates() async throws {
        let source = try await QuicklinksHarness(file: Samples.file)
        let destination = exchangeFile(source, "export.json")
        source.fakes.fileDialogs.saveLocation = destination
        try await source.harness.run("export")

        let target = try await QuicklinksHarness()
        target.fakes.fileDialogs.filesToChoose = [destination]
        try await target.harness.run("import")
        let names = target.feature.entries.map(\.quicklink.name)
        #expect(names.suffix(3) == ["Sample Docs", "Sample Tracker", "Sample Search"])
        #expect(names.count == DefaultSearches.all.count + 3, "the built-ins were duplicates")
        let toast = try #require(target.harness.toasts.last)
        #expect(toast.title == "Imported 3 quicklinks")
        #expect(toast.message == "Skipped \(DefaultSearches.all.count) duplicates.")
        let imported = try #require(target.feature.entries.last?.quicklink)
        #expect(imported.id != Samples.search.id && !imported.isBuiltIn && imported.isFallback)
        #expect(try await target.storedFile()?.quicklinks.count == DefaultSearches.all.count + 3)
    }

    @Test func aRaycastStyleListImports() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "raycast.json")
        try write(
            """
            [
              {"name": "Team Wiki", "link": "https://wiki.example.com/{argument name=\\"Page\\"}", "openWith": "com.example.browser"},
              {"name": "Board", "link": "board.example.com", "openWith": "Example Browser", "iconName": "star"},
              {"name": "", "link": "https://empty-name.example.com"},
              {"link": "https://no-name.example.com"},
              {"name": "Broken", "link": "https://x.example.com/{argument nme=\\"a\\"}"},
              {"name": "Sample Docs", "link": "https://docs.example.com/guide"}
            ]
            """, to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        try await quicklinks.harness.run("import")
        let added = quicklinks.feature.entries.suffix(2).map(\.quicklink)
        #expect(added.map(\.name) == ["Team Wiki", "Board"])
        #expect(added[0].openWith == Samples.browserID)
        #expect(added[1].openWith == nil, "an app name is not a bundle ID")
        #expect(added[1].link == "https://board.example.com")
        #expect(quicklinks.harness.toasts.last?.message == "Skipped 1 duplicate and 3 entries that were not valid.")
        #expect(throws: Never.self) { try quicklinks.harness.command(added[0].commandID) }
    }

    @Test func theFeaturesOwnFileImportsToo() throws {
        let data = try JSONEncoder().encode(Samples.samplesOnly)
        let entries = try QuicklinkExchange.decode(data)
        #expect(entries.map(\.name) == ["Sample Docs", "Sample Tracker", "Sample Search"])
    }

    @Test func aFileThatIsNotAListOfQuicklinksIsRefused() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "notes.json")
        try write("{\"title\": \"not quicklinks\"}", to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        await #expect(throws: ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)) {
            try await quicklinks.harness.run("import")
        }
        #expect(quicklinks.feature.entries.count == 3)
    }

    @Test func mergeCountsWhatItSkips() {
        var idNumber = 0
        let result = QuicklinkExchange.merge(
            [
                ExchangedQuicklink(name: "One", link: "https://one.example.com", keywords: ["One", "two words", "1"]),
                ExchangedQuicklink(name: "one", link: "https://one.example.com"),
                ExchangedQuicklink(
                    name: "Two", link: "mailto:{argument name=\"To\"}", icon: "envelope", fallback: true),
                ExchangedQuicklink(name: "Bad Icon", link: "https://icon.example.com", icon: "../x"),
                ExchangedQuicklink(name: String(repeating: "n", count: 101), link: "https://long.example.com"),
                ExchangedQuicklink(name: "No Link"),
            ],
            into: [Samples.docs],
            makeID: {
                idNumber += 1
                return "imported-\(idNumber)"
            })
        #expect(result.added.map(\.id) == ["imported-1", "imported-2", "imported-3"])
        #expect(result.added[0].keywords == ["one", "1"])
        #expect(result.added[1].icon == "envelope" && result.added[1].isFallback)
        #expect(result.added[2].icon == nil)
        #expect(result.duplicates == 1)
        #expect(result.invalid == 2)
    }

    private func exchangeFile(_ quicklinks: QuicklinksHarness, _ name: String) -> URL {
        quicklinks.fakes.storage.root.appending(path: "exchange").appending(path: name)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
