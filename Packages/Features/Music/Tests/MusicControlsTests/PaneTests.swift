import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

/// What the settings pane shows besides the preferred player.
@Suite("Settings pane", .timeLimit(.minutes(1)))
@MainActor
struct PaneTests {
    @Test func thePaneShowsBothPlayersPermissions() throws {
        let pane = try #require(MediaHarness().feature.settingsPane)
        let permissions = pane.sections.flatMap(\.items).compactMap { item -> Permission? in
            if case .permission(let permission) = item.control { return permission }
            return nil
        }
        #expect(permissions == [Player.music.permission, Player.spotify.permission])
    }

    /// The settings window draws a feature's hotkey presets above its own sections.
    @Test func theHotkeysNoteSaysThePresetsAreAbove() {
        #expect(Strings.Settings.noHotkeysNote.contains("A preset above"))
        #expect(!Strings.Settings.noHotkeysNote.contains("below"))
    }
}
