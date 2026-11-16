import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// macOS can switch between light and dark while the launcher runs, at sunset for example. The
/// surface restyles what it draws by itself. The host draws row glyphs for one appearance, so it has
/// to draw its rows again, or black glyphs stay on dark glass.
@Suite("Panel: following the system's appearance", .serialized, .timeLimit(.minutes(1)))
@MainActor struct AppearanceFollowTests {
    @Test func aSwitchToDarkDrawsTheRowsAgainForDark() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        #expect(!fixture.panel.rowMapper.isDark)
        let lookupsInLight = fixture.icons.lookups.count

        fixture.panel.surface.panel.appearance = NSAppearance(named: .darkAqua)
        #expect(await waitUntil { fixture.panel.rowMapper.isDark }, "the row mapper follows the switch")
        #expect(fixture.panel.rowMapper.resolvedTheme?.isDark == true)
        #expect(fixture.panel.resolvedTheme.isDark)
        #expect(fixture.icons.lookups.count > lookupsInLight, "the page asked for its icons again")

        let lookupsInDark = fixture.icons.lookups.count
        fixture.panel.surface.panel.appearance = NSAppearance(named: .aqua)
        #expect(await waitUntil { !fixture.panel.rowMapper.isDark }, "and follows it back")
        #expect(fixture.icons.lookups.count > lookupsInDark)
    }
}
