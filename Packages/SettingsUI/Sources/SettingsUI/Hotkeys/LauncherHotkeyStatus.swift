import Foundation
import Kit

/// What settings and onboarding know about the launcher hotkey's binding. App's launcher hotkey
/// implements it. Settings reads it, and asks for a fresh check when one of its windows opens.
public protocol LauncherHotkeyStatus: AnyObject, Sendable {
    /// The combination bound for the launcher now, or nil.
    var bound: KeyCombo? { get }

    /// The stored combination while an enabled macOS shortcut uses it, with that shortcut's owner.
    /// Nothing is bound for the launcher then. Nil while the hotkey is bound, cleared or refused for
    /// another reason.
    var wait: LauncherHotkeyWait? { get }

    /// Sent when ``bound``, ``wait`` or ``turnedOffShortcut`` changes.
    var statusChanges: ChangeSignal { get }

    /// Checks the system's shortcuts again now and binds the hotkey if its combination is free.
    /// Cheap, and does nothing while the hotkey is bound.
    func checkNow()

    /// Turns off the macOS shortcut the hotkey waits for, when ``LauncherHotkeyWait/canTurnOff``,
    /// and binds the hotkey. Only the person's Continue on onboarding's hotkey step and the buttons
    /// that say so call it. True when the hotkey is bound afterwards. After a failed try the wait
    /// says ``LauncherHotkeyWait/turnOffFailed``. The default does nothing and returns false.
    func turnOffSystemShortcut() async -> Bool

    /// The Spotlight shortcut the app turned off for the launcher, while the launcher hotkey uses
    /// other keys and that shortcut is still off. Nil otherwise. The default is nil.
    var turnedOffShortcut: TurnedOffShortcut? { get }

    /// Turns ``turnedOffShortcut`` back on, the same way it was turned off, and forgets it. True
    /// when it is on again. The default does nothing and returns false.
    func turnShortcutBackOn() async -> Bool
}

extension LauncherHotkeyStatus {
    public func turnOffSystemShortcut() async -> Bool { false }

    public var turnedOffShortcut: TurnedOffShortcut? { nil }

    public func turnShortcutBackOn() async -> Bool { false }
}

/// A launcher hotkey that waits until a macOS shortcut no longer uses its combination.
public struct LauncherHotkeyWait: Hashable, Sendable {
    /// The stored combination.
    public var combo: KeyCombo
    /// Whose shortcut uses it, such as "Spotlight".
    public var owner: String
    /// True when the app can turn that shortcut off itself, as it can Spotlight's own two.
    public var canTurnOff: Bool
    /// True after the app tried to turn the shortcut off and the keys were still taken. The app does
    /// not try again for this wait, so ``canTurnOff`` is false then.
    public var turnOffFailed: Bool

    public init(combo: KeyCombo, owner: String, canTurnOff: Bool = false, turnOffFailed: Bool = false) {
        self.combo = combo
        self.owner = owner
        self.canTurnOff = canTurnOff
        self.turnOffFailed = turnOffFailed
    }

    /// True when Spotlight uses Command-Space, as on a new Mac.
    public var isSpotlight: Bool {
        combo == SpotlightShortcutGuide.combo && owner == SpotlightShortcutGuide.owner
    }
}

/// A Spotlight shortcut the app turned off for the launcher hotkey.
public struct TurnedOffShortcut: Hashable, Sendable {
    /// The keys it used.
    public var combo: KeyCombo
    /// Whose shortcut it is, such as "Spotlight".
    public var owner: String
    /// When the app turned it off.
    public var date: Date

    public init(combo: KeyCombo, owner: String, date: Date) {
        self.combo = combo
        self.owner = owner
        self.date = date
    }
}

/// What onboarding, the General pane and the menu bar menu say about a macOS shortcut that uses
/// the launcher's keys, in the words macOS 27 uses.
///
/// The names come from the system's own English strings: "System Settings" from the app's
/// `CFBundleDisplayName`, "Keyboard" from the Keyboard pane's `InfoPlist.loctable`, "Keyboard
/// Shortcuts…" from its `Localizable.loctable`, and "Spotlight", "Show Spotlight search" and "Show
/// Finder search window" from its `DefaultShortcutsTable.loctable`, all under
/// `/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex`.
public enum SpotlightShortcutGuide {
    /// The combination Spotlight uses on a new Mac, and the launcher's default.
    public static let combo = KeyCombo(.space, .command)
    /// The owner Platform names for Spotlight's shortcuts.
    public static let owner = "Spotlight"

    /// The Keyboard pane's ID, from its extension's `CFBundleIdentifier`.
    public static let keyboardPaneID = "com.apple.Keyboard-Settings.extension"
    /// The anchor in the Keyboard pane that System Settings titles "Spotlight keyboard shortcuts",
    /// from the pane's `Keyboard.searchTerms`.
    public static let spotlightAnchor = "Spotlight"

    /// The deep link to the Spotlight keyboard shortcuts in the Keyboard pane, in the form the Apps
    /// feature opens panes with. A macOS that does not know the anchor opens the Keyboard pane.
    public static var keyboardSettingsURL: URL {
        URL(string: "x-apple.systempreferences:\(keyboardPaneID)?\(spotlightAnchor)")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }

    /// The button that opens it.
    public static let openButton = "Open Keyboard Settings"

    /// The button that turns the shortcut off, in the General pane and the menu bar menu.
    public static func turnOffButton(_ wait: LauncherHotkeyWait) -> String {
        "Turn Off \(wait.owner)'s Shortcut"
    }

    /// The name of the switch in Keyboard Shortcuts that turns the shortcut off: the Finder search
    /// window's for its default keys, Spotlight search's otherwise.
    static func systemSwitch(_ combo: KeyCombo) -> String {
        combo == KeyCombo(.space, [.command, .option]) ? "Show Finder search window" : "Show Spotlight search"
    }

    // MARK: Onboarding's hotkey step

    /// What Continue will do, while the app can turn the shortcut off.
    public static func takeOverNote(_ wait: LauncherHotkeyWait) -> String {
        let keys = wait.combo.displayString
        return "\(keys) opens \(wait.owner) right now. When you press Continue, \(Brand.name) turns off "
            + "\(wait.owner)'s shortcut. Then \(keys) opens \(Brand.name)."
    }

    /// The smaller line under ``takeOverNote(_:)``: how to keep the shortcut, and how to undo it.
    public static func takeOverFootnote(_ wait: LauncherHotkeyWait) -> String {
        "To keep \(wait.combo.displayString) for \(wait.owner), click the field above and press other keys. To turn "
            + "\(wait.owner)'s shortcut back on later, open System Settings, Keyboard, Keyboard Shortcuts, Spotlight."
    }

    /// What to do while a shortcut the app cannot turn off uses the keys, such as Mission Control's.
    public static func cannotTurnOffNote(_ wait: LauncherHotkeyWait) -> String {
        "\(paneCannotTurnOffNote(wait)) You can also click the field above and press other keys."
    }

    /// What to do after the app tried to turn the shortcut off and could not.
    public static func failedNote(_ wait: LauncherHotkeyWait) -> String {
        "\(Brand.name) could not turn off \(wait.owner)'s shortcut. Turn off \(systemSwitch(wait.combo)) in System "
            + "Settings, under Keyboard, Keyboard Shortcuts, Spotlight."
    }

    /// The line that says the launcher is still waiting for its keys.
    public static func waitingLine(_ wait: LauncherHotkeyWait) -> String {
        "\(Brand.name) waits until \(wait.combo.displayString) is free."
    }

    /// The line under the recorder while nothing else uses the keys.
    public static let otherKeysNote = "To use another hotkey, click the field and press the keys."

    /// The line that turns green the moment the combination is free and bound.
    public static func freedLine(_ combo: KeyCombo) -> String {
        "\(combo.displayString) opens \(Brand.name) now."
    }

    // MARK: Done step

    /// The done step's line while the hotkey is bound.
    public static func doneBound(_ combo: KeyCombo) -> String {
        "Press \(combo.displayString) to open \(Brand.name)."
    }

    /// The done step's line while a macOS shortcut still uses the keys.
    public static func doneWaiting(_ wait: LauncherHotkeyWait) -> String {
        "\(wait.combo.displayString) still opens \(wait.owner). Click the bolt in the menu bar to open \(Brand.name) "
            + "for now."
    }

    /// The done step's line with no hotkey.
    public static let doneNoHotkey =
        "Click the bolt in the menu bar to open \(Brand.name). You can set a hotkey in Settings."

    // MARK: General pane

    /// The General pane's line while the app can turn the shortcut off.
    public static func paneNote(_ wait: LauncherHotkeyWait) -> String {
        "\(wait.combo.displayString) opens \(wait.owner), not \(Brand.name)."
    }

    /// The General pane's line while a shortcut the app cannot turn off uses the keys.
    public static func paneCannotTurnOffNote(_ wait: LauncherHotkeyWait) -> String {
        let keys = wait.combo.displayString
        return "\(wait.owner) uses \(keys) right now. To open \(Brand.name) with \(keys), turn off that shortcut in "
            + "System Settings, under Keyboard."
    }

    /// The General pane's line about a shortcut the app turned off, once the launcher uses other
    /// keys.
    public static func turnedOffNote(_ shortcut: TurnedOffShortcut) -> String {
        "\(Brand.name) turned off \(shortcut.owner)'s \(shortcut.combo.displayString) shortcut."
    }

    /// The button that turns it back on.
    public static let turnBackOnButton = "Turn It Back On"

    // MARK: App

    /// The HUD the app shows the moment the combination is free and bound.
    public static func nowOpens(_ combo: KeyCombo) -> String {
        "\(combo.displayString) Now Opens \(Brand.name)"
    }

    /// The HUD the app shows when the menu bar menu's Turn Off could not free the keys.
    public static func turnOffFailedTitle(_ wait: LauncherHotkeyWait) -> String {
        "Could Not Turn Off \(wait.owner)'s Shortcut"
    }

    /// The menu bar item's line while a macOS shortcut uses the keys.
    public static func menuTitle(_ wait: LauncherHotkeyWait) -> String {
        "\(wait.owner) Uses \(wait.combo.displayString)"
    }

    /// The sentence a menu item about the wait shows as its tooltip.
    public static func menuToolTip(_ wait: LauncherHotkeyWait) -> String {
        if wait.canTurnOff { return paneNote(wait) }
        if wait.turnOffFailed { return failedNote(wait) }
        return paneCannotTurnOffNote(wait)
    }
}
