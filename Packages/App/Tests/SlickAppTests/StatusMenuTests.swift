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

        let wait = LauncherHotkeyWait(combo: KeyCombo(.upArrow, .control), owner: "Mission Control")
        status.hotkeyWait = wait
        let menu = status.makeMenu()
        #expect(
            menu.items.map(\.title) == [
                "Mission Control Uses ⌃↑", "Open Keyboard Settings", "", AppStrings.openLauncher,
                AppStrings.settings, "", AppStrings.quit,
            ])
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[1].toolTip == SpotlightShortcutGuide.paneCannotTurnOffNote(wait))
        let open = menu.items[1]
        let target = try #require(open.target as? NSObject)
        let action = try #require(open.action)
        target.perform(action, with: open)
        #expect(opened == 1)

        status.hotkeyWait = nil
        #expect(status.makeMenu().items.map(\.title) == plain)
        #expect(!status.isInstalled)
    }

    @Test func offersToTurnSpotlightOffAndThenToOpenKeyboardSettingsAfterAFailedTry() throws {
        var turnOffs = 0
        var opened = 0
        let status = StatusItemController(
            settings: FakeSettings(), openLauncher: {}, openSettings: {}, openKeyboardSettings: { opened += 1 },
            turnOffShortcut: { turnOffs += 1 })
        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight", canTurnOff: true)
        status.hotkeyWait = wait
        let menu = status.makeMenu()
        #expect(menu.items.map(\.title).prefix(3) == ["Spotlight Uses ⌘Space", "Turn Off Spotlight's Shortcut", ""])
        #expect(menu.items[1].toolTip == "⌘Space opens Spotlight, not \(Brand.name).")
        let item = menu.items[1]
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        target.perform(action, with: item)
        #expect(turnOffs == 1)
        #expect(opened == 0)

        status.hotkeyWait = LauncherHotkeyWait(
            combo: KeyCombo(.space, .command), owner: "Spotlight", turnOffFailed: true)
        let after = status.makeMenu()
        #expect(after.items.map(\.title).prefix(2) == ["Spotlight Uses ⌘Space", "Open Keyboard Settings"])
        #expect(after.items[1].toolTip?.hasPrefix("\(Brand.name) could not turn off Spotlight's shortcut.") == true)
    }

    @Test func hudTitlesUseTitleCaseAndTheKeySymbols() {
        let combo = KeyCombo(.k, [.command, .option])
        #expect(AppStrings.hotkeyRefused(combo.displayString) == "Launcher Hotkey ⌥⌘K Is Taken")
        #expect(SpotlightShortcutGuide.nowOpens(KeyCombo(.space, .command)) == "⌘Space Now Opens \(Brand.name)")
        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight", canTurnOff: true)
        #expect(SpotlightShortcutGuide.turnOffFailedTitle(wait) == "Could Not Turn Off Spotlight's Shortcut")
    }
}
