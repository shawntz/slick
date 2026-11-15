import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import Snippets

@Suite("Storage and reload", .timeLimit(.minutes(1)))
struct StorageTests {
    @Test func firstRunSavesStarterSnippetsOnce() async throws {
        let fakes = FakeServices()
        let first = FeatureHarness(SnippetsFeature.self, fakes: fakes)
        #expect(first.issues.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: first.file.path))
        await first.start()

        let stored = try await first.storedSnippets()
        #expect(stored.map(\.name) == ["Today's Date", "Current Time", "Timestamp", "New UUID", "Thank You Reply"])
        #expect(Set(stored.compactMap(\.collection)) == ["Examples"])
        #expect(stored.allSatisfy { $0.created == fakes.clock.now })
        #expect(first.library.index.snippets == stored)

        // A deleted starter stays deleted: the next launch reads the file and adds nothing.
        try await first.library.remove(id: "starter-uuid")
        await first.deactivate()
        let second = FeatureHarness(SnippetsFeature.self, fakes: fakes)
        await second.start()
        #expect(second.library.index.snippets.count == 4)
        #expect(second.snippet(named: "New UUID") == nil)
    }

    @Test func changesAreSavedToTheFileAndReadOnTheNextLaunch() async throws {
        let fakes = FakeServices()
        let harness = try await FeatureHarness.loaded([Fixture.greeting], fakes: fakes)
        let added = try await harness.library.add(
            SnippetDraft(name: "  Thanks  ", text: "Thank you!", keyword: " ty ", collection: " Email ", expands: false)
        )
        try await harness.library.setPinned(true, id: added.id)
        try await harness.library.update(
            id: Fixture.greeting.id, with: SnippetDraft(name: "Hello", text: "Hello, {clipboard}", keyword: "hello"))

        let stored = try await harness.storedSnippets()
        #expect(stored.map(\.name) == ["Hello", "Thanks"])
        let thanks = try #require(stored.last)
        #expect(thanks.keyword == "ty")
        #expect(thanks.collection == "Email")
        #expect(!thanks.expands)
        #expect(thanks.isPinned)
        #expect(thanks.created == fakes.clock.now)
        #expect(stored.first?.modified == fakes.clock.now)

        // The file is pretty-printed JSON a person can read and edit.
        let raw = try String(contentsOf: harness.file, encoding: .utf8)
        #expect(raw.contains("\"version\" : 1"))
        #expect(raw.contains("\"name\" : \"Thanks\""))

        await harness.deactivate()
        let relaunched = FeatureHarness(SnippetsFeature.self, fakes: fakes)
        await relaunched.start()
        #expect(relaunched.library.index.snippets == harness.library.index.snippets)
    }

    @Test func aChangeOnDiskReloadsTheLibraryAndTheOpenList() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        try await harness.openSearch()
        #expect(harness.rows.map(\.title) == ["Greeting"])

        try await harness.writeFile([Fixture.greeting, Fixture.address])
        try await harness.announceFileChange()
        #expect(harness.library.index.snippets.map(\.name) == ["Greeting", "Office Address"])
        #expect(harness.rows.map(\.title) == ["Greeting", "Office Address"])
    }

    @Test func theLibrarysOwnSaveDoesNotReloadTwice() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        // A clock with sub-millisecond time, which the file cannot hold.
        harness.fakes.clock.set(Date(timeIntervalSince1970: 1_794_648_600.123_456))
        try await harness.library.add(SnippetDraft(name: "Later", text: "Later text"))
        let generation = harness.library.changes.generation
        try await harness.announceFileChange()
        #expect(harness.library.changes.generation == generation)
        let created = try #require(try await harness.storedSnippets().last?.created)
        #expect(abs(created.timeIntervalSince1970 - 1_794_648_600.123) < 0.001)
    }

    @Test func anUnreadableFileIsNeverOverwrittenAndRecoversWhenFixed() async throws {
        let harness = FeatureHarness(SnippetsFeature.self)
        let damaged = "{ \"version\": 1, \"snippets\": [ { \"name\": \"Half"
        try write(damaged, to: harness.file)
        await harness.start()

        #expect(harness.library.state != .ready)
        #expect(harness.feature.status?.level == .failure)
        #expect(harness.feature.status?.title == "Your snippets could not be read")
        await #expect(throws: ActionFailure.self) {
            try await harness.library.add(SnippetDraft(name: "New", text: "Text"))
        }
        #expect(try String(contentsOf: harness.file, encoding: .utf8) == damaged)

        try await harness.openSearch()
        #expect(harness.page?.notice?.title == "Your snippets could not be read")
        #expect(harness.page?.notice?.action?.id == "show-file")
        #expect(harness.issues.isEmpty)

        try await harness.writeFile([Fixture.greeting])
        try await harness.announceFileChange()
        #expect(harness.library.state == .ready)
        #expect(harness.feature.status == nil)
        #expect(harness.rows.map(\.title) == ["Greeting"])
        #expect(harness.page?.notice == nil)
    }

    @Test func aDamagedFileAfterLaunchKeepsWhatIsLoaded() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let declarations = harness.feature.declarationChanges?.generation ?? 0
        try write("not json", to: harness.file)
        try await harness.announceFileChange()
        #expect(harness.library.index.snippets.map(\.name) == ["Greeting"])
        #expect(harness.feature.status?.level == .failure)
        #expect((harness.feature.declarationChanges?.generation ?? 0) > declarations)
        await #expect(throws: ActionFailure.self) { try await harness.library.remove(id: Fixture.greeting.id) }
        #expect(try String(contentsOf: harness.file, encoding: .utf8) == "not json")
    }

    @Test func aDeletedFileEmptiesTheLibraryAndTheNextChangeWritesANewOne() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        try FileManager.default.removeItem(at: harness.file)
        try await harness.announceFileChange()
        #expect(harness.library.index.isEmpty)
        try await harness.library.add(SnippetDraft(name: "Fresh", text: "Fresh text"))
        #expect(try await harness.storedSnippets().map(\.name) == ["Fresh"])
    }

    @Test func aHandWrittenFileWithOnlyNamesAndTextsLoads() async throws {
        let harness = FeatureHarness(SnippetsFeature.self)
        try write(
            #"[{"name": "Plain", "text": "Plain text"}, {"name": "Keyed", "text": "Keyed text", "keyword": "kk"}]"#,
            to: harness.file)
        await harness.start()
        let plain = try #require(harness.snippet(named: "Plain"))
        #expect(plain.expands)
        #expect(!plain.isPinned)
        #expect(plain.keyword == nil)
        #expect(plain.id == Snippet.derivedID(name: "Plain", text: "Plain text"))

        // The derived ID is the same on every read, so nothing changes on a reload.
        let generation = harness.library.changes.generation
        try await harness.announceFileChange()
        #expect(harness.library.changes.generation == generation)
    }

    @Test func changesRunInTheOrderTheyWereAsked() async throws {
        let harness = try await FeatureHarness.loaded([])
        async let first = harness.library.add(SnippetDraft(name: "One", text: "1"))
        async let second = harness.library.add(SnippetDraft(name: "Two", text: "2"))
        async let third = harness.library.add(SnippetDraft(name: "Three", text: "3"))
        _ = try await (first, second, third)
        #expect(Set(try await harness.storedSnippets().map(\.name)) == ["One", "Two", "Three"])
        #expect(harness.library.index.snippets.count == 3)
    }
}
