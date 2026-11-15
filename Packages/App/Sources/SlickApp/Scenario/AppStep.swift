import Foundation
import Kit

/// A scenario step the app runs itself, for what the panel cannot show: what the fake workspace
/// recorded, what settings would have opened, the user's aliases and favorites, deep links and the
/// launcher hotkey. In a scenario file it is `{ "app": { ... } }` among Host's steps.
///
/// The actions run first, in the order listed here, then every check:
///
/// | Key | Type | What it does |
/// |---|---|---|
/// | `pressHotkey` | `true` | does what the launcher hotkey does, through its binding |
/// | `systemShortcuts` | strings | plays the macOS shortcuts that hold these combinations, as Spotlight holds `cmd+space` on a new Mac; `[]` turns them all off. The launcher notices on its own timer or when settings opens |
/// | `setFeatures` | object | turns each feature, by ID, on or off |
/// | `setSettings` | object | sets general settings: `themeName`, `visibleRows`, `inlineCompletion`, `panelSizing` or `launcherHotkey`; a name with a dot, such as `windows.showsLayoutName`, sets that feature setting as stored |
/// | `setHotkey` | object | gives `item` the hotkey `keys`, as settings does; `""` clears it |
/// | `copyAsOtherApp` | strings | another app copies each text in turn onto the run's private pasteboard |
/// | `pressKeys` | string | plays a press of whatever hotkey is registered for these keys, through the hotkey service |
/// | `link` | string | opens a deep link; `{scheme}` stands for the app's URL scheme |
/// | `linkOutcome` | string | the last link was `openedLauncher`, `asked`, `ran`, `openedSettings`, `openedFeatureSettings` or `refused` |
/// | `launched` | strings | the bundle IDs the workspace was asked to launch, exactly, oldest first |
/// | `opened` | strings | the URLs the workspace was asked to open, exactly, oldest first |
/// | `settings` | strings | what settings was asked to open, exactly: a pane name, `""` for the last pane, or `features/<id>` |
/// | `aliases` | object | each item ID has exactly this alias |
/// | `favorites` | strings | the favorites, exactly, in order |
/// | `hud` | string | the last HUD's title; `{brand}` stands for the app's name |
/// | `pasteboardText` | string | the text on the run's private pasteboard |
/// | `hotkeyBound` | bool | a launcher hotkey is bound |
/// | `hotkeyWaiting` | string | the owner of the macOS shortcut the launcher hotkey waits behind, `""` for none |
/// | `launcherHotkey` | string | the launcher hotkey bound now, as `KeyCombo` writes it |
/// | `hotkeyRefused` | bool | the last `setHotkey` was refused |
/// | `itemHotkeys` | object | each item ID has exactly this hotkey; `""` for none |
/// | `theme` | string | the selected theme, and the panel draws it |
/// | `featuresActive` | object | each feature, by ID, is active or not |
nonisolated struct AppStep: Decodable, Equatable, Sendable {
    var pressHotkey: Bool?
    var systemShortcuts: [String]?
    var setFeatures: [String: Bool]?
    var setSettings: [String: SettingValue]?
    var setHotkey: HotkeyRequest?
    var copyAsOtherApp: [String]?
    var pressKeys: String?
    var link: String?
    var linkOutcome: String?
    var launched: [String]?
    var opened: [String]?
    var settings: [String]?
    var aliases: [String: String]?
    var favorites: [String]?
    var hud: String?
    var pasteboardText: String?
    var hotkeyBound: Bool?
    var hotkeyWaiting: String?
    var launcherHotkey: String?
    var hotkeyRefused: Bool?
    var itemHotkeys: [String: String]?
    var theme: String?
    var featuresActive: [String: Bool]?

    /// An item hotkey to set.
    struct HotkeyRequest: Decodable, Equatable, Sendable {
        var item: String
        var keys: String
    }

    /// A setting's value as the file writes it.
    enum SettingValue: Decodable, Equatable, Sendable {
        case bool(Bool)
        case number(Int)
        case text(String)
        case none

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .none
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .number(value)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pressHotkey, systemShortcuts, setFeatures, setSettings, setHotkey, copyAsOtherApp, pressKeys, link
        case linkOutcome, launched, opened
        case settings
        case aliases, favorites, hud, pasteboardText, hotkeyBound, hotkeyWaiting, launcherHotkey, hotkeyRefused
        case itemHotkeys
        case theme, featuresActive
    }

    init(from decoder: any Decoder) throws {
        // Unknown keys make the file unreadable, as they do for Host's steps.
        let names = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown app key \"\(unknown)\""))
        }
        guard !names.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty app step"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pressHotkey = try container.decodeIfPresent(Bool.self, forKey: .pressHotkey)
        systemShortcuts = try container.decodeIfPresent([String].self, forKey: .systemShortcuts)
        setFeatures = try container.decodeIfPresent([String: Bool].self, forKey: .setFeatures)
        setSettings = try container.decodeIfPresent([String: SettingValue].self, forKey: .setSettings)
        setHotkey = try container.decodeIfPresent(HotkeyRequest.self, forKey: .setHotkey)
        copyAsOtherApp = try container.decodeIfPresent([String].self, forKey: .copyAsOtherApp)
        pressKeys = try container.decodeIfPresent(String.self, forKey: .pressKeys)
        link = try container.decodeIfPresent(String.self, forKey: .link)
        linkOutcome = try container.decodeIfPresent(String.self, forKey: .linkOutcome)
        launched = try container.decodeIfPresent([String].self, forKey: .launched)
        opened = try container.decodeIfPresent([String].self, forKey: .opened)
        settings = try container.decodeIfPresent([String].self, forKey: .settings)
        aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites)
        hud = try container.decodeIfPresent(String.self, forKey: .hud)
        pasteboardText = try container.decodeIfPresent(String.self, forKey: .pasteboardText)
        hotkeyBound = try container.decodeIfPresent(Bool.self, forKey: .hotkeyBound)
        hotkeyWaiting = try container.decodeIfPresent(String.self, forKey: .hotkeyWaiting)
        launcherHotkey = try container.decodeIfPresent(String.self, forKey: .launcherHotkey)
        hotkeyRefused = try container.decodeIfPresent(Bool.self, forKey: .hotkeyRefused)
        itemHotkeys = try container.decodeIfPresent([String: String].self, forKey: .itemHotkeys)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        featuresActive = try container.decodeIfPresent([String: Bool].self, forKey: .featuresActive)
    }

    /// The expected HUD title with the app's name put in.
    var resolvedHUD: String? {
        hud?.replacingOccurrences(of: "{brand}", with: Brand.name)
    }

    /// The link with the app's scheme put in.
    var resolvedLink: String? {
        link?.replacingOccurrences(of: "{scheme}", with: Brand.urlScheme)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
