import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI

/// A panel controller over the test runtime, fake root search and fake icons, placed far off every
/// screen and shown without key status, so nothing appears on the desktop or takes the keyboard.
@MainActor final class PanelFixture {
    static let offscreen = CGRect(x: -20000, y: -20000, width: 1600, height: 1000)

    let runtime: RuntimeFixture
    let root: FakeRootSource
    let icons = FakeIconProvider()
    let hud = RecordingHUD()
    let panel: PanelController
    let opened = Box<[ItemID]>([])
    let copied = Box<[ItemID]>([])

    private init(runtime: RuntimeFixture, root: FakeRootSource, themes: ThemeStore?) {
        self.runtime = runtime
        self.root = root
        let surface = LauncherSurface(visibleFrame: Self.offscreen)
        surface.panel.appearance = NSAppearance(named: .aqua)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        panel = PanelController(
            runtime: runtime.runtime, rootSource: root, icons: icons, themes: themes, surface: surface, hud: hud)
        panel.summoner.takesKeyStatus = false
        panel.summoner.followsPointerScreen = false
        let opened = opened
        let copied = copied
        root.rowActions = { row in
            [
                Action("Open", id: "open") { _ in
                    opened.value.append(row.id)
                    return .close()
                },
                Action("Copy", id: "copy") { _ in
                    copied.value.append(row.id)
                    return .keepOpen
                },
                Action("Reveal", id: "reveal", shortcut: KeyCombo(.r, .command)) { _ in .keepOpen },
            ]
        }
    }

    /// A started runtime, with `features` besides the test features, and a panel prewarmed and
    /// summoned. The panel draws in light, through the appearance setting, unless `settings` says
    /// otherwise, so what a test sees does not depend on the Mac's appearance.
    static func make(
        rows: [Row] = SampleRows.all, fallbacks: [Row] = [], settings: [String: SettingStorage] = [:],
        themes: ThemeStore? = nil, summon: Bool = true, features: [FeatureRegistration] = []
    ) async -> PanelFixture {
        _ = NSApplication.shared
        let runtime = RuntimeFixture()
        HostSettings.settings(runtime.fakes.settings)[HostSettings.appearance] = .light
        for (name, value) in settings { runtime.fakes.settings.set(value, for: HostSettings.namespace + "." + name) }
        await runtime.start(more: features)
        let fixture = PanelFixture(
            runtime: runtime, root: FakeRootSource(rows: rows, fallbacks: fallbacks), themes: themes)
        fixture.panel.prewarm()
        if summon { fixture.panel.summon() }
        return fixture
    }

    var field: QueryField { panel.surface.queryField }

    /// Types the full text, as the field reports it after a keystroke.
    func type(_ text: String) {
        field.text = text
        panel.queryField(field, didChangeText: text)
    }

    @discardableResult
    func press(_ command: QueryCommand) -> Bool {
        panel.queryField(field, perform: command)
    }

    @discardableResult
    func command(_ key: String, _ modifiers: KeyChord.Modifiers = .command) -> Bool {
        press(.chord(KeyChord(key, modifiers)))
    }

    var rootTitles: [String] { panel.rootPage.list.content.sections.flatMap { $0.rows.map(\.title) } }

    func titles(_ list: ResultListView) -> [String] { list.content.sections.flatMap { $0.rows.map(\.title) } }

    var topList: ListPageController? { panel.top as? ListPageController }

    /// A Return key event for a card, made locally and never posted to the system.
    static func spaceKey() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }

    static func returnKey() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    /// A Tab key event for a card, made locally and never posted to the system.
    static func tabKey() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
    }

    func close() {
        panel.summoner.dismiss(returnFocus: false)
        panel.surface.panel.close()
    }
}
