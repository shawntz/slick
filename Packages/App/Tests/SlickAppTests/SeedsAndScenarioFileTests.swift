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

    @Test func anotherCopyIsAnyOtherProcess() {
        #expect(SingleInstance.others(among: [10, 20], me: 10) == [20])
        #expect(SingleInstance.others(among: [10], me: 10).isEmpty)
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
        #expect(BenchMode.sizes == [3_000, 10_000])
    }
}
