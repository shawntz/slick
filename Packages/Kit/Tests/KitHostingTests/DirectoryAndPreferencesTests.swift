import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@Suite(.timeLimit(.minutes(1))) struct DirectoryAndPreferencesTests {
    @Test func registeredFeaturesKeepOrderAndDeclarations() throws {
        let fakes = FakeServices()
        let directory = FakeFeatureDirectory()
        directory.register(ShelfFeature.self, fakes: fakes)
        directory.register(WatcherFeature.self, fakes: fakes)

        #expect(directory.features.map(\.id) == ["shelf", "watcher"])
        #expect(directory.enabledFeatures.map(\.id) == ["shelf"])
        let shelf = try #require(directory.feature("shelf"))
        #expect(shelf.commands.map(\.id.rawValue) == ["cmd:shelf.add", "cmd:shelf.browse"])
        #expect(shelf.commands.map(\.isEnabled) == [true, true])
        #expect(shelf.catalogSources.map(\.namespace) == ["shelf"])
        #expect(shelf.hotkeyPresets.map(\.id) == ["default"])
        #expect(shelf.context.featureID == "shelf")
        #expect(directory.feature("watcher")?.commands.first?.isEnabled == false)
        #expect(directory.command(.command(feature: "shelf", command: "browse"))?.command.title == "Shelf Browse")
        #expect(directory.command(ItemID("shelf", "add")) == nil)
    }

    @Test func providersAreFoundByNamespaceWhileTheFeatureIsOn() {
        let directory = FakeFeatureDirectory()
        let feature = directory.register(ShelfFeature.self, fakes: FakeServices())
        #expect(directory.provider(forNamespace: "shelf")?.actions === feature.catalog)
        #expect(directory.provider(forNamespace: "shelf-count")?.actions === feature.answers)
        #expect(directory.provider(forNamespace: "shelf-count")?.feature.id == "shelf")
        directory.setEnabled(false, feature: "shelf")
        #expect(directory.provider(forNamespace: "shelf") == nil)
    }

    @Test func switchesAndReloadsSendChanges() throws {
        let directory = FakeFeatureDirectory()
        let feature = directory.register(ShelfFeature.self, fakes: FakeServices())
        let before = directory.changes.generation
        let add = ItemID.command(feature: "shelf", command: "add")

        directory.setEnabled(false, command: add)
        #expect(directory.command(add)?.isEnabled == false)
        feature.commandIDs = ["add", "browse", "lend"]
        directory.reload("shelf")
        let shelf = try #require(directory.feature("shelf"))
        #expect(shelf.commands.map(\.command.id) == ["add", "browse", "lend"])
        #expect(shelf.commands.map(\.isEnabled) == [false, true, true])
        directory.setEnabled(false, feature: "shelf")
        #expect(directory.feature("shelf")?.commands.map(\.isEnabled) == [false, false, false])
        #expect(directory.changes.generation == before + 3)
    }

    @Test func featureSwitchActivatesThroughTheDirectory() async throws {
        let directory = FakeFeatureDirectory()
        let feature = directory.register(ShelfFeature.self, fakes: FakeServices())
        directory.register(WatcherFeature.self, fakes: FakeServices())
        let preferences = FakeItemPreferences(directory: directory)

        #expect(preferences.isEnabled(feature: "shelf"))
        #expect(!preferences.isEnabled(feature: "watcher"))
        #expect(!preferences.isEnabled(feature: "unknown"))
        await preferences.setEnabled(false, feature: "shelf")
        #expect(feature.deactivations == 1)
        #expect(directory.enabledFeatures.isEmpty)
        await preferences.setEnabled(true, feature: "shelf")
        #expect(feature.activations == 1)

        let browse = ItemID.command(feature: "shelf", command: "browse")
        preferences.setEnabled(false, command: browse)
        #expect(!preferences.isEnabled(command: browse))
        #expect(directory.command(browse)?.isEnabled == false)
    }

    @Test func aliasesAndFavorites() {
        let preferences = FakeItemPreferences()
        let notes = ItemID("app", "com.example.notes")
        let file = ItemID("file", "/tmp/example.txt")
        let before = preferences.changes.generation

        preferences.setAlias("nn", for: notes)
        preferences.setAlias("ex", for: file)
        preferences.setAlias("", for: file)
        #expect(preferences.aliases == [notes: "nn"])

        preferences.setFavorites([file, notes, file])
        #expect(preferences.favorites == [file, notes])
        preferences.toggleFavorite(file)
        #expect(preferences.favorites == [notes])
        #expect(!preferences.isFavorite(file))
        preferences.toggleFavorite(file)
        #expect(preferences.favorites == [notes, file])
        #expect(preferences.changes.generation == before + 6)
    }

    @Test func hotkeysTakeOverOtherItemsAndRefuseBlockingConflicts() throws {
        let preferences = FakeItemPreferences()
        let left = ItemID.command(feature: "windows", command: "left-half")
        let right = ItemID.command(feature: "windows", command: "right-half")
        let combo = KeyCombo(.leftArrow, [.control, .option])

        try preferences.setHotkey(combo, for: left)
        #expect(preferences.hotkeyConflicts(for: combo, excluding: left).isEmpty)
        #expect(preferences.hotkeyConflicts(for: combo, excluding: right).map(\.owner) == [left.rawValue])
        try preferences.setHotkey(combo, for: right)
        #expect(preferences.hotkeys == [right: combo])

        preferences.launcherHotkey = KeyCombo(.space, .option)
        #expect(throws: HotkeyError.conflict([HotkeyConflict(owner: "Launcher", canOverride: false)])) {
            try preferences.setHotkey(KeyCombo(.space, .option), for: left)
        }
        let spotlight = HotkeyConflict(owner: "Spotlight", canOverride: true)
        preferences.addConflict(spotlight, for: KeyCombo(.space, .command))
        try preferences.setHotkey(KeyCombo(.space, .command), for: left)
        #expect(preferences.hotkeys[left] == KeyCombo(.space, .command))

        preferences.bindingFailure = .registrationFailed(code: -9878)
        #expect(throws: HotkeyError.registrationFailed(code: -9878)) {
            try preferences.setHotkey(KeyCombo(.k, .command), for: left)
        }
        try preferences.setHotkey(nil, for: left)
        #expect(preferences.hotkeys == [right: combo])
    }
}
