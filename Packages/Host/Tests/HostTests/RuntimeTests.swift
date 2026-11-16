import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

/// The feature runtime: registration, declarations, switches and activation.
@Suite("Runtime: registration", .timeLimit(.minutes(1)))
@MainActor struct RegistrationTests {
    @Test func registersInOrderAndReadsDeclarations() async {
        let fixture = RuntimeFixture()
        await fixture.start()
        let runtime = fixture.runtime
        #expect(runtime.features.map(\.id) == ["workbench", "relay", "watcher"])
        #expect(runtime.enabledFeatures.map(\.id) == ["workbench", "relay"])
        #expect(runtime.command(RuntimeFixture.command("echo"))?.command.title == "Echo")
        #expect(runtime.feature("relay")?.universalActions.count == 1)
        #expect(runtime.issues.isEmpty, "\(runtime.issues)")
    }

    @Test func activatesFeaturesThatAreOnAndDeactivatesAtQuit() async {
        let fixture = RuntimeFixture()
        await fixture.start()
        #expect(fixture.workbench.activations == 1)
        #expect((fixture.runtime.instance("watcher") as? Watcher)?.activations == 0)
        await fixture.runtime.deactivateAll()
        #expect(fixture.workbench.deactivations == 1)
        #expect(fixture.runtime.isActive("workbench") == false)
    }

    @Test func skipsADuplicateFeatureAndNotesIt() async {
        let fixture = RuntimeFixture()
        await fixture.runtime.start([FeatureRegistration(Relay.self), FeatureRegistration(Relay.self)])
        #expect(fixture.runtime.features.map(\.id) == ["relay"])
        #expect(fixture.runtime.issues["relay"]?.isEmpty == false)
    }

    @Test func readsDeclarationsAgainAfterTheySignal() async {
        let fixture = RuntimeFixture()
        await fixture.start()
        var changes = fixture.runtime.changes.stream().makeAsyncIterator()
        fixture.workbench.showsExtra = true
        fixture.workbench.declarations.send()
        await changes.next()
        #expect(fixture.runtime.command(RuntimeFixture.command("extra")) != nil)
    }

    /// Root follows a live subtitle's change signal. After the feature's declarations change, the
    /// directory hands Root the same signal object again, so Root's runner keeps following it.
    @Test func aLiveSubtitleKeepsItsSignalAcrossADeclarationChange() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let id = RuntimeFixture.command("status")
        let before = try #require(fixture.runtime.command(id)?.command.liveSubtitle?.changes)
        #expect(before === fixture.workbench.statusChanges)
        var changes = fixture.runtime.changes.stream().makeAsyncIterator()
        fixture.workbench.showsExtra = true
        fixture.workbench.declarations.send()
        await changes.next()
        let after = try #require(fixture.runtime.command(id)?.command.liveSubtitle?.changes)
        #expect(after === before)
        #expect(fixture.runtime.feature("workbench")?.commands.first { $0.id == id }?.command.liveSubtitle != nil)
        #expect(before.listenerCount == 0, "the runtime itself does not listen; Root does")
    }

    @Test func aFeatureSwitchActivatesDeactivatesAndCancelsHandlers() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let preferences = fixture.runtime.preferences
        await preferences.setEnabled(true, feature: "watcher")
        #expect((fixture.runtime.instance("watcher") as? Watcher)?.activations == 1)
        #expect(fixture.runtime.feature("watcher")?.isEnabled == true)

        let run = fixture.runtime.pipeline.runCommand(RuntimeFixture.command("wait"), launch: .root)
        await fixture.fakes.clock.waitForSleepers(1)
        #expect(fixture.runtime.pipeline.runningHandlerCount == 1)
        await preferences.setEnabled(false, feature: "workbench")
        await run.value
        #expect(fixture.workbench.deactivations == 1)
        #expect(fixture.workbench.log == ["wait started"], "turning the feature off cancelled the handler")
        #expect(fixture.presenter.toasts.isEmpty && fixture.presenter.huds.isEmpty, "a cancellation shows nothing")
        #expect(fixture.runtime.command(RuntimeFixture.command("plain"))?.isEnabled == false)
    }

    /// A grant made through the app's own buttons reaches each feature that is on and lists it.
    @Test func aGrantReachesTheFeaturesThatAreOnAndListIt() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let watcher = try #require(fixture.runtime.instance("watcher") as? Watcher)
        await fixture.runtime.permissionGranted(.accessibility)
        await fixture.runtime.permissionGranted(.calendars)
        #expect(fixture.workbench.grants == [.accessibility], "only what the manifest lists")
        #expect(watcher.grants.isEmpty, "a feature that is off hears nothing")

        await fixture.runtime.preferences.setEnabled(true, feature: "watcher")
        await fixture.runtime.permissionGranted(.accessibility)
        #expect(watcher.grants == [.accessibility])
        #expect(fixture.workbench.grants == [.accessibility, .accessibility])
    }

    @Test func aCommandSwitchTurnsOneCommandOff() async {
        let fixture = RuntimeFixture()
        await fixture.start()
        fixture.runtime.preferences.setEnabled(false, command: RuntimeFixture.command("plain"))
        #expect(fixture.runtime.isAvailable(RuntimeFixture.command("plain")) == false)
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("plain"), launch: .root).value
        #expect(fixture.workbench.log.isEmpty)
        #expect(fixture.presenter.toasts.map(\.title) == ["This Command Is Not Available"])
    }
}

/// Aliases, hotkeys, favorites and the preferences file.
@Suite("Runtime: preferences", .timeLimit(.minutes(1)))
@MainActor struct PreferencesTests {
    @Test func preferencesSurviveARelaunch() async throws {
        let fakes = FakeServices()
        let folder = fakes.storage.root.appending(path: "host", directoryHint: .isDirectory)
        let first = RuntimeFixture(fakes: fakes, dataDirectory: folder)
        await first.start()
        let echo = RuntimeFixture.command("echo")
        let preferences = first.runtime.preferences
        preferences.setAlias("ec", for: echo)
        try preferences.setHotkey(KeyCombo(.e, [.control, .option]), for: echo)
        preferences.setFavorites([SampleRows.editor.id, echo, SampleRows.editor.id])
        preferences.setEnabled(false, command: RuntimeFixture.command("plain"))
        await preferences.setEnabled(true, feature: "watcher")
        await preferences.flush()
        #expect(FileManager.default.fileExists(atPath: preferences.fileURL.path))

        let second = RuntimeFixture(fakes: fakes, dataDirectory: folder)
        await second.start()
        let loaded = second.runtime.preferences
        #expect(loaded.aliases == [echo: "ec"])
        #expect(loaded.hotkeys == [echo: KeyCombo(.e, [.control, .option])])
        #expect(loaded.favorites == [SampleRows.editor.id, echo])
        #expect(loaded.isEnabled(command: RuntimeFixture.command("plain")) == false)
        #expect(loaded.isEnabled(feature: "watcher"))
        #expect(second.runtime.feature("watcher")?.isEnabled == true)
    }

    @Test func fallbackChoicesSurviveARelaunchAndAnOlderFileLoads() async throws {
        let fakes = FakeServices()
        let folder = fakes.storage.root.appending(path: "host", directoryHint: .isDirectory)
        let first = RuntimeFixture(fakes: fakes, dataDirectory: folder)
        await first.start()
        let preferences = first.runtime.preferences
        #expect(preferences.fallbackChoices.isEmpty)
        let echo = RuntimeFixture.command("echo")
        let plain = RuntimeFixture.command("plain")
        var changes = preferences.changes.stream().makeAsyncIterator()
        preferences.setFallback(echo, isOn: true)
        await changes.next()
        preferences.setFallbackOrder([plain, echo, plain])
        await changes.next()
        #expect(preferences.fallbackChoices == FallbackChoices(order: [plain, echo], switches: [echo: true]))
        await preferences.flush()

        let second = RuntimeFixture(fakes: fakes, dataDirectory: folder)
        await second.start()
        #expect(second.runtime.preferences.fallbackChoices == preferences.fallbackChoices)
    }

    @Test(arguments: [
        (#"{ "aliases": { "cmd:workbench.echo": "ec" } }"#, FallbackChoices()),
        (
            #"{ "fallbackChoices": { "order": ["not an id", "cmd:workbench.echo"], "switches": { "x": true } } }"#,
            FallbackChoices(order: [ItemID.command(feature: "workbench", command: "echo")])
        ),
    ])
    func anOlderOrHandEditedFileLoadsTheFallbackChoicesItCan(json: String, expected: FallbackChoices) async throws {
        let fixture = RuntimeFixture()
        try FileManager.default.createDirectory(at: fixture.dataDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fixture.runtime.preferences.fileURL)
        await fixture.start()
        #expect(fixture.runtime.preferences.fallbackChoices == expected)
    }

    @Test func aCorruptFileLoadsDefaults() async throws {
        let fixture = RuntimeFixture()
        try FileManager.default.createDirectory(at: fixture.dataDirectory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fixture.runtime.preferences.fileURL)
        await fixture.start()
        #expect(fixture.runtime.preferences.aliases.isEmpty)
        #expect(fixture.runtime.features.count == 3)
    }

    @Test func aHotkeyBindsAndRunsItsCommandWithTheHotkeyLaunch() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let plain = RuntimeFixture.command("plain")
        fixture.presenter.isPanelVisible = false
        try fixture.runtime.preferences.setHotkey(KeyCombo(.p, [.control, .option]), for: plain)
        let bindingID = HostPreferences.bindingID(for: plain)
        #expect(fixture.fakes.hotkeys.registered[bindingID] == KeyCombo(.p, [.control, .option]))
        #expect(await fixture.fakes.hotkeys.press(bindingID))
        #expect(await waitUntil { fixture.workbench.log == ["plain"] })
        #expect(fixture.workbench.launches == [.hotkey])
        #expect(await waitUntil { fixture.presenter.huds == ["Done"] })
    }

    @Test func settingAHotkeyTakesItOverFromAnotherItem() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let combo = KeyCombo(.j, [.control, .option])
        let preferences = fixture.runtime.preferences
        try preferences.setHotkey(combo, for: RuntimeFixture.command("plain"))
        #expect(preferences.hotkeyConflicts(for: combo, excluding: nil).map(\.owner) == ["Plain"])
        try preferences.setHotkey(combo, for: RuntimeFixture.command("echo"))
        #expect(preferences.hotkeys == [RuntimeFixture.command("echo"): combo])
        #expect(fixture.fakes.hotkeys.registered.count == 1)
    }

    @Test func theLauncherHotkeyAndRefusalsThrowAndStoreNothing() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let preferences = fixture.runtime.preferences
        let launcher = try #require(HostSettings.settings(fixture.fakes.settings)[HostSettings.launcherHotkey])
        #expect(throws: HotkeyError.self) { try preferences.setHotkey(launcher, for: RuntimeFixture.command("plain")) }
        let taken = KeyCombo(.t, [.control, .command])
        fixture.fakes.hotkeys.addConflict(HotkeyConflict(owner: "System", canOverride: false), for: taken)
        #expect(throws: HotkeyError.self) { try preferences.setHotkey(taken, for: RuntimeFixture.command("plain")) }
        #expect(preferences.hotkeys.isEmpty)
        #expect(fixture.fakes.hotkeys.registered.isEmpty)
    }

    @Test func aMacOSShortcutRefusesAnItemHotkeyAndKeepsItsMark() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let preferences = fixture.runtime.preferences
        let held = KeyCombo(.space, [.control, .option, .command])
        fixture.fakes.hotkeys.addSystemShortcut(held)
        #expect(preferences.hotkeyConflicts(for: held, excluding: nil).map(\.isSystemShortcut) == [true])
        let spotlight = HotkeyConflict(owner: "Spotlight", canOverride: false, isSystemShortcut: true)
        #expect(throws: HotkeyError.conflict([spotlight])) {
            try preferences.setHotkey(held, for: RuntimeFixture.command("plain"))
        }
        #expect(preferences.hotkeys.isEmpty)
        // The launcher hotkey is one of the launcher's own bindings, not a macOS shortcut.
        let launcher = try #require(HostSettings.settings(fixture.fakes.settings)[HostSettings.launcherHotkey])
        #expect(preferences.hotkeyConflicts(for: launcher, excluding: nil).map(\.isSystemShortcut) == [false])
    }

    @Test func aSwitchedOffCommandLosesItsBindingButKeepsItsHotkey() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let plain = RuntimeFixture.command("plain")
        let preferences = fixture.runtime.preferences
        try preferences.setHotkey(KeyCombo(.k, [.control, .option]), for: plain)
        preferences.setEnabled(false, command: plain)
        #expect(fixture.fakes.hotkeys.registered.isEmpty)
        #expect(preferences.hotkeys[plain] != nil)
        preferences.setEnabled(true, command: plain)
        #expect(fixture.fakes.hotkeys.registered.count == 1)
    }

    @Test func aMissingCommandKeepsItsAliasAndHotkeyForThirtyDays() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let echo = RuntimeFixture.command("echo")
        let preferences = fixture.runtime.preferences
        preferences.setAlias("ec", for: echo)
        try preferences.setHotkey(KeyCombo(.e, [.control, .option]), for: echo)

        fixture.workbench.showsEcho = false
        fixture.runtime.reread("workbench")
        #expect(preferences.missingCommands[echo] != nil)
        #expect(fixture.fakes.hotkeys.registered.isEmpty, "a missing command's hotkey is not bound")

        fixture.fakes.clock.advance(by: .seconds(29 * 86_400))
        fixture.runtime.reread("workbench")
        #expect(preferences.aliases[echo] == "ec")

        fixture.workbench.showsEcho = true
        fixture.runtime.reread("workbench")
        #expect(preferences.missingCommands.isEmpty, "it came back in time")
        #expect(fixture.fakes.hotkeys.registered.count == 1)

        fixture.workbench.showsEcho = false
        fixture.runtime.reread("workbench")
        fixture.fakes.clock.advance(by: .seconds(31 * 86_400))
        fixture.runtime.reread("workbench")
        #expect(preferences.aliases.isEmpty)
        #expect(preferences.hotkeys.isEmpty)
    }

    @Test func anItemHotkeyRunsTheRowsFirstActionThroughRoot() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let opened = Box<[ItemID]>([])
        let root = FakeRootSource(rows: SampleRows.all)
        root.rowActions = { row in
            [
                Action("Open", id: "open") { _ in
                    opened.value.append(row.id)
                    return .close()
                }
            ]
        }
        fixture.runtime.rootSource = root
        try fixture.runtime.preferences.setHotkey(KeyCombo(.f, [.control, .option]), for: SampleRows.editor.id)
        #expect(await fixture.fakes.hotkeys.press(HostPreferences.bindingID(for: SampleRows.editor.id)))
        #expect(await waitUntil { opened.value == [SampleRows.editor.id] })
        #expect(root.calls.contains(.didRun(SampleRows.editor.id, .hotkey)))
    }
}
