import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// The scenario runner, driving the off-screen test panel. Captures are replaced by a solid
/// image, so nothing is shown or captured on the real screen.
@Suite("Scenarios", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ScenarioTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Scenarios", directoryHint: .isDirectory)

    private func makeRunner(_ fixture: PanelFixture) -> (ScenarioRunner, URL) {
        let output = fixture.runtime.fakes.storage.root.appending(path: "scenario-out", directoryHint: .isDirectory)
        let runner = ScenarioRunner(panel: fixture.panel, output: output, placesInCorner: false)
        runner.capture = { _ in Self.solidImage() }
        runner.log = { _ in }
        return (runner, output)
    }

    @Test(arguments: ["root-to-list.json", "form-validation.json"])
    func theExampleScenariosPass(_ name: String) async throws {
        let fixture = await PanelFixture.make(rows: SampleRows.all + [SampleRows.survey], summon: false)
        defer { fixture.close() }
        let (runner, output) = makeRunner(fixture)
        var lines: [String] = []
        runner.log = { lines.append($0) }
        let passed = await runner.run(file: Self.folder.appending(path: name))
        #expect(passed, "\(lines.joined(separator: "\n"))")
        #expect(lines.last == "scenario PASS")
        let data = try Data(contentsOf: output.appending(path: "result.json"))
        let result = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["passed"] as? Bool == true)
        #expect((result["captures"] as? [String])?.count == 1)
        #expect(FileManager.default.fileExists(atPath: (result["captures"] as? [String])?.first ?? ""))
    }

    @Test func aFailedExpectationStopsWithItsReason() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let (runner, _) = makeRunner(fixture)
        let scenario = Scenario(
            name: "wrong selection",
            steps: [
                .summon, .type("Plain"), .expect(ScenarioExpectation(selection: "Echo")), .press("return"),
            ])
        let result = await runner.run(scenario)
        #expect(!result.passed)
        #expect(result.reason == "step 3 expect: selection was \"Plain\", expected \"Echo\"")
        #expect(result.steps.count == 3, "nothing runs after a failure")
    }

    @Test func theTimeLimitBoundsTheRun() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let (runner, _) = makeRunner(fixture)
        let scenario = Scenario(name: "slow", timeLimit: 0.2, steps: [.summon, .wait(5), .summon])
        let started = ContinuousClock.now
        let result = await runner.run(scenario)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!result.passed)
        #expect(result.reason?.hasPrefix("time limit") == true)
    }

    @Test func waitUntilIdleWaitsForALoad() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["alpha"])
        source.gated = true
        fixture.open(.list(ListPage(source, title: "Notes")))
        let (runner, _) = makeRunner(fixture)
        let busy = await runner.run(Scenario(name: "busy", steps: [.waitUntilIdle(0.1)]))
        #expect(busy.reason?.contains("not idle") == true)
        source.gate.open()
        let idle = await runner.run(
            Scenario(name: "idle", steps: [.waitUntilIdle(2), .expect(.init(rows: ["alpha"]))]))
        #expect(idle.passed, "\(idle.reason ?? "")")
    }

    @Test func keysReachTheActionCard() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let (runner, _) = makeRunner(fixture)
        let result = await runner.run(
            Scenario(
                name: "card",
                steps: [
                    .type("Notes"), .press("cmd+k"),
                    .expect(
                        .init(actions: [
                            "Open", "Copy", "Reveal", "Shout", "Add to Favorites", "Set Alias",
                            "Set Hotkey", "Reset Ranking",
                        ])),
                    .type("cop"), .press("return"), .waitUntilIdle(2), .expect(.init(visible: true)),
                ]))
        #expect(result.passed, "\(result.reason ?? "")")
        #expect(fixture.copied.value == [SampleRows.note.id])
    }

    @Test func plainKeysTypeAndDeleteRemovesOne() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let (runner, _) = makeRunner(fixture)
        let result = await runner.run(
            Scenario(
                name: "keys",
                steps: [
                    .press("n"), .press("o"), .press("space"), .press("shift+x"), .press("delete"),
                    .expect(.init(query: "no ")), .press("escape"), .expect(.init(query: "")),
                ]))
        #expect(result.passed, "\(result.reason ?? "")")
    }

    @Test func stepsDecodeFromTheirOneKey() throws {
        let json = """
            {"name": "all", "timeLimit": 500, "steps": [
              {"summon": true}, {"type": "a"}, {"press": "cmd+shift+k"}, {"waitUntilIdle": 1}, {"wait": 0.5},
              {"expect": {"rowCount": 2}}, {"capture": "plain"}, {"capture": {"name": "keyed", "key": true}},
              {"fill": {"field": "name", "value": "x"}}, {"dismiss": true}
            ]}
            """
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        #expect(scenario.timeLimit == Scenario.maximumTimeLimit)
        #expect(
            scenario.steps == [
                .summon, .type("a"), .press("cmd+shift+k"), .waitUntilIdle(1), .wait(0.5),
                .expect(ScenarioExpectation(rowCount: 2)), .capture(name: "plain", key: false),
                .capture(name: "keyed", key: true), .fill(field: "name", value: "x"), .dismiss,
            ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Scenario.self, from: Data(#"{"name": "x", "steps": [{"jump": 1}]}"#.utf8))
        }
    }

    nonisolated static func solidImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }
}
