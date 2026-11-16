import Foundation
import Host
import Kit
import Root
import Testing

@testable import SlickApp

@Suite("First-run seeds")
struct FirstRunSeedTests {
    @Test func readsBundleIDsFromDockTiles() {
        let tiles: [Any] = [
            ["tile-data": ["bundle-identifier": "com.example.mail"]],
            ["tile-data": ["bundle-identifier": "com.example.notes"]],
            ["tile-data": ["bundle-identifier": "com.example.mail"]],
            ["tile-data": ["file-label": "No ID"]],
            ["tile-data": ["bundle-identifier": "bad id with spaces"]],
            ["tile-data": ["bundle-identifier": ""]],
            "not a tile",
            ["tile-type": "spacer-tile"],
        ]
        #expect(FirstRunSeeds.bundleIDs(fromDockTiles: tiles) == ["com.example.mail", "com.example.notes"])
    }

    @Test func weighsEachKindAsRootAsks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seeds = FirstRunSeeds.seeds(
            dock: ["com.example.mail"], running: ["com.example.notes"],
            counted: [
                .init(bundleID: "com.example.calendar", useCount: 20, lastUsed: nil),
                .init(bundleID: "com.example.unused", useCount: 0, lastUsed: nil),
            ], now: now)
        #expect(seeds.count == 3)
        #expect(seeds[0] == LearningSeed.dockApp(ItemID("app", "com.example.mail"), now: now))
        #expect(seeds[1] == LearningSeed.runningApp(ItemID("app", "com.example.notes"), now: now))
        #expect(seeds[2] == LearningSeed.countedApp(ItemID("app", "com.example.calendar"), useCount: 20, lastUsed: now))
    }

    @Test func usesTheAppsFeaturesKeys() {
        #expect(FirstRunSeeds.appID("com.example.mail").rawValue == "app:com.example.mail")
        #expect(FirstRunSeeds.isBundleID("com.example.app-2_beta"))
        #expect(!FirstRunSeeds.isBundleID(".hidden"))
        #expect(!FirstRunSeeds.isBundleID("com.example/../x"))
        #expect(!FirstRunSeeds.isBundleID("é.example"))
    }

    @Test func theDataFolderLockAdmitsOneLauncherAndFreesOnRelease() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var first: InstanceLock?
        if case .acquired(let lock) = SingleInstance.lock(dataRoot: folder) { first = lock }
        #expect(first != nil)
        // A second open of the same file is another holder, as another process would be.
        guard case .heldElsewhere = SingleInstance.lock(dataRoot: folder) else {
            Issue.record("a second launcher took the lock")
            return
        }
        // Another data folder, as a selftest, bench or scenario uses, is not blocked.
        let other = folder.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        guard case .acquired = SingleInstance.lock(dataRoot: other) else {
            Issue.record("another data folder was blocked")
            return
        }
        // The lock goes with the descriptor, as it does when the process ends or crashes.
        first = nil
        guard case .acquired = SingleInstance.lock(dataRoot: folder) else {
            Issue.record("the lock was not freed")
            return
        }
        #expect(first == nil)
    }

    @Test func aFolderThatCannotHoldTheLockLetsTheLauncherRun() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)/deeper")
        guard case .unavailable = SingleInstance.lock(dataRoot: missing) else {
            Issue.record("a missing folder did not report the lock as unavailable")
            return
        }
    }
}

@Suite("Scenario files")
struct ScenarioFileTests {
    @Test func readsHostAndAppSteps() throws {
        let text = """
            {
              "name": "Example",
              "timeLimit": 12,
              "steps": [
                { "summon": true },
                { "app": { "link": "{scheme}://search?q=x", "linkOutcome": "openedLauncher" } },
                { "expect": { "query": "x" } },
                { "app": { "launched": [], "favorites": [] } }
              ]
            }
            """
        let file = try ScenarioMode.load(Data(text.utf8))
        #expect(file.name == "Example")
        #expect(file.timeLimit == 12)
        #expect(file.items.map(\.name) == ["summon", "app", "expect", "app"])
        guard case .app(let step) = file.items[1] else {
            Issue.record("step 2 is not an app step")
            return
        }
        #expect(step.resolvedLink == Brand.urlScheme + "://search?q=x")
        #expect(step.linkOutcome == "openedLauncher")
    }

    @Test(arguments: [
        #"{ "steps": [] }"#,
        #"{ "name": "x" }"#,
        #"{ "name": "x", "steps": [ { "app": { "unknown": 1 } } ] }"#,
        #"{ "name": "x", "steps": [ { "app": {} } ] }"#,
        #"{ "name": "x", "steps": [ { "nope": true } ] }"#,
        #"{ "name": "x", "steps": [ { "summon": true, "dismiss": true } ] }"#,
        #"[1, 2]"#,
    ])
    func refusesBadFiles(text: String) {
        #expect(throws: (any Error).self) { try ScenarioMode.load(Data(text.utf8)) }
    }

    @Test func capsTheTimeLimit() throws {
        let file = try ScenarioMode.load(Data(#"{ "name": "x", "timeLimit": 999, "steps": [] }"#.utf8))
        #expect(file.timeLimit == Scenario.maximumTimeLimit)
    }

    @Test func everyCommittedScenarioReads() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../scenarios").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        for file in files {
            #expect(throws: Never.self, "\(file.lastPathComponent)") { try ScenarioMode.load(Data(contentsOf: file)) }
        }
    }
}

@Suite("Bench catalog")
struct BenchCatalogTests {
    @Test func theSyntheticCatalogIsTheSameEveryRun() async throws {
        #expect(SyntheticCatalog.titles(count: 3_000) == SyntheticCatalog.titles(count: 3_000))
        let titles = SyntheticCatalog.titles(count: 3_000)
        #expect(Set(titles).count == 3_000)
        #expect(titles.contains { $0.hasPrefix("Sample ") })
        #expect(titles.contains { $0.contains("Item") })
        let rows = try await SyntheticCatalog(count: 10).rows()
        #expect(rows.count == 10)
        #expect(rows.allSatisfy { $0.id.namespace == SyntheticCatalog.benchNamespace })
    }

    @Test func benchNamesCoverRootAndHost() {
        #expect(BenchMode.names.first == "root")
        #expect(BenchMode.names.contains("typing"))
        // The bench that takes key status runs only when named.
        #expect(BenchMode.names.contains("summon-key"))
        #expect(!HostBench.names.contains("summon-key"))
        #expect(BenchMode.sizes == [3_000, 10_000])
    }
}
