import Foundation
import Kit

/// What settings and onboarding know about the launcher hotkey's binding. App's launcher hotkey
/// implements it. Settings reads it, and asks for a fresh check when one of its windows opens.
public protocol LauncherHotkeyStatus: AnyObject, Sendable {
    /// The combination bound for the launcher now, or nil.
    var bound: KeyCombo? { get }

    /// The stored combination while an enabled macOS shortcut holds it, with that shortcut's owner.
    /// Nothing is bound for the launcher then. Nil while the hotkey is bound, cleared or refused for
    /// another reason.
    var wait: LauncherHotkeyWait? { get }

    /// Sent when ``bound`` or ``wait`` changes.
    var statusChanges: ChangeSignal { get }

    /// Checks the system's shortcuts again now and binds the hotkey if its combination is free.
    /// Cheap, and does nothing while the hotkey is bound.
    func checkNow()
}

/// A launcher hotkey that waits for a macOS shortcut to let go of its combination.
public struct LauncherHotkeyWait: Hashable, Sendable {
    /// The stored combination.
    public var combo: KeyCombo
    /// Who holds it, such as "Spotlight".
    public var owner: String

    public init(combo: KeyCombo, owner: String) {
        self.combo = combo
        self.owner = owner
    }

    /// True when Spotlight holds Command-Space, as on a new Mac.
    public var isSpotlight: Bool {
        combo == SpotlightShortcutGuide.combo && owner == SpotlightShortcutGuide.owner
    }
}

/// How to free Command-Space from Spotlight, in the words macOS 27 uses.
///
/// The names come from the system's own English strings: "System Settings" from the app's
/// `CFBundleDisplayName`, "Keyboard" from the Keyboard pane's `InfoPlist.loctable`, "Keyboard
/// Shortcuts…" from its `Localizable.loctable`, and "Spotlight" and "Show Spotlight search" from its
/// `DefaultShortcutsTable.loctable`, all under
/// `/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex`.
public enum SpotlightShortcutGuide {
    /// The combination Spotlight holds on a new Mac, and the launcher's default.
    public static let combo = KeyCombo(.space, .command)
    /// The owner Platform names for that combination.
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

    /// The three steps that turn Spotlight's shortcut off.
    public static let steps = [
        "Open Keyboard in System Settings.",
        "Click Keyboard Shortcuts…, then Spotlight.",
        "Turn off Show Spotlight search.",
    ]

    /// The sentence that says the launcher hotkey waits, and what frees it.
    public static func waitingNote(_ wait: LauncherHotkeyWait) -> String {
        let combo = wait.combo.displayString
        if wait.owner == owner {
            return
                "Spotlight holds \(combo), so it does not open \(Brand.name) yet. Turn off Spotlight's shortcut in System Settings, and it will."
        }
        return
            "\(wait.owner) holds \(combo), so it does not open \(Brand.name) yet. Turn off that shortcut in System Settings, under Keyboard, and it will."
    }

    /// The line that says the launcher is still waiting.
    public static func waitingLine(_ wait: LauncherHotkeyWait) -> String {
        "Waiting for \(wait.owner) to let go of \(wait.combo.displayString)"
    }

    /// The line that turns green the moment the combination is free.
    public static func freedLine(_ combo: KeyCombo) -> String {
        "\(combo.displayString) opens \(Brand.name) now."
    }

    /// The HUD the app shows the moment the combination is free and bound.
    public static func nowOpens(_ combo: KeyCombo) -> String {
        "\(combo.displayString) Now Opens \(Brand.name)"
    }

    /// The menu bar item's line while the hotkey waits.
    public static func menuTitle(_ wait: LauncherHotkeyWait) -> String {
        "\(wait.owner) Holds \(wait.combo.displayString)"
    }
}
