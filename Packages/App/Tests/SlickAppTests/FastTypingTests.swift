import AppKit
import Foundation
import Host
import Kit
import LauncherUI
import Root
import Testing

@testable import SlickApp

/// An async section that answers slower than the user types, as file search will.
final class SlowSearch: Feature, AsyncProvider {
    static let manifest = FeatureManifest(id: "slow-search", name: "Slow Search", icon: .symbol("tortoise"))

    /// How long each answer takes after the debounce.
    static let delay: Duration = .milliseconds(150)

    let namespace = "slow"
    let sectionTitle = "Slow"
    var minimumQueryLength: Int { 1 }
    /// Every query the provider started on, and those it answered without being cancelled.
    private(set) var started: [String] = []
    private(set) var answered: [String] = []

    init(context: FeatureContext) {}

    var liveProviders: [LiveProvider] { [.async(self)] }

    func results(for query: String) async throws -> [Row] {
        started.append(query)
        try await Task.sleep(for: Self.delay)
        try Task.checkCancellation()
        answered.append(query)
        return [Row(id: ItemID(namespace, query), title: "Slow: \(query)")]
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open Slowly") { _ in .close() }]
    }
}

/// Typing faster than an async section answers, through the joined launcher: the real panel, root
/// search and every feature, plus one slow async provider.
@Suite("Typing faster than async sections", .serialized)
struct FastTypingTests {
    @Test func onlyTheLastQuerysAnswerShowsAndNothingAboveItMoves() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "app-fast-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: ScenarioRunTests.offscreen)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        var configuration = Assembly.Configuration(
            environment: .scenario, dataRoot: data, workspace: { RecordingWorkspace(wrapping: $0) }, surface: surface)
        configuration.registrations = Features.registrations + [FeatureRegistration(SlowSearch.self)]
        let assembly = Assembly(configuration)
        await assembly.start(prewarm: true)
        let panel = try #require(assembly.panel)
        #expect(await SelfTest.within(.seconds(20)) { await assembly.ready() })
        let slow = try #require(assembly.runtime.instance("slow-search") as? SlowSearch)

        let file = try ScenarioMode.load(
            Data(
                """
                {
                  "name": "Typing faster than an async section",
                  "timeLimit": 60,
                  "steps": [
                    { "app": { "setFeatures": { "schedule": false } } },
                    { "summon": true },
                    { "type": "notes" },
                    { "expect": { "selection": "Notes" } },
                    { "waitUntilIdle": 15 },
                    { "expect": { "selection": "Notes", "rowsInclude": ["Notes", "Slow: notes"] } },
                    { "type": "x" },
                    { "press": "delete" },
                    { "type": "y" },
                    { "press": "delete" },
                    { "expect": { "selection": "Notes", "query": "notes" } },
                    { "waitUntilIdle": 15 },
                    { "expect": { "selection": "Notes", "rowsInclude": ["Notes", "Slow: notes"] } },
                    { "press": "escape" },
                    { "type": "zzqx" },
                    { "press": "escape" },
                    { "expect": { "query": "", "rowCount": 0 } },
                    { "waitUntilIdle": 15 },
                    { "expect": { "query": "", "rowCount": 0 } },
                    { "dismiss": true }
                  ]
                }
                """.utf8))
        let runner = ScenarioRunner(panel: panel, output: data.appending(path: "output"), placesInCorner: false)
        runner.capture = { _ in ScenarioRunTests.solidImage() }
        runner.log = { _ in }
        var lines: [String] = []
        let result = await ScenarioMode.run(file, runner: runner, assembly: assembly) { lines.append($0) }
        #expect(result.passed, "\(result.reason ?? "")\n\(lines.joined(separator: "\n"))")

        // Every keystroke cancelled the answer before it. Only full queries the user paused on
        // were answered, and no answer for a query that was gone ever reached the screen.
        #expect(!slow.answered.contains("n"))
        #expect(!slow.answered.contains("notesx"))
        #expect(!slow.answered.contains("zzqx"))
        #expect(slow.answered.allSatisfy { $0 == "notes" })
        let titles = panel.shownTitles
        #expect(!titles.contains { $0.hasPrefix("Slow: ") && $0 != "Slow: notes" })
        await assembly.shutdown()
    }
}
