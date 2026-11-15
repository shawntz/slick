import Kit
import KitHosting
import KitTesting
import Testing

@Suite(.timeLimit(.minutes(1))) struct HostSettingsTests {
    @Test func defaultsMatchTheContract() {
        let general = HostSettings.settings(FakeSettings())
        #expect(general[HostSettings.panelSizing] == .fixed)
        #expect(general[HostSettings.visibleRows] == 9)
        #expect(general[HostSettings.summonStrategy] == .layerOpacity)
        #expect(general[HostSettings.panelScreen] == .pointer)
        #expect(general[HostSettings.resetToRootAfter] == 90)
        #expect(general[HostSettings.launcherHotkey] == KeyCombo(.space, .command))
        #expect(general[HostSettings.showSuggestions])
        #expect(general[HostSettings.suggestionCount] == 5)
        #expect(general[HostSettings.showFavorites])
        #expect(general[HostSettings.inlineCompletion])
        #expect(general[HostSettings.fallbackCommands].isEmpty)
        #expect(general[HostSettings.tabCommand].isEmpty)
        #expect(!general[HostSettings.learningPaused])
        #expect(general[HostSettings.showStatusItem])
        #expect(general[HostSettings.fetchRemoteIcons])
        #expect(general[HostSettings.themeName] == "Standard")
        #expect(!general[HostSettings.onboardingDone])
    }

    @Test func valuesRoundTripUnderTheNamespace() {
        let store = FakeSettings()
        let general = HostSettings.settings(store)
        general[HostSettings.panelSizing] = .fitContent
        general[HostSettings.summonStrategy] = .orderFront
        general[HostSettings.panelScreen] = .activeWindow
        general[HostSettings.resetToRootAfter] = -1
        general[HostSettings.launcherHotkey] = nil
        general[HostSettings.fallbackCommands] = ["cmd:web.google", "cmd:web.maps"]
        general[HostSettings.tabCommand] = "cmd:ai.ask"
        general[HostSettings.themeName] = "Graphite"

        let reread = HostSettings.settings(store)
        #expect(reread[HostSettings.panelSizing] == .fitContent)
        #expect(reread[HostSettings.summonStrategy] == .orderFront)
        #expect(reread[HostSettings.panelScreen] == .activeWindow)
        #expect(reread[HostSettings.resetToRootAfter] == -1)
        #expect(reread[HostSettings.launcherHotkey] == nil)
        #expect(reread[HostSettings.fallbackCommands] == ["cmd:web.google", "cmd:web.maps"])
        #expect(reread[HostSettings.tabCommand] == "cmd:ai.ask")
        #expect(reread[HostSettings.themeName] == "Graphite")
        #expect(store.values["app.general.panelSizing"] == .string("fitContent"))
        #expect(store.values["app.general.launcherHotkey"] == .empty)
        #expect(store.values.keys.allSatisfy { $0.hasPrefix(HostSettings.namespace + ".") })
    }

    @Test func everyKeyIsListedOnce() {
        let names = HostSettings.allKeys.map(\.name)
        #expect(names.count == 17)
        #expect(Set(names).count == names.count)
        #expect(!FeatureManifestID.isValid(HostSettings.namespace))
    }

    @Test func resetDelay() {
        #expect(HostSettings.resetToRootDelay(0) == .zero)
        #expect(HostSettings.resetToRootDelay(90) == .seconds(90))
        #expect(HostSettings.resetToRootDelay(-1) == nil)
    }

    @Test func changesStreamAcrossWriters() async throws {
        let store = FakeSettings()
        let general = HostSettings.settings(store)
        var changes = general.changes(of: HostSettings.visibleRows).makeAsyncIterator()
        HostSettings.settings(store)[HostSettings.visibleRows] = 7
        #expect(await changes.next() == 7)
    }
}

/// The feature ID rule from ``FeatureManifest/id``: a lowercase letter, then lowercase letters,
/// digits and "-".
private enum FeatureManifestID {
    static func isValid(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
