import AppKit
import Foundation
import Host
import Kit
import LauncherUI
import Root
import Testing

@testable import SlickApp

/// A file search that finds an app's own bundle, as File Search does for an app in
/// ~/Applications in the live launcher. The scenario environment's file index holds only made-up
/// documents, so this stands in for it.
final class BundleFinder: Feature, AsyncProvider {
    static let manifest = FeatureManifest(id: "bundle-finder", name: "Bundle Finder", icon: .symbol("doc"))

    let namespace = "bundle-file"
    let sectionTitle = "Files"
    var minimumQueryLength: Int { 1 }
    var debounce: Duration { .zero }
    /// What every query finds, set by the test.
    var found: [Row] = []

    init(context: FeatureContext) {}

    var liveProviders: [LiveProvider] { [.async(self)] }

    func results(for query: String) async throws -> [Row] {
        found
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open File") { _ in .close() }]
    }
}

/// One item that two features list: an app row from the Apps feature and a file row for the same
/// bundle from a file search, through the joined launcher.
@Suite("One item, two rows", .serialized, .timeLimit(.minutes(2)))
struct OneItemTwoRowsTests {
    @Test func anAppAndItsBundleFoundAsAFileShowOnce() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "app-one-item-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: ScenarioRunTests.offscreen)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        var configuration = Assembly.Configuration(
            environment: .scenario, dataRoot: data, workspace: { RecordingWorkspace(wrapping: $0) }, surface: surface)
        configuration.registrations = Features.registrations + [FeatureRegistration(BundleFinder.self)]
        let assembly = Assembly(configuration)
        await assembly.start(prewarm: true)
        let panel = try #require(assembly.panel)
        #expect(await SelfTest.within(.seconds(20)) { await assembly.ready() })
        let finder = try #require(assembly.runtime.instance("bundle-finder") as? BundleFinder)

        let app = try #require(assembly.root.row(for: ItemID("app", "com.example.text-editor")))
        guard case .files(let urls) = app.represents, let bundle = urls.first else {
            Issue.record("the app row stands for no file: \(String(describing: app.represents))")
            return
        }
        // The file search spells the folder with a trailing slash, as a directory URL does.
        let spelled = URL(filePath: bundle.path(percentEncoded: false), directoryHint: .isDirectory)
        let notes = URL(
            filePath: bundle.deletingLastPathComponent().path(percentEncoded: false) + "Text Editor notes.txt")
        finder.found = [
            Row(id: ItemID("bundle-file", spelled.path), title: "Text Editor.app", represents: .files([spelled])),
            Row(id: ItemID("bundle-file", notes.path), title: "Text Editor notes.txt", represents: .files([notes])),
        ]

        let file = try ScenarioMode.load(
            Data(
                """
                {
                  "name": "One item, two rows",
                  "timeLimit": 60,
                  "steps": [
                    { "summon": true },
                    { "type": "text editor" },
                    { "waitUntilIdle": 15 },
                    { "expect": { "selection": "Text Editor", "rowsInclude": ["Text Editor", "Text Editor notes.txt"] } }
                  ]
                }
                """.utf8))
        let runner = ScenarioRunner(panel: panel, output: data.appending(path: "output"), placesInCorner: false)
        runner.capture = { _ in ScenarioRunTests.solidImage() }
        runner.log = { _ in }
        var lines: [String] = []
        let result = await ScenarioMode.run(file, runner: runner, assembly: assembly) { lines.append($0) }
        #expect(result.passed, "\(result.reason ?? "")\n\(lines.joined(separator: "\n"))")
        // The app shows once: the file row for its bundle is left out, the other file stays.
        #expect(!panel.shownTitles.contains("Text Editor.app"), "\(panel.shownTitles)")
        #expect(panel.shownTitles.filter { $0 == "Text Editor" }.count == 1)
        await assembly.shutdown()
    }
}
