import Foundation
import Kit
import Testing

@testable import SettingsUI

/// Checks the guide's words and link against the system's own files. It reads only property lists
/// under /System and opens nothing.
@Suite(.timeLimit(.minutes(1))) struct SpotlightGuideTests {
    nonisolated static let keyboard = URL(
        filePath: "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents")

    /// The English table of a `.loctable` file, or nil when the file is missing.
    nonisolated static func english(_ name: String) -> [String: Any]? {
        let url = keyboard.appending(path: "Resources/\(name).loctable")
        guard let data = try? Data(contentsOf: url),
            let tables = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return tables["en"] as? [String: Any]
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: keyboard.path)))
    func theStepsUseTheSystemsOwnWords() throws {
        let names = try #require(Self.english("InfoPlist"))
        let localizable = try #require(Self.english("Localizable"))
        let shortcuts = try #require(Self.english("DefaultShortcutsTable"))
        let pane = try #require(names["CFBundleDisplayName"] as? String)
        let button = try #require(localizable["Keyboard Shortcuts…"] as? String)
        let row = try #require(shortcuts["Spotlight"] as? String)
        let checkbox = try #require(shortcuts["Show Spotlight search"] as? String)
        let steps = SpotlightShortcutGuide.steps
        #expect(steps[0] == "Open \(pane) in System Settings.")
        #expect(steps[1] == "Click \(button), then \(row).")
        #expect(steps[2] == "Turn off \(checkbox).")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: keyboard.path)))
    func theLinkNamesTheKeyboardPaneAndItsSpotlightAnchor() throws {
        let info = try #require(NSDictionary(contentsOf: Self.keyboard.appending(path: "Info.plist")) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == SpotlightShortcutGuide.keyboardPaneID)
        let attributes = info["EXAppExtensionAttributes"] as? [String: Any]
        let settings = attributes?["SettingsExtensionAttributes"] as? [String: Any]
        #expect(settings?["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true)
        let file = try #require(settings?["searchTermsFileName"] as? String)
        let terms = try #require(
            NSDictionary(contentsOf: Self.keyboard.appending(path: "Resources/en.lproj/\(file).searchTerms"))
                as? [String: Any])
        #expect(terms[SpotlightShortcutGuide.spotlightAnchor] != nil)
        #expect(
            SpotlightShortcutGuide.keyboardSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Spotlight")
    }
}
