import AppKit
import Foundation
import Host
import Kit
import LauncherUI
import SettingsUI
import Testing

@testable import SlickApp

/// The app steps that open the real onboarding window on a step for a picture: on the step asked
/// for, at the place given, never key, applying nothing and marking nothing done, and closed again.
@Suite("Onboarding window steps", .serialized, .timeLimit(.minutes(1)))
struct OnboardingWindowStepTests {
    @Test func opensTheHotkeyStepCapturesItAndClosesIt() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "onboarding-step-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: ScenarioRunTests.offscreen)
        let file = try ScenarioMode.load(
            Data(
                """
                {
                  "name": "Onboarding window",
                  "steps": [
                    { "app": { "systemShortcuts": ["cmd+space"], "setSettings": { "launcherHotkey": "ctrl+opt+k" } } },
                    { "app": { "setSettings": { "launcherHotkey": "cmd+space" }, "hotkeyWaiting": "Spotlight" } },
                    { "app": { "openOnboarding": "hotkey", "captureOnboarding": "hotkey" } },
                    { "app": { "hotkeyWaiting": "Spotlight", "hotkeyBound": false } },
                    { "app": { "openOnboarding": "theme" } },
                    { "app": { "closeOnboarding": true } }
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
        #expect((captured.first?.width ?? 0) >= 500)
        let onboarding = try #require(assembly.settings.existingOnboarding)
        #expect(onboarding.shownStep == .theme)
        #expect(onboarding.captureFrame == nil, "the window closed")
        #expect(!NSApplication.shared.windows.contains { $0.isKeyWindow && $0.frame.origin == origin })
        // Picturing onboarding is not finishing it, and opens no settings.
        #expect(OnboardingController.isNeeded(assembly.services.settings))
        #expect(assembly.settings.requests.isEmpty)
        await assembly.shutdown()
    }

    @Test func refusesAnUnknownStepAndACaptureWithNoWindow() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "onboarding-step-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let file = ScenarioMode.File(name: "x", timeLimit: 5, items: [])
        var configuration = try ScenarioMode.configuration(for: file, dataRoot: data)
        configuration.makesPanel = false
        let assembly = Assembly(configuration)
        var captures: [String] = []
        let capture = try JSONDecoder().decode(AppStep.self, from: Data(#"{ "captureOnboarding": "x" }"#.utf8))
        let missing = await ScenarioMode.perform(capture, assembly: assembly, captures: &captures)
        #expect(missing?.contains("no onboarding window to capture") == true)
        let unknown = try JSONDecoder().decode(AppStep.self, from: Data(#"{ "openOnboarding": "nothing" }"#.utf8))
        let problem = await ScenarioMode.perform(unknown, assembly: assembly, captures: &captures)
        #expect(problem?.hasPrefix("no onboarding step nothing; the steps are welcome, hotkey") == true)
        #expect(captures.isEmpty)
        #expect(assembly.settings.existingOnboarding?.captureFrame == nil)
        await assembly.shutdown()
    }
}
