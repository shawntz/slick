import Foundation
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

@Suite struct PersistenceTests {
    @Test func rememberedRowsAndLearningSurviveARelaunch() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        do {
            let first = await RootFixture.ready(storage: storage, environment: .live)
            #expect(first.root.status == .ready(persistent: true))
            try await first.pick("Groceries List", for: "note groceries")
            try await first.pick("Terminal", for: "term")
            try await first.pick("Terminal", for: "term")
            await first.root.flush()
            await first.shutdown()
        }

        let second = await RootFixture.ready(storage: storage, environment: .live)
        let root = second.root
        #expect(root.status == .ready(persistent: true))
        #expect(second.results("groceries") == ["Groceries List"])
        let note = try #require(root.row(for: ItemID("note", "groceries")))
        #expect(note.payload?.string == "groceries")
        #expect(root.actions(for: note).map(\.title) == ["Open Note"])
        #expect(root.featureID(for: note) == LibraryFeature.manifest.id)
        #expect(root.usage.useCount(of: note.id) == 1)
        #expect(second.results("term").first == "Terminal")
        await second.shutdown()
    }

    @Test func aSecondEngineOnTheSameFolderFallsBackToMemory() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        let first = await RootFixture.ready(storage: storage, environment: .live)
        let second = await RootFixture.ready(storage: storage, environment: .live)
        #expect(first.root.status == .ready(persistent: true))
        #expect(second.root.status == .inMemory(.directoryInUse))
        #expect(second.root.status.featureStatus?.level == .warning)
        #expect(second.results("calendar") == ["Calendar"])
        try await second.pick("Terminal", for: "term")
        await second.shutdown()
        await first.shutdown()
    }

    @Test func anUnusableFolderFallsBackToMemory() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let blocker = folder.url.appending(path: "blocker")
        try Data("x".utf8).write(to: blocker)
        let fixture = await RootFixture.ready(storage: RootStoragePaths(directory: blocker), environment: .live)
        #expect(fixture.root.status == .inMemory(.directoryUnusable))
        #expect(fixture.results("calendar") == ["Calendar"])
        await fixture.shutdown()
    }

    @Test func outsideTheLiveEnvironmentOnlyTheJSONFilesAreWritten() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        let fixture = await RootFixture.ready(storage: storage, environment: .scenario)
        #expect(fixture.root.status == .ready(persistent: false))
        try await fixture.pick("Groceries List", for: "note groceries")
        await fixture.root.flush()
        await fixture.shutdown()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path(percentEncoded: false)).sorted()
        #expect(names == ["learning.json", "remembered.json", "usage.json"])
        for name in names {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: folder.url.appending(path: name).path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test func aDamagedElementIsSkippedNotTheFile() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let good = #"{"id":"emoji:a","lastUsed":0,"count":3,"score":1}"#
        let bad = #"{"id":"not an id","lastUsed":0,"count":1,"score":1}"#
        try Data(#"{"version":1,"items":[\#(bad),\#(good)]}"#.utf8).write(to: folder.url.appending(path: "usage.json"))
        try Data("not json".utf8).write(to: folder.url.appending(path: "remembered.json"))
        let fixture = await RootFixture.ready(storage: RootStoragePaths(directory: folder.url))
        #expect(fixture.root.usage.useCount(of: ItemID("emoji", "a")) == 3)
        #expect(fixture.root.usage.recentlyUsed(namespace: "emoji", limit: 5).count == 1)
        await fixture.shutdown()
    }

    @Test func pathsComeFromTheStorageService() {
        let storage = RootStoragePaths(storage: FakeStorageStandIn())
        #expect(storage.directory?.lastPathComponent == RootStoragePaths.folderName)
        #expect(storage.engineDirectory?.lastPathComponent == "engine")
        #expect(RootStoragePaths.inMemory.rememberedFile == nil)
    }
}

/// A storage service that only hands out paths under the temporary directory.
private final class FakeStorageStandIn: StorageService {
    let root = FileManager.default.temporaryDirectory.appending(path: "root-tests-paths")

    func dataDirectory(for featureID: String) -> URL {
        root.appending(path: featureID)
    }

    func cacheDirectory(for featureID: String) -> URL {
        root.appending(path: "cache").appending(path: featureID)
    }

    var homeDirectory: URL { root.appending(path: "home") }
}
