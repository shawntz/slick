import Foundation
import Kit
import KitTesting
import Testing

@Suite("Settings")
struct SettingsTests {
    nonisolated enum Tone: String, CaseIterable, SettingValue {
        case none, light, dark
    }

    nonisolated struct Window: CodableSettingValue {
        var width: Int
        var height: Int
    }

    static let enabled = SettingKey("enabled", default: true)
    static let tone = SettingKey("tone", default: Tone.none)
    static let hotkey = SettingKey<KeyCombo?>("hotkey", default: KeyCombo(.space, .option))
    static let size = SettingKey("size", default: Window(width: 800, height: 500))
    static let apps = SettingKey("apps", default: [String]())

    private let fakes = FakeServices()
    private var settings: FeatureSettings { fakes.context(featureID: "demo").settings }

    @Test func readsDefaultsUntilSet() {
        #expect(settings[Self.enabled])
        #expect(settings[Self.tone] == .none)
        #expect(settings[Self.hotkey] == KeyCombo(.space, .option))
    }

    @Test func storesTypedValuesUnderTheFeaturePrefix() {
        settings[Self.tone] = .dark
        settings[Self.apps] = ["com.example.one"]
        settings[Self.size] = Window(width: 1, height: 2)
        #expect(settings[Self.tone] == .dark)
        #expect(settings[Self.apps] == ["com.example.one"])
        #expect(settings[Self.size] == Window(width: 1, height: 2))
        #expect(fakes.settings.values["demo.tone"] == .string("dark"))
    }

    @Test func aClearedOptionalDiffersFromUnset() {
        settings[Self.hotkey] = nil
        #expect(settings[Self.hotkey] == nil)
        #expect(fakes.settings.values["demo.hotkey"] == .empty)
        settings.reset(Self.hotkey)
        #expect(settings[Self.hotkey] == KeyCombo(.space, .option))
    }

    @Test func aValueOfTheWrongTypeReadsAsTheDefault() {
        fakes.settings.set(.int(3), for: "demo.tone")
        #expect(settings[Self.tone] == .none)
    }

    @Test func changesArriveTyped() async {
        var changes = settings.changes(of: Self.tone).makeAsyncIterator()
        settings[Self.tone] = .light
        #expect(await changes.next() == .light)
        settings.reset(Self.tone)
        #expect(await changes.next() == Tone.none)
    }

    @Test func oneStreamReportsChangesToSeveralKeys() async {
        var changes = settings.changes(ofAny: [Self.tone.erased, Self.apps.erased]).makeAsyncIterator()
        settings[Self.enabled] = false
        settings[Self.apps] = ["com.example.two"]
        settings[Self.tone] = .dark
        #expect(await changes.next() == "apps", "keys outside the list are not reported")
        #expect(await changes.next() == "tone")
    }

    @Test func secretsAreNamespacedAndKeptOutOfSettings() async throws {
        let secrets = fakes.context(featureID: "demo").secrets
        try await secrets.set("token-123", for: "apiKey")
        #expect(try await secrets.value(for: "apiKey") == "token-123")
        #expect(fakes.secrets.values == ["demo.apiKey": "token-123"])
        #expect(fakes.settings.values.isEmpty)
        try await secrets.set(nil, for: "apiKey")
        #expect(try await secrets.value(for: "apiKey") == nil)
    }

    @Test func panesEraseTheirKeys() throws {
        let pane = SettingsPane([
            SettingsSection(
                "General",
                items: [
                    .toggle("Enabled", key: Self.enabled),
                    .picker("Tone", key: Self.tone) { $0.rawValue.capitalized },
                    .hotkey("Hotkey", key: Self.hotkey),
                    .list("Ignored apps", key: Self.apps, itemKind: .application),
                    .button("Clear", style: .destructive, confirmation: Confirmation("Clear?")) { _ in },
                    .multiSelect("Calendars", key: Self.apps) { [SettingsChoice(id: "work", title: "Work")] },
                    .secret("API key", name: "apiKey"),
                    .permission(.calendars),
                ])
        ])
        let controls = try #require(pane.sections.first).items.map(\.control)
        #expect(controls.compactMap(\.key?.name) == ["enabled", "tone", "hotkey", "apps", "apps"])
        guard case .picker(_, let options) = controls[1] else {
            Issue.record("expected a picker")
            return
        }
        #expect(options.map(\.title) == ["None", "Light", "Dark"])
        #expect(options.map(\.value) == [.string("none"), .string("light"), .string("dark")])
    }
}
