import AppKit
import Foundation
import Host
import Kit
import LauncherUI
import SettingsUI
import Testing

@testable import SlickApp

/// The app steps that open the real settings window for a capture: on the pane asked for, at the
/// place given, never key, its frame never saved, and closed again.
@Suite("Settings window steps", .serialized, .timeLimit(.minutes(1)))
struct SettingsWindowStepTests {
    @Test func opensCapturesAndClosesTheWindowWithoutSavingItsFrame() async throws {
        let autosave = "NSWindow Frame SettingsWindow"
        let savedBefore = UserDefaults.standard.string(forKey: autosave)
        let data = FileManager.default.temporaryDirectory.appending(path: "settings-step-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: ScenarioRunTests.offscreen)
        let file = try ScenarioMode.load(
            Data(
                """
                {
                  "name": "Settings window",
                  "steps": [
                    { "app": { "openSettings": "learning", "captureSettings": "learning" } },
                    { "app": { "closeSettings": true } }
                  ]
                }
                """.utf8))
        let assembly = Assembly(try ScenarioMode.configuration(for: file, dataRoot: data, surface: surface))
        await assembly.start(prewarm: true)
        let panel = try #require(assembly.panel)
        let runner = ScenarioRunner(panel: panel, output: data.appending(path: "output"), placesInCorner: false)
        var captured: [CGRect] = []
        runner.capture = { frame in
            captured.append(frame)
            return ScenarioRunTests.solidImage()
        }
        runner.log = { _ in }
        let origin = CGPoint(x: -20000, y: -20000)
        let result = await ScenarioMode.run(file, runner: runner, assembly: assembly, settingsOrigin: origin) { _ in }
        #expect(result.passed, "\(result.reason ?? "")")
        #expect(result.captures.count == 1)
        #expect(result.captures.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(captured.count == 1)
        #expect(captured.first?.origin == origin)
        #expect((captured.first?.width ?? 0) >= 900)
        let controller = try #require(assembly.settings.existingController)
        #expect(controller.captureFrame == nil, "the window closed")
        #expect(!controller.isVisible)
        #expect(!NSApplication.shared.windows.contains { $0.isKeyWindow && $0.frame.origin == origin })
        #expect(UserDefaults.standard.string(forKey: autosave) == savedBefore)
        // Opening it this way is not a request a person made: nothing is recorded as opened.
        #expect(assembly.settings.requests.isEmpty)
        await assembly.shutdown()
    }

    @Test func refusesAnUnknownPaneAndACaptureWithNoWindow() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "settings-step-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let file = ScenarioMode.File(name: "x", timeLimit: 5, items: [])
        var configuration = try ScenarioMode.configuration(for: file, dataRoot: data)
        configuration.makesPanel = false
        let assembly = Assembly(configuration)
        var captures: [String] = []
        let unknown = try JSONDecoder().decode(AppStep.self, from: Data(#"{ "openSettings": "nothing" }"#.utf8))
        let problem = await ScenarioMode.perform(unknown, assembly: assembly, captures: &captures)
        #expect(problem == "no settings pane nothing")
        let capture = try JSONDecoder().decode(AppStep.self, from: Data(#"{ "captureSettings": "x" }"#.utf8))
        let missing = await ScenarioMode.perform(capture, assembly: assembly, captures: &captures)
        #expect(missing?.contains("no settings window to capture") == true)
        #expect(captures.isEmpty)
        await assembly.shutdown()
    }
}
