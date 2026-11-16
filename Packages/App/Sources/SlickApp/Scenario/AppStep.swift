import Foundation
import Kit

/// A scenario step the app runs itself, for what the panel cannot show: what the fake workspace
/// recorded, what settings would have opened, the user's aliases and favorites, deep links, the
/// launcher hotkey, the run's clock and the app in front. In a scenario file it is
/// `{ "app": { ... } }` among Host's steps.
///
/// The actions run first, in the order listed here, then every check:
///
/// | Key | Type | What it does |
/// |---|---|---|
/// | `setTime` | string | moves the run's clock forward to this moment, such as `2026-11-16T09:00:00Z`; the run's clock reads UTC |
/// | `advanceClock` | number | moves the run's clock forward by this many seconds, as for the wait on the page that asks before a link runs a command |
/// | `sessionStart` | `true` | plays a wake or an unlock on the run's system context |
/// | `frontApp` | string | puts the app with this bundle ID in front, for the system context and the workspace |
/// | `pressHotkey` | `true` | does what the launcher hotkey does, through its binding |
/// | `systemShortcuts` | strings | plays the macOS shortcuts that hold these combinations, as Spotlight holds `cmd+space` on a new Mac; `[]` turns them all off. The launcher notices on its own timer or when settings opens |
/// | `setFeatures` | object | turns each feature, by ID, on or off |
/// | `setSettings` | object | sets general settings: `themeName`, `visibleRows`, `inlineCompletion`, `panelSizing`, `launcherHotkey` or `tabCommand`; a name with a dot, such as `windows.showsLayoutName`, sets that feature setting as stored |
/// | `setHotkey` | object | gives `item` the hotkey `keys`, as settings does; `""` clears it |
/// | `setFallbacks` | object | as the root search pane does: `order` lists fallback command IDs in the new order, `on` turns each by ID on or off |
/// | `onboarding` | object | plays onboarding's Optional Features step: `features` sets each switch by feature ID, then Continue applies them |
/// | `copyAsOtherApp` | strings | another app copies each text in turn onto the run's private pasteboard |
/// | `makeFiles` | object | writes each made-up text to its path in the run's home folder, which shows as `~`; a path that climbs out fails |
/// | `chooseFiles` | strings | the next open dialog hands back these paths in the run's home folder, as if the user chose them; with nothing queued a dialog cancels |
/// | `pressKeys` | string | plays a press of whatever hotkey is registered for these keys, through the hotkey service |
/// | `link` | string | opens a deep link; `{scheme}` stands for the app's URL scheme |
/// | `waitForRow` | string | waits until a row or cell with this title shows on the top page, 5 s at most, for a page that fills itself after its own read |
/// | `select` | string | selects the row or cell with this title on the top page, with Down and Up as a person would |
/// | `waitUntilReady` | `true` | waits until every feature finished its loading and root search is ready, as runs do before their first step unless the file says `startsBeforeReady` |
/// | `openSettings` | string | opens the real settings window on this pane at a fixed place, without key status and without saving its frame |
/// | `captureSettings` | string | writes `captures/<name>.png` of the settings window `openSettings` opened |
/// | `closeSettings` | `true` | closes that window |
/// | `openOnboarding` | string | opens the real onboarding window on this step, `welcome`, `hotkey`, `features`, `permissions`, `theme` or `done`, at the place `openSettings` uses, without key status; it applies no switch and marks nothing done |
/// | `captureOnboarding` | string | writes `captures/<name>.png` of the onboarding window `openOnboarding` opened |
/// | `closeOnboarding` | `true` | closes that window |
/// | `linkOutcome` | string | the last link was `openedLauncher`, `asked`, `ran`, `openedSettings`, `openedFeatureSettings` or `refused` |
/// | `launched` | strings | the bundle IDs the workspace was asked to launch, exactly, oldest first |
/// | `opened` | strings | the URLs the workspace was asked to open, exactly, oldest first |
/// | `settings` | strings | what settings was asked to open, exactly: a pane name, `""` for the last pane, or `features/<id>` |
/// | `aliases` | object | each item ID has exactly this alias |
/// | `favorites` | strings | the favorites, exactly, in order |
/// | `hud` | string | the last HUD's title; `{brand}` stands for the app's name |
/// | `pasteboardText` | string | the text on the run's private pasteboard |
/// | `homeFiles` | strings | each of these paths exists in the run's home folder |
/// | `openDialogs` | number | how many open dialogs were asked for in the run so far |
/// | `hotkeyBound` | bool | a launcher hotkey is bound |
/// | `hotkeyWaiting` | string | the owner of the macOS shortcut the launcher hotkey waits behind, `""` for none |
/// | `launcherHotkey` | string | the launcher hotkey bound now, as `KeyCombo` writes it |
/// | `hotkeyRefused` | bool | the last `setHotkey` was refused |
/// | `itemHotkeys` | object | each item ID has exactly this hotkey; `""` for none |
/// | `theme` | string | the selected theme, and the panel draws it |
/// | `featuresActive` | object | each feature, by ID, is active or not |
/// | `fallbacksOn` | strings | the IDs of the fallbacks that are on, in the order root search shows them |
nonisolated struct AppStep: Decodable, Equatable, Sendable {
    var setTime: Date?
    var advanceClock: Double?
    var sessionStart: Bool?
    var frontApp: String?
    var pressHotkey: Bool?
    var systemShortcuts: [String]?
    var setFeatures: [String: Bool]?
    var setSettings: [String: SettingValue]?
    var setHotkey: HotkeyRequest?
    var setFallbacks: FallbackRequest?
    var onboarding: OnboardingRequest?
    var copyAsOtherApp: [String]?
    var makeFiles: [String: String]?
    var chooseFiles: [String]?
    var pressKeys: String?
    var link: String?
    var waitForRow: String?
    var select: String?
    var waitUntilReady: Bool?
    var openSettings: String?
    var captureSettings: String?
    var closeSettings: Bool?
    var openOnboarding: String?
    var captureOnboarding: String?
    var closeOnboarding: Bool?
    var linkOutcome: String?
    var launched: [String]?
    var opened: [String]?
    var settings: [String]?
    var aliases: [String: String]?
    var favorites: [String]?
    var hud: String?
    var pasteboardText: String?
    var homeFiles: [String]?
    var openDialogs: Int?
    var hotkeyBound: Bool?
    var hotkeyWaiting: String?
    var launcherHotkey: String?
    var hotkeyRefused: Bool?
    var itemHotkeys: [String: String]?
    var theme: String?
    var featuresActive: [String: Bool]?
    var fallbacksOn: [String]?

    /// An item hotkey to set.
    struct HotkeyRequest: Decodable, Equatable, Sendable {
        var item: String
        var keys: String
    }

    /// Fallback choices to make, as the root search pane makes them.
    struct FallbackRequest: Decodable, Equatable, Sendable {
        /// Fallback command IDs in the new order.
        var order: [String]?
        /// Each fallback command ID turned on or off.
        var on: [String: Bool]?
    }

    /// The switches of onboarding's Optional Features step, by feature ID, as the user leaves them.
    struct OnboardingRequest: Decodable, Equatable, Sendable {
        var features: [String: Bool]
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
        case setTime, advanceClock, sessionStart, frontApp
        case pressHotkey, systemShortcuts, setFeatures, setSettings, setHotkey, setFallbacks, onboarding
        case copyAsOtherApp, makeFiles, chooseFiles, pressKeys, link
        case waitForRow, select, waitUntilReady, openSettings, captureSettings, closeSettings
        case openOnboarding, captureOnboarding, closeOnboarding
        case linkOutcome, launched, opened
        case settings
        case aliases, favorites, hud, pasteboardText, homeFiles, openDialogs
        case hotkeyBound, hotkeyWaiting, launcherHotkey, hotkeyRefused
        case itemHotkeys
        case theme, featuresActive, fallbacksOn
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
        if let text = try container.decodeIfPresent(String.self, forKey: .setTime) {
            guard let date = try? Date.ISO8601FormatStyle().parse(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .setTime, in: container, debugDescription: "cannot read the time \(text)")
            }
            setTime = date
        }
        advanceClock = try container.decodeIfPresent(Double.self, forKey: .advanceClock)
        if let seconds = advanceClock, !(seconds > 0) {
            throw DecodingError.dataCorruptedError(
                forKey: .advanceClock, in: container, debugDescription: "advanceClock must be more than 0")
        }
        sessionStart = try container.decodeIfPresent(Bool.self, forKey: .sessionStart)
        frontApp = try container.decodeIfPresent(String.self, forKey: .frontApp)
        pressHotkey = try container.decodeIfPresent(Bool.self, forKey: .pressHotkey)
        systemShortcuts = try container.decodeIfPresent([String].self, forKey: .systemShortcuts)
        setFeatures = try container.decodeIfPresent([String: Bool].self, forKey: .setFeatures)
        setSettings = try container.decodeIfPresent([String: SettingValue].self, forKey: .setSettings)
        setHotkey = try container.decodeIfPresent(HotkeyRequest.self, forKey: .setHotkey)
        setFallbacks = try container.decodeIfPresent(FallbackRequest.self, forKey: .setFallbacks)
        onboarding = try container.decodeIfPresent(OnboardingRequest.self, forKey: .onboarding)
        copyAsOtherApp = try container.decodeIfPresent([String].self, forKey: .copyAsOtherApp)
        makeFiles = try container.decodeIfPresent([String: String].self, forKey: .makeFiles)
        chooseFiles = try container.decodeIfPresent([String].self, forKey: .chooseFiles)
        pressKeys = try container.decodeIfPresent(String.self, forKey: .pressKeys)
        link = try container.decodeIfPresent(String.self, forKey: .link)
        waitForRow = try container.decodeIfPresent(String.self, forKey: .waitForRow)
        select = try container.decodeIfPresent(String.self, forKey: .select)
        waitUntilReady = try container.decodeIfPresent(Bool.self, forKey: .waitUntilReady)
        openSettings = try container.decodeIfPresent(String.self, forKey: .openSettings)
        captureSettings = try container.decodeIfPresent(String.self, forKey: .captureSettings)
        closeSettings = try container.decodeIfPresent(Bool.self, forKey: .closeSettings)
        openOnboarding = try container.decodeIfPresent(String.self, forKey: .openOnboarding)
        captureOnboarding = try container.decodeIfPresent(String.self, forKey: .captureOnboarding)
        closeOnboarding = try container.decodeIfPresent(Bool.self, forKey: .closeOnboarding)
        linkOutcome = try container.decodeIfPresent(String.self, forKey: .linkOutcome)
        launched = try container.decodeIfPresent([String].self, forKey: .launched)
        opened = try container.decodeIfPresent([String].self, forKey: .opened)
        settings = try container.decodeIfPresent([String].self, forKey: .settings)
        aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites)
        hud = try container.decodeIfPresent(String.self, forKey: .hud)
        pasteboardText = try container.decodeIfPresent(String.self, forKey: .pasteboardText)
        homeFiles = try container.decodeIfPresent([String].self, forKey: .homeFiles)
        openDialogs = try container.decodeIfPresent(Int.self, forKey: .openDialogs)
        hotkeyBound = try container.decodeIfPresent(Bool.self, forKey: .hotkeyBound)
        hotkeyWaiting = try container.decodeIfPresent(String.self, forKey: .hotkeyWaiting)
        launcherHotkey = try container.decodeIfPresent(String.self, forKey: .launcherHotkey)
        hotkeyRefused = try container.decodeIfPresent(Bool.self, forKey: .hotkeyRefused)
        itemHotkeys = try container.decodeIfPresent([String: String].self, forKey: .itemHotkeys)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        featuresActive = try container.decodeIfPresent([String: Bool].self, forKey: .featuresActive)
        fallbacksOn = try container.decodeIfPresent([String].self, forKey: .fallbacksOn)
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
