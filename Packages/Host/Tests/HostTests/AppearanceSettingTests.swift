import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// The appearance setting in the Appearance pane draws the panel, the HUD and Large Type in light
/// or dark whatever the system shows, and Match System follows the system again. A change to the
/// selected theme in the theme store, as the pane makes while the user moves a control, restyles
/// the panel.
@Suite("Panel: the appearance setting and theme changes", .serialized, .timeLimit(.minutes(1)))
@MainActor struct AppearanceSettingTests {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    @Test func theSettingDrawsThePanelLightOrDarkAndSystemFollowsTheSystemAgain() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let general = HostSettings.settings(fixture.runtime.fakes.settings)
        let panel = fixture.panel
        let largeType = try #require(panel.largeType as? RecordingLargeType)
        #expect(!panel.resolvedTheme.isDark && !panel.rowMapper.isDark)

        general[HostSettings.appearance] = .dark
        #expect(await waitUntil { panel.resolvedTheme.isDark }, "the surface resolves its theme for dark")
        #expect(panel.surface.panel.appearance?.name == .darkAqua)
        #expect(panel.rowMapper.isDark, "the rows are drawn again for dark")
        #expect(fixture.hud.appearance?.name == .darkAqua)
        #expect(largeType.appearance?.name == .darkAqua)

        general[HostSettings.appearance] = .light
        #expect(await waitUntil { !panel.resolvedTheme.isDark })
        #expect(panel.surface.panel.appearance?.name == .aqua)
        #expect(!panel.rowMapper.isDark)
        #expect(fixture.hud.appearance?.name == .aqua)
        #expect(largeType.appearance?.name == .aqua)

        general[HostSettings.appearance] = .system
        #expect(await waitUntil { panel.surface.panel.appearance == nil })
        let systemIsDark = Self.isDark(NSApp.effectiveAppearance)
        #expect(panel.resolvedTheme.isDark == systemIsDark, "the panel draws as the system does")
        #expect(panel.rowMapper.isDark == systemIsDark)
        #expect(fixture.hud.appearance == nil)
        #expect(largeType.appearance == nil)
    }

    /// The panel takes the setting when it is made, before its first summon.
    @Test func aStoredSettingAppliesAtLaunch() async {
        let fixture = await PanelFixture.make(settings: ["appearance": .string("dark")], summon: false)
        defer { fixture.close() }
        #expect(fixture.panel.surface.panel.appearance?.name == .darkAqua)
        #expect(fixture.panel.resolvedTheme.isDark)
        #expect(fixture.panel.rowMapper.isDark)
        #expect(fixture.hud.appearance?.name == .darkAqua)
    }

    /// The HUD window resolves its theme each time it shows, so a HUD after the change draws in the
    /// new appearance. Large Type's window takes it too. Neither window is ordered in.
    @Test func theHUDAndLargeTypeWindowsTakeTheAppearance() throws {
        _ = NSApplication.shared
        let hud = HUDWindowDisplay()
        let largeType = LargeTypeWindowDisplay()
        defer {
            hud.window.close()
            largeType.window.close()
        }
        for dark in [true, false] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hud.appearance = appearance
            largeType.appearance = appearance
            let content = try #require(hud.window.contentView)
            #expect(Self.isDark(content.effectiveAppearance) == dark)
            #expect(
                ResolvedTheme(
                    theme: hud.window.theme, appearance: content.effectiveAppearance,
                    accessibility: DisplayAccessibility()
                ).isDark == dark)
            #expect(largeType.window.appearance?.name == appearance?.name)
        }
        hud.appearance = nil
        #expect(hud.window.appearance == nil)
    }

    @Test func aChangeToTheSelectedThemeRestylesThePanel() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "host-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(folder: folder)
        let fixture = await PanelFixture.make(themes: store)
        defer { fixture.close() }
        let surface = fixture.panel.surface
        var changed = Theme.standard
        changed.panel.cornerRadius = 30
        changed.clarity = 1.6
        changed.lens.style = .fill

        try store.update(changed, for: "Standard")
        #expect(surface.theme.panel.cornerRadius == 30)
        #expect(surface.theme.clarity == 1.6)
        #expect(surface.glass.cornerRadius == 30, "the glass itself takes the new corner radius")
        #expect(surface.lens.style == .fill)

        // A theme that is not selected leaves the panel alone.
        try store.update(.ember, for: "Ocean")
        #expect(surface.theme.clarity == 1.6)

        // Reset puts Standard back as it ships.
        try store.reset("Standard")
        #expect(surface.theme.panel.cornerRadius == Theme.standard.panel.cornerRadius)
        #expect(surface.lens.style == Theme.standard.lens.style)
    }
}
