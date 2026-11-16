import AppKit
import Foundation
import Host
import Kit
import Testing

/// A scenario never puts Large Type on screen: an `expect` step reads the text it recorded.
@Suite("Scenario: Large Type", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ScenarioLargeTypeTests {
    @Test func aScenarioReadsWhatLargeTypeShowed() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let output = FileManager.default.temporaryDirectory.appending(
            path: "large-type-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = ScenarioRunner(panel: fixture.panel, output: output, placesInCorner: false)
        let result = await runner.run(
            Scenario(
                name: "large type",
                steps: [
                    .expect(ScenarioExpectation(largeType: "")), .type("notes"), .press("cmd+l"),
                    .expect(ScenarioExpectation(visible: false, largeType: "notes")),
                ]))
        #expect(result.passed, "\(result.reason ?? "")")

        let wrong = await runner.run(
            Scenario(name: "wrong", steps: [.expect(ScenarioExpectation(largeType: "other"))]))
        #expect(!wrong.passed)
        #expect(wrong.reason?.contains("Large Type showed \"notes\"") == true)
    }

    @Test func aScenarioFileNamesTheExpectation() throws {
        let json = #"{"name": "x", "steps": [{"expect": {"largeType": "482 913"}}]}"#
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        #expect(scenario.steps == [.expect(ScenarioExpectation(largeType: "482 913"))])
    }
}
