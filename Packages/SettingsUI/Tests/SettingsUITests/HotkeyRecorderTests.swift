import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct HotkeyRecorderTests {
    @Test func classifiesKeyPresses() {
        typealias Model = HotkeyRecorderModel
        #expect(Model.classify(key: .k, modifiers: [.command, .shift]) == .record(KeyCombo(.k, [.command, .shift])))
        #expect(Model.classify(key: .space, modifiers: .option) == .record(KeyCombo(.space, .option)))
        #expect(Model.classify(key: Key(name: "f5")!, modifiers: []) == .record(KeyCombo(Key(name: "f5")!)))
        // The Fn flag macOS adds to function keys is dropped.
        #expect(Model.classify(key: Key(name: "f13")!, modifiers: .function) == .record(KeyCombo(Key(name: "f13")!)))
        #expect(Model.classify(key: .escape, modifiers: []) == .cancel)
        #expect(Model.classify(key: .delete, modifiers: []) == .clear)
        #expect(Model.classify(key: .forwardDelete, modifiers: []) == .clear)
        #expect(Model.classify(key: .tab, modifiers: []) == .passThrough)
        #expect(Model.classify(key: .tab, modifiers: .shift) == .passThrough)
        if case .reject = Model.classify(key: .k, modifiers: []) {} else { Issue.record("a bare letter was accepted") }
        if case .reject = Model.classify(key: .k, modifiers: .shift) {
        } else {
            Issue.record("Shift alone was accepted")
        }
        if case .reject = Model.classify(key: .space, modifiers: []) {
        } else {
            Issue.record("a bare space was accepted")
        }
    }

    @Test func recordsOnlyWhileRecording() {
        let bed = TestBed()
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        #expect(!model.handle(key: .k, modifiers: .command))
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
        model.beginRecording()
        #expect(model.displayText == "Type a shortcut")
        model.modifiersChanged([.command, .option])
        #expect(model.displayText == "⌥⌘")
        #expect(model.handle(key: .k, modifiers: [.command, .option]))
        #expect(bed.preferences.hotkeys[TestBed.open] == KeyCombo(.k, [.command, .option]))
        #expect(model.state == .idle)
        #expect(model.displayText == "⌥⌘K")
    }

    @Test func rejectsBareKeysAndKeepsTheOldHotkey() throws {
        let bed = TestBed()
        try bed.preferences.setHotkey(KeyCombo(.j, .command), for: TestBed.open)
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        #expect(model.handle(key: .j, modifiers: []))
        guard case .message = model.state else {
            Issue.record("no message for a bare key")
            return
        }
        #expect(model.note?.contains("Command, Option or Control") == true)
        #expect(bed.preferences.hotkeys[TestBed.open] == KeyCombo(.j, .command))
    }

    @Test func tabPassesThroughAndEscapeStops() {
        let bed = TestBed()
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        #expect(!model.handle(key: .tab, modifiers: []))
        #expect(model.isRecording)
        #expect(model.handle(key: .escape, modifiers: []))
        #expect(!model.isRecording)
    }

    @Test func deleteClears() throws {
        let bed = TestBed()
        try bed.preferences.setHotkey(KeyCombo(.j, .command), for: TestBed.open)
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        #expect(model.handle(key: .delete, modifiers: []))
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
        #expect(model.combo == nil)
    }

    @Test func reviewsAConflictBeforeTakingTheCombination() throws {
        let bed = TestBed()
        let combo = KeyCombo(.l, [.control, .option])
        try bed.preferences.setHotkey(combo, for: TestBed.list)
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .l, modifiers: [.control, .option])
        guard case .review(let proposed, let conflicts) = model.state else {
            Issue.record("no review")
            return
        }
        #expect(proposed == combo)
        #expect(conflicts.map(\.owner) == [TestBed.list.rawValue])
        // The owner reads as the command's title.
        #expect(model.note == "List Samples uses ⌃⌥L. Replace it?")
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
        model.confirmReplace()
        #expect(bed.preferences.hotkeys[TestBed.open] == combo)
        #expect(bed.preferences.hotkeys[TestBed.list] == nil)
    }

    @Test func cancellingAReviewChangesNothing() throws {
        let bed = TestBed()
        let combo = KeyCombo(.l, [.control, .option])
        try bed.preferences.setHotkey(combo, for: TestBed.list)
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .l, modifiers: [.control, .option])
        model.dismiss()
        #expect(bed.preferences.hotkeys[TestBed.list] == combo)
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
    }

    @Test func refusesTheLauncherHotkey() {
        let bed = TestBed()
        let launcher = KeyCombo(.space, .option)
        bed.preferences.launcherHotkey = launcher
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .space, modifiers: .option)
        guard case .blocked(_, let conflicts) = model.state else {
            Issue.record("not blocked")
            return
        }
        #expect(conflicts == [HotkeyConflict(owner: "Launcher", canOverride: false)])
        #expect(model.note?.contains("and keeps it. Choose other keys.") == true)
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
    }

    @Test func showsASystemRefusal() {
        let bed = TestBed()
        bed.preferences.bindingFailure = .registrationFailed(code: -9878)
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .k, modifiers: [.command, .control])
        #expect(model.note == "macOS refused this hotkey. Try another combination.")
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
    }

    @Test func launcherHotkeyTakesACombinationFromAnItem() throws {
        let bed = TestBed()
        let combo = KeyCombo(.space, [.control, .option])
        try bed.preferences.setHotkey(combo, for: TestBed.list)
        let model = bed.context().recorder(HotkeyTargets.launcher(general: bed.general, preferences: bed.preferences))
        #expect(model.combo == KeyCombo(.space, .command))
        model.beginRecording()
        model.handle(key: .space, modifiers: [.control, .option])
        guard case .review = model.state else {
            Issue.record("no review")
            return
        }
        model.confirmReplace()
        #expect(bed.general[HostSettings.launcherHotkey] == combo)
        #expect(bed.preferences.hotkeys[TestBed.list] == nil)
    }

    @Test func reRecordingTheSameLauncherHotkeyIsNotAConflict() {
        let bed = TestBed()
        bed.preferences.launcherHotkey = KeyCombo(.space, .command)
        let model = bed.context().recorder(HotkeyTargets.launcher(general: bed.general, preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .space, modifiers: .command)
        #expect(model.state == .idle)
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.space, .command))
    }

    @Test func theLauncherStoresACombinationAMacOSShortcutHoldsAndNamesTheHolder() {
        let bed = TestBed()
        let combo = KeyCombo(.space, [.control])
        let owner = "Select the previous input source"
        bed.preferences.addSystemShortcut(combo, owner: owner)
        let model = bed.context().recorder(HotkeyTargets.launcher(general: bed.general, preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .space, modifiers: .control)
        #expect(
            model.state
                == .held(
                    combo,
                    [HotkeyConflict(owner: owner, canOverride: false, isSystemShortcut: true)]
                ))
        #expect(
            model.note
                == "Select the previous input source already uses ⌃Space. \(Brand.name) can use it after you turn off "
                + "that shortcut in System Settings.")
        #expect(bed.general[HostSettings.launcherHotkey] == combo)
        model.dismiss()
        #expect(model.note == nil)
    }

    @Test func aHeldCombinationAnItemHoldsIsReviewedFirstThenStored() throws {
        let bed = TestBed()
        let combo = KeyCombo(.space, [.control, .shift])
        try bed.preferences.setHotkey(combo, for: TestBed.list)
        bed.preferences.addSystemShortcut(combo)
        let model = bed.context().recorder(HotkeyTargets.launcher(general: bed.general, preferences: bed.preferences))
        model.propose(combo)
        guard case .review(_, let others) = model.state else {
            Issue.record("no review: \(model.state)")
            return
        }
        #expect(others.map(\.canOverride) == [true])
        model.confirmReplace()
        guard case .held = model.state else {
            Issue.record("not held: \(model.state)")
            return
        }
        #expect(bed.general[HostSettings.launcherHotkey] == combo)
        #expect(bed.preferences.hotkeys[TestBed.list] == nil)
    }

    @Test func anItemHotkeyStillRefusesACombinationAMacOSShortcutHolds() {
        let bed = TestBed()
        let combo = KeyCombo(.space, .command)
        bed.preferences.addSystemShortcut(combo)
        let model = bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        model.beginRecording()
        model.handle(key: .space, modifiers: .command)
        #expect(model.note == "Spotlight uses ⌘Space and keeps it. Choose other keys.")
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)

        // A feature's own hotkey setting is refused too.
        let settings = bed.sampleSettings()
        let setting = bed.context().recorder(
            HotkeyTargets.setting(
                SampleSettings.pickHotkey.erased, title: "Pick", settings: settings, preferences: bed.preferences))
        setting.propose(combo)
        guard case .blocked = setting.state else {
            Issue.record("not blocked: \(setting.state)")
            return
        }
        #expect(settings[SampleSettings.pickHotkey] == nil)
    }
}
