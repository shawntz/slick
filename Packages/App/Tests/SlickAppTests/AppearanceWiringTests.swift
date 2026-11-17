import AppKit
import Foundation
import Host
import Kit
import KitHosting
import LauncherUI
import SettingsUI
import Testing

@testable import SlickApp

/// The settings window and the panel share one theme store and one settings service, so what the
/// Appearance pane changes reaches the panel of the joined launcher: a theme's values, through the
/// store, and the appearance setting.
@Suite("Appearance reaches the panel", .serialized, .timeLimit(.minutes(1)))
struct AppearanceWiringTests {
    @Test func aThemeChangeAndTheAppearanceSettingReachThePanel() async throws {
        let data = FileManager.default.temporaryDirectory.appending(path: "app-appearance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: ScenarioRunTests.offscreen)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let assembly = Assembly(
            .init(
                environment: .scenario, dataRoot: data, workspace: { RecordingWorkspace(wrapping: $0) },
                surface: surface))
        await assembly.start(prewarm: false)
        let panel = try #require(assembly.panel)
        let themes = assembly.dependencies.themes
        #expect(themes === assembly.themes, "settings change the store the panel draws from")

        var changed = themes.current
        changed.panel.cornerRadius = 31
        changed.clarity = 1.4
        try themes.update(changed, for: themes.selectedName)
        #expect(panel.surface.theme.panel.cornerRadius == 31)
        #expect(panel.surface.theme.clarity == 1.4)
        let file = data.appending(path: Assembly.themesFolderName).appending(path: "Standard.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        HostSettings.settings(assembly.dependencies.services.settings)[HostSettings.appearance] = .dark
        try await waitUntil { panel.surface.panel.appearance?.name == .darkAqua }
        #expect(panel.resolvedTheme.isDark)
        #expect(assembly.recordingHUD?.appearance?.name == .darkAqua)

        assembly.general[HostSettings.appearance] = .system
        try await waitUntil { panel.surface.panel.appearance == nil }
        #expect(assembly.recordingHUD?.appearance == nil)
        await assembly.shutdown()
        surface.panel.close()
    }
}
