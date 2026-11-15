import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Storage, reload and the built-in searches", .timeLimit(.minutes(1)))
@MainActor
struct StorageTests {
    @Test func theBuiltInSearchesAreAboutThirtyAndEachTakesTheTypedText() {
        let all = DefaultSearches.all
        #expect((25...35).contains(all.count))
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        for quicklink in all {
            let template = LinkTemplate(quicklink.link)
            #expect(template.takesQuery, "\(quicklink.id) takes the typed text")
            #expect(template.issues.isEmpty)
            #expect(template.scheme == "https")
            #expect(template.webHost != nil)
            #expect(!quicklink.keywords.isEmpty)
            #expect(quicklink.isBuiltIn && quicklink.isEnabled)
            #expect(Quicklink.isValidID(quicklink.id))
            #expect(LinkTemplate.validated(quicklink.link) == .valid(quicklink.link))
        }
        #expect(DefaultSearches.quicklink(id: DefaultSearches.defaultEngineID) != nil)
        #expect(all.filter(\.isFallback).map(\.id) == ["wikipedia"])
    }

    @Test func firstLaunchWritesTheBuiltInSearches() async throws {
        let quicklinks = try await QuicklinksHarness()
        let stored = try #require(try await quicklinks.storedFile())
        #expect(stored.quicklinks == DefaultSearches.all)
        #expect(stored.removedDefaults.isEmpty)
        #expect(stored.version == QuicklinkFile.currentVersion)
        #expect(quicklinks.feature.entries.map(\.quicklink) == DefaultSearches.all)
        #expect(quicklinks.feature.status == nil)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func theFileIsPlainJSONAPersonCanRead() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.feature.setEnabled(false, id: "sample-docs")
        let text = try String(contentsOf: quicklinks.fileURL, encoding: .utf8)
        #expect(text.contains("\"name\" : \"Sample Docs\""))
        #expect(text.contains("\"enabled\" : false"))
        #expect(text.contains("https://docs.example.com/guide"), "slashes are not escaped")
    }

    @Test func anOlderFileGainsNewBuiltInsButNotDeletedOnes() async throws {
        let old = QuicklinkFile(quicklinks: [DefaultSearches.all[0], Samples.docs], removedDefaults: ["bing"])
        let quicklinks = try await QuicklinksHarness(file: old)
        let ids = quicklinks.feature.entries.map(\.id)
        #expect(ids.prefix(2) == ["google", "sample-docs"])
        #expect(!ids.contains("bing"), "a deleted built-in stays deleted")
        #expect(ids.contains("wikipedia"), "a new built-in joins")
        #expect(ids.count == DefaultSearches.all.count)
    }

    @Test func aFileWrittenByHandIsMadeSafe() async throws {
        let removed = try String(decoding: JSONEncoder().encode(DefaultSearches.all.map(\.id)), as: UTF8.self)
        let raw = """
            {"quicklinks": [
              {"id": "my link", "name": "Hand Written", "link": "https://hand.example.com"},
              {"id": "dup", "name": "First", "link": "https://first.example.com"},
              {"id": "dup", "name": "  ", "link": "https://second.example.com", "enabled": false}
            ], "removedDefaults": \(removed)}
            """
        let quicklinks = try await QuicklinksHarness(raw: raw)
        let entries = quicklinks.feature.entries.map(\.quicklink)
        #expect(entries.count == 3)
        #expect(Quicklink.isValidID(entries[0].id) && entries[0].id != "my link")
        #expect(entries[0].isEnabled && entries[0].keywords.isEmpty && entries[0].openWith == nil)
        #expect(entries.map(\.id).suffix(2) == ["dup", "dup-2"])
        #expect(entries[2].name == Strings.untitled)
        #expect(!entries[2].isEnabled)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func anEditOnDiskReloadsTheCommandsAndTheCatalog() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        #expect(try await quicklinks.harness.catalogRows().map(\.title) == ["Sample Docs"])
        var edited = Samples.file
        edited.quicklinks.append(Quicklink(id: "sample-wiki", name: "Sample Wiki", link: "https://wiki.example.com"))
        edited.quicklinks.removeAll { $0.id == "sample-tracker" }
        let before = quicklinks.feature.changes.generation
        try await quicklinks.editFileOnDisk(edited)
        #expect(quicklinks.feature.changes.generation > before)
        #expect(try await quicklinks.harness.catalogRows().map(\.title).sorted() == ["Sample Docs", "Sample Wiki"])
        #expect(!quicklinks.commandIDs().contains("open.sample-tracker"))
    }

    @Test func anOpenListFollowsAnEditOnDisk() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try await quicklinks.harness.run("search")
        var edited = Samples.samplesOnly
        edited.quicklinks[0].name = "Renamed Docs"
        try await quicklinks.editFileOnDisk(edited)
        #expect(quicklinks.harness.rows.map(\.title).contains("Renamed Docs"))
    }

    @Test func theFeaturesOwnSaveSendsOneSignal() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let before = quicklinks.feature.changes.generation
        try await quicklinks.feature.setEnabled(false, id: "sample-docs")
        #expect(quicklinks.feature.changes.generation == before + 1)
        // The watch then reports the feature's own write; the file matches, so nothing is sent.
        quicklinks.fakes.fileWatcher.simulateChange([quicklinks.fileURL])
        try await quicklinks.harness.settle()
        #expect(quicklinks.feature.changes.generation == before + 1)
    }

    @Test func anUnreadableFileBlocksSavingUntilItIsFixed() async throws {
        let quicklinks = try await QuicklinksHarness(raw: "{ not json")
        #expect(quicklinks.feature.status?.level == .warning)
        #expect(quicklinks.feature.status?.title == Strings.statusUnreadable)
        #expect(quicklinks.feature.entries.count == DefaultSearches.all.count, "the built-ins still work")
        // Saving would overwrite the file the user is fixing.
        await #expect(throws: ActionFailure(Strings.fileUnreadableTitle, message: Strings.fileUnreadableMessage)) {
            try await quicklinks.feature.setEnabled(false, id: "google")
        }
        #expect(try String(contentsOf: quicklinks.fileURL, encoding: .utf8) == "{ not json")

        try await quicklinks.editFileOnDisk(Samples.samplesOnly)
        #expect(quicklinks.feature.status == nil)
        #expect(quicklinks.feature.entries.map(\.id) == ["sample-docs", "sample-tracker", "sample-search"])
        try await quicklinks.feature.setEnabled(false, id: "sample-docs")
        #expect(try await quicklinks.storedFile()?.quicklinks.first?.isEnabled == false)
    }

    @Test func aFileThatBreaksWhileRunningKeepsTheLastGoodList() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let before = quicklinks.feature.changes.generation
        try await quicklinks.writeRawFileOnDisk("[")
        #expect(quicklinks.feature.status != nil)
        #expect(quicklinks.feature.changes.generation == before + 1, "settings shows the status")
        #expect(quicklinks.feature.entries.map(\.id) == ["sample-docs", "sample-tracker", "sample-search"])
    }

    @Test func aDeletedFileStartsAgainFromTheBuiltIns() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        try FileManager.default.removeItem(at: quicklinks.fileURL)
        quicklinks.fakes.fileWatcher.simulateChange([quicklinks.fileURL])
        try await quicklinks.harness.settle()
        #expect(quicklinks.feature.entries.map(\.quicklink) == DefaultSearches.all)
        #expect(!FileManager.default.fileExists(atPath: quicklinks.fileURL.path), "the next change writes it")
    }

    @Test func deletingABuiltInIsRememberedAndRestoringBringsEveryBuiltInBack() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        let feature = quicklinks.feature
        try await feature.remove(id: "bing")
        var wiki = try #require(feature.entry(id: "wikipedia")).quicklink
        wiki.link = "https://de.wikipedia.org/wiki/Special:Search?search={query}"
        wiki.name = "Search German Wikipedia"
        try await feature.upsert(wiki)
        try await feature.setEnabled(false, id: "youtube")
        let stored = try #require(try await quicklinks.storedFile())
        #expect(stored.removedDefaults == ["bing"])
        #expect(stored.quicklinks.first { $0.id == "wikipedia" }?.name == "Search German Wikipedia")

        try await quicklinks.editFileOnDisk(stored)
        #expect(feature.entry(id: "bing") == nil, "a reload keeps it deleted")

        quicklinks.harness.confirmationAnswer = false
        try await quicklinks.harness.pressSettingsButton(Strings.restoreButton)
        #expect(feature.entry(id: "bing") == nil, "declining changes nothing")

        quicklinks.harness.confirmationAnswer = true
        try await quicklinks.harness.pressSettingsButton(Strings.restoreButton)
        #expect(quicklinks.harness.confirmations.last?.title == Strings.restoreTitle)
        #expect(feature.entry(id: "bing")?.quicklink == DefaultSearches.quicklink(id: "bing"))
        #expect(feature.entry(id: "wikipedia")?.quicklink == DefaultSearches.quicklink(id: "wikipedia"))
        #expect(feature.entry(id: "youtube")?.quicklink.isEnabled == true)
        #expect(feature.entry(id: "sample-docs")?.quicklink == Samples.docs, "the user's own stay")
        #expect(try await quicklinks.storedFile()?.removedDefaults == [])
        #expect(quicklinks.harness.toasts.last?.title == Strings.restoredDefaults)
    }

    @Test func restoringLeavesAQuicklinkOfTheUsersOwnThatSharesAnID() async throws {
        let own = Quicklink(id: "google", name: "My Own Search", link: "https://search.example.com/?q={query}")
        let quicklinks = try await QuicklinksHarness(file: QuicklinkFile(quicklinks: [own]))
        try await quicklinks.feature.restoreDefaults()
        #expect(quicklinks.feature.entry(id: "google")?.quicklink == own)
        #expect(quicklinks.feature.entries.count == DefaultSearches.all.count)
    }

    @Test func theFeatureWatchesItsDataFolderUntilItIsTurnedOff() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        #expect(quicklinks.fakes.fileWatcher.watchedDirectories == [quicklinks.harness.context.storage.dataDirectory])
        await quicklinks.harness.deactivate()
        var edited = Samples.samplesOnly
        edited.quicklinks[0].name = "Renamed Docs"
        try await quicklinks.editFileOnDisk(edited)
        #expect(quicklinks.feature.entry(id: "sample-docs")?.quicklink.name == "Sample Docs")
    }
}
