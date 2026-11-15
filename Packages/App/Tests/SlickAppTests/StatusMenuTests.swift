import AppKit
import Kit
import KitTesting
import SettingsUI
import Testing

@testable import SlickApp

/// The menu bar item's menu, made without installing the item, so nothing reaches the menu bar.
@Suite("Menu bar menu", .timeLimit(.minutes(1)))
struct StatusMenuTests {
    @Test func namesAWaitingHotkeyAndOffersKeyboardSettingsUntilItIsBound() throws {
        var opened = 0
        let status = StatusItemController(
            settings: FakeSettings(), openLauncher: {}, openSettings: {}, openKeyboardSettings: { opened += 1 })
        #expect(!status.isInstalled)
        let plain = status.makeMenu().items.map(\.title)
        #expect(plain == [AppStrings.openLauncher, AppStrings.settings, "", AppStrings.quit])

        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight")
        status.hotkeyWait = wait
        let menu = status.makeMenu()
        #expect(
            menu.items.map(\.title) == [
                "Spotlight Holds ⌘Space", "Open Keyboard Settings", "", AppStrings.openLauncher, AppStrings.settings,
                "",
                AppStrings.quit,
            ])
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[1].toolTip == SpotlightShortcutGuide.waitingNote(wait))
        let open = menu.items[1]
        let target = try #require(open.target as? NSObject)
        let action = try #require(open.action)
        target.perform(action, with: open)
        #expect(opened == 1)

        status.hotkeyWait = nil
        #expect(status.makeMenu().items.map(\.title) == plain)
        #expect(!status.isInstalled)
    }

    @Test func hudTitlesUseTitleCaseAndTheKeySymbols() {
        let combo = KeyCombo(.k, [.command, .option])
        #expect(AppStrings.hotkeyRefused(combo.displayString) == "Launcher Hotkey ⌥⌘K Is Taken")
        #expect(SpotlightShortcutGuide.nowOpens(KeyCombo(.space, .command)) == "⌘Space Now Opens \(Brand.name)")
    }
}
