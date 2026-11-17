import AppKit
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import SwiftUI
import Testing

@testable import SettingsUI

/// The recorder field with clicks and keys, as AppKit hands them to it. A click goes the way the
/// window sends it: the window makes the clicked view first responder, then sends it mouseDown.
/// Each window sits far off every display and is never ordered in, except in
/// ``RoutedRecorderTests``. None becomes key.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HotkeyRecorderFieldTests {
    @Test func aClickStartsARecordingTheNextStopsItAndTheThirdStartsItAgain() {
        let bench = RecorderBench()
        defer { bench.close() }
        for round in 1...3 {
            bench.click()
            #expect(bench.model.isRecording == (round != 2), "click \(round)")
            #expect((bench.window.firstResponder === bench.field) == (round != 2), "click \(round)")
        }
        #expect(bench.model.displayText == "Type a shortcut")
        // The same when nothing made the field first responder before the click.
        bench.click()
        #expect(!bench.model.isRecording)
        for round in 1...3 {
            bench.click(asTheWindowDoes: false)
            #expect(bench.model.isRecording == (round != 2), "direct click \(round)")
        }
    }

    @Test func aClickedRecordingStoresTheCombinationAndGivesUpFocus() {
        let bench = RecorderBench()
        defer { bench.close() }
        bench.click()
        #expect(bench.model.isRecording)
        bench.type(.k, "k", [.command, .option])
        #expect(bench.bed.preferences.hotkeys[TestBed.open] == KeyCombo(.k, [.command, .option]))
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder !== bench.field, "no focus ring stays on the field")
        bench.click()
        #expect(bench.model.isRecording)
        bench.type(.escape, "\u{1b}")
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder !== bench.field)
        // A key the model refuses ends the recording too, and the note says why.
        bench.click()
        #expect(bench.model.isRecording)
        bench.type(.k, "k")
        #expect(!bench.model.isRecording)
        #expect(bench.model.note != nil)
        #expect(bench.window.firstResponder !== bench.field)
        #expect(bench.bed.preferences.hotkeys[TestBed.open] == KeyCombo(.k, [.command, .option]))
        #expect(bench.window.unanswered == 0)
    }

    @Test func theSecondClickOfADoubleClickIsIgnored() {
        let bench = RecorderBench()
        defer { bench.close() }
        bench.click()
        bench.click(count: 2)
        #expect(bench.model.isRecording, "a double-click starts one recording")
        #expect(bench.window.firstResponder === bench.field)
        bench.click(count: 3)
        #expect(bench.model.isRecording)
        bench.click()
        #expect(!bench.model.isRecording, "a single click after it stops the recording")
        // A quick click after a recording ended starts the next one, whatever its click count.
        bench.click(count: 2)
        #expect(bench.model.isRecording, "a quick click after a stop records")
        bench.type(.k, "k", [.command, .option])
        #expect(!bench.model.isRecording)
        bench.click(count: 2)
        #expect(bench.model.isRecording, "a quick click after a recorded shortcut records")
        bench.type(.escape, "\u{1b}")
        #expect(!bench.model.isRecording)
        bench.click(count: 3)
        #expect(bench.model.isRecording, "a quick click after Escape records")
        // A recording the keyboard started stops on a click of any count.
        bench.type(.escape, "\u{1b}")
        #expect(bench.window.makeFirstResponder(bench.field))
        bench.type(.space, " ")
        #expect(bench.model.isRecording)
        bench.click(count: 2)
        #expect(!bench.model.isRecording)
    }

    @Test func aCommandClickInAWindowThatIsNotKeyStartsNothing() {
        let bench = RecorderBench()
        defer { bench.close() }
        bench.click(flags: [.command])
        #expect(!bench.model.isRecording, "the window stays in the background, so no key would arrive")
        bench.click()
        #expect(bench.model.isRecording, "a plain click still records")
        bench.click()
        #expect(!bench.model.isRecording)
        // In the key window a Command-click is a click like any other.
        bench.window.claimsKey = true
        bench.click(flags: [.command])
        #expect(bench.model.isRecording)
    }

    /// The window tells a recording field about every mouse-down, whatever the button and however
    /// the recording started.
    @Test func anyButtonPressedElsewhereEndsARecordingHoweverItStarted() {
        let bench = RecorderBench()
        defer { bench.close() }
        let away = CGPoint(x: 300, y: 80)
        #expect(bench.hit(at: away).map { !$0.isDescendant(of: bench.field) } == true)
        bench.click()
        #expect(bench.model.isRecording)
        bench.window.sendEvent(Events.mouse(.rightMouseDown, at: away, in: bench.window))
        #expect(!bench.model.isRecording, "a right click elsewhere ends it")
        #expect(bench.window.firstResponder !== bench.field, "a click's recording gives up focus")

        #expect(bench.window.makeFirstResponder(bench.field))
        bench.type(.space, " ")
        #expect(bench.model.isRecording)
        bench.window.sendEvent(Events.mouse(.otherMouseDown, at: away, in: bench.window))
        #expect(!bench.model.isRecording, "a third button elsewhere ends a recording the keyboard started")
        #expect(bench.window.firstResponder === bench.field, "and the field keeps focus")

        // A press on the field itself is the field's own business.
        bench.click()
        #expect(bench.model.isRecording)
        bench.window.sendEvent(Events.mouse(.rightMouseDown, at: bench.middle, in: bench.window))
        #expect(bench.model.isRecording, "a right click on the field leaves the recording alone")
    }

    @Test func aNewModelEndsTheRecordingOfTheOldOne() {
        let bench = RecorderBench()
        defer { bench.close() }
        bench.click()
        #expect(bench.model.isRecording)
        let other = bench.bed.context().recorder(
            HotkeyTargets.item(TestBed.open, title: "Open again", preferences: bench.bed.preferences))
        bench.field.model = other
        #expect(!bench.model.isRecording, "the old model stops recording")
        #expect(!other.isRecording)
        bench.click()
        #expect(other.isRecording, "a click records on the new model")
        #expect(!bench.model.isRecording)
    }

    @Test func focusAloneRecordsNothing() {
        let bench = RecorderBench()
        defer { bench.close() }
        #expect(bench.window.makeFirstResponder(bench.field))
        #expect(!bench.model.isRecording)
        #expect(bench.model.displayText == "Record Shortcut")
    }

    @Test func tabReachesTheFieldOnlyWithKeyboardNavigation() {
        let bench = RecorderBench()
        defer { bench.close() }
        bench.field.keyboardNavigation = { false }
        #expect(!bench.field.canBecomeKeyView)
        bench.field.keyboardNavigation = { true }
        #expect(bench.field.canBecomeKeyView)
        // A click reaches the field either way.
        #expect(bench.field.acceptsFirstResponder)
        // Left alone, the field asks this Mac's setting.
        #expect(HotkeyRecorderField().keyboardNavigation() == NSApplication.shared.isFullKeyboardAccessEnabled)
    }

    @Test func theFirstClickInAWindowThatIsNotKeyCounts() {
        let bench = RecorderBench()
        defer { bench.close() }
        #expect(!bench.window.isKeyWindow)
        #expect(bench.field.acceptsFirstMouse(for: bench.mouse(.leftMouseDown)))
        bench.click()
        #expect(bench.model.isRecording)
    }

    @Test func spaceAndReturnStartARecordingFromTheKeyboardAndFocusStays() {
        let bench = RecorderBench()
        defer { bench.close() }
        let field = bench.field
        #expect(bench.window.makeFirstResponder(field))
        bench.type(.space, " ")
        #expect(bench.model.isRecording)
        bench.type(.escape, "\u{1b}")
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder === field, "a recording the keyboard started keeps focus")
        bench.type(.return, "\r")
        #expect(bench.model.isRecording)
        bench.type(.j, "j", [.control, .option])
        #expect(bench.bed.preferences.hotkeys[TestBed.open] == KeyCombo(.j, [.control, .option]))
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder === field)
        bench.type(.space, " ")
        #expect(bench.model.isRecording, "Space records again")
        bench.type(.space, " ", repeating: true)
        #expect(bench.model.isRecording, "a held Space does not end the recording it started")
        field.keyDown(with: Events.key(.space, " ", [], repeating: true, in: bench.window))
        #expect(bench.model.isRecording, "nor when the repeat comes straight to keyDown")
        bench.type(.escape, "\u{1b}")
        bench.type(Key(code: 0x4C), "\u{3}")
        #expect(bench.model.isRecording, "the keypad's Enter starts a recording")
        bench.type(.escape, "\u{1b}")
        #expect(!bench.model.isRecording)
        #expect(bench.window.unanswered == 0)
        // With a modifier, Space is not a press. It goes on to the window unused.
        bench.type(.space, " ", [.option])
        #expect(!bench.model.isRecording)
        #expect(bench.window.unanswered == 1)
        #expect(bench.bed.preferences.hotkeys[TestBed.open] == KeyCombo(.j, [.control, .option]))
    }

    /// AppKit moves focus on Tab only in the key window, and no test window becomes key. So this
    /// checks that Tab and Shift-Tab reach the window, then moves focus as a key window does.
    @Test func tabAndShiftTabPassThroughToTheWindow() {
        let bench = RecorderBench()
        defer { bench.close() }
        let next = bench.addFieldAfter()
        let tab = Key.tab.code
        #expect(bench.window.makeFirstResponder(bench.field))
        bench.type(.space, " ")
        #expect(bench.model.isRecording)
        bench.type(.tab, "\t")
        bench.type(.tab, "\t", [.shift])
        #expect(bench.window.keysThatArrived == [tab, tab], "the window gets Tab and Shift-Tab")
        #expect(bench.model.isRecording, "Tab is not a shortcut")
        #expect(bench.bed.preferences.hotkeys[TestBed.open] == nil)
        bench.window.selectKeyView(following: bench.field)
        #expect(bench.isFocused(next))
        #expect(!bench.model.isRecording, "moving focus ends the recording")
        // A field that does not record passes them on too.
        #expect(bench.window.makeFirstResponder(bench.field))
        bench.type(.tab, "\t")
        bench.type(.tab, "\t", [.shift])
        #expect(bench.window.keysThatArrived == [tab, tab, tab, tab])
        #expect(!bench.model.isRecording)
    }

    @Test func theAccessibilityPressStartsARecordingOnlyInTheKeyWindow() {
        let bench = RecorderBench()
        defer { bench.close() }
        #expect(!bench.field.accessibilityPerformPress(), "a window that isn't key would get no keys")
        #expect(!bench.model.isRecording)
        bench.window.claimsKey = true
        #expect(bench.field.accessibilityPerformPress())
        #expect(bench.model.isRecording)
        #expect(bench.window.firstResponder === bench.field)
        #expect(bench.field.accessibilityPerformPress())
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder === bench.field)
        // A press stops a recording in any window.
        bench.window.claimsKey = false
        bench.click()
        #expect(bench.model.isRecording)
        #expect(bench.field.accessibilityPerformPress())
        #expect(!bench.model.isRecording)
    }

    @Test func aRecordingEndsWhenItsWindowStopsBeingKey() {
        let bench = RecorderBench()
        defer { bench.close() }
        let other = TestWindow(
            contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.titled], backing: .buffered,
            defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        bench.click()
        #expect(bench.model.isRecording)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(bench.model.isRecording, "another window's notice changes nothing")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: bench.window)
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder !== bench.field)

        // A recording the keyboard started keeps focus for when the window is key again.
        #expect(bench.window.makeFirstResponder(bench.field))
        bench.type(.space, " ")
        #expect(bench.model.isRecording)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: bench.window)
        #expect(!bench.model.isRecording)
        #expect(bench.window.firstResponder === bench.field)
        bench.click()
        #expect(bench.model.isRecording, "a click records again")
    }

    @Test func aRecordingEndsWhenTheFieldLeavesItsWindow() {
        let bench = RecorderBench()
        defer { bench.close() }
        bench.click()
        #expect(bench.model.isRecording)
        bench.field.removeFromSuperview()
        #expect(!bench.model.isRecording)
        // Back in a window, a click records again.
        bench.window.contentView?.addSubview(bench.field)
        bench.click()
        #expect(bench.model.isRecording)
    }

    /// The Clear button pressed through performClick, with no click in the window. SwiftUI updates
    /// the field after the model changes, and the field then gives up focus.
    @Test func aClickedRecordingThatTheClearButtonEndsGivesUpFocus() async throws {
        let bed = TestBed()
        bed.general[HostSettings.launcherHotkey] = KeyCombo(.space, .command)
        let model = SettingsModel(dependencies: bed.dependencies)
        let bench = SettingsWindowBench(model: model)
        defer { bench.close() }
        let recorder = model.general.launcherHotkey
        let field = try #require(bench.field())
        bench.click(field)
        #expect(recorder.isRecording)
        let clear = try #require(bench.hit(at: bench.clearPoint(beside: field)) as? NSButton)
        clear.performClick(nil)
        #expect(await eventually { bench.window.firstResponder !== field })
        #expect(!recorder.isRecording)
        #expect(bed.general[HostSettings.launcherHotkey] == nil)
        bench.settle()
        bench.click(try #require(bench.field()))
        #expect(recorder.isRecording)
    }

    /// The full loop in the real General pane inside the real settings view: click, type, see the
    /// combination stored, three times over.
    @Test func theGeneralPaneRecordsOneShortcutAfterAnother() throws {
        let bed = TestBed()
        bed.general[HostSettings.launcherHotkey] = KeyCombo(.space, .command)
        let model = SettingsModel(dependencies: bed.dependencies)
        let bench = SettingsWindowBench(model: model)
        defer { bench.close() }
        let recorder = model.general.launcherHotkey
        let combos: [(Key, String, NSEvent.ModifierFlags, KeyCombo)] = [
            (.space, " ", [.option], KeyCombo(.space, .option)),
            (.k, "k", [.command, .shift], KeyCombo(.k, [.command, .shift])),
            (.j, "j", [.control, .option], KeyCombo(.j, [.control, .option])),
        ]
        for (index, combo) in combos.enumerated() {
            let round = index + 1
            let field = try #require(bench.field(), "round \(round)")
            #expect(!recorder.isRecording, "round \(round)")
            bench.click(field)
            #expect(recorder.isRecording, "round \(round): the click records")
            #expect(bench.window.firstResponder === field, "round \(round)")
            bench.type(combo.0, combo.1, combo.2)
            #expect(bed.general[HostSettings.launcherHotkey] == combo.3, "round \(round)")
            #expect(!recorder.isRecording, "round \(round)")
            #expect(bench.window.firstResponder !== field, "round \(round)")
            bench.settle()
        }
        // A second click stops a recording, and a third starts one.
        let field = try #require(bench.field())
        bench.click(field)
        bench.click(field)
        #expect(!recorder.isRecording)
        bench.click(field)
        #expect(recorder.isRecording)
        #expect(bench.window.unanswered == 0)
    }

    @Test func theGeneralPaneRecordsNothingUntilClicked() throws {
        let bed = TestBed()
        let model = SettingsModel(dependencies: bed.dependencies)
        let bench = SettingsWindowBench(model: model)
        defer { bench.close() }
        let field = try #require(bench.field())
        #expect(bench.window.makeFirstResponder(field))
        bench.settle()
        #expect(!model.general.launcherHotkey.isRecording)
        #expect(model.general.launcherHotkey.displayText != "Type a shortcut")
    }

    /// Onboarding's footer has Back on Escape and Continue on Return. While the recorder records,
    /// those keys go to the recorder instead.
    @Test func inOnboardingEscapeAndReturnGoToTheRecordingNotToBackAndContinue() async throws {
        let bed = TestBed()
        let context = bed.context()
        let model = OnboardingModel(context: context) {}
        try #require(model.show(.hotkey))
        let bench = SettingsWindowBench(onboarding: model, toasts: context.toasts)
        defer { bench.close() }
        let recorder = model.hotkey

        bench.click(try #require(bench.field()))
        #expect(recorder.isRecording)
        bench.settle()
        bench.type(.escape, "\u{1b}")
        bench.settle()
        #expect(model.step == .hotkey, "Escape stops the recording and stays on the step")
        #expect(!recorder.isRecording)

        bench.click(try #require(bench.field()))
        #expect(recorder.isRecording)
        bench.settle()
        bench.type(.return, "\r")
        bench.settle()
        #expect(model.step == .hotkey, "Return goes to the recording, which refuses a key alone")
        #expect(!recorder.isRecording)
        #expect(recorder.note != nil)

        bench.click(try #require(bench.field()))
        bench.settle()
        bench.type(.k, "k", [.command, .option])
        bench.settle()
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.k, [.command, .option]))
        #expect(model.step == .hotkey)

        // With no recording, Return presses Continue, as on any Mac. Continue runs in a task.
        bench.type(.return, "\r")
        #expect(await eventually { model.step != .hotkey })
        #expect(bench.window.unanswered == 0)
    }

    /// Return presses Continue while the recorder shows a refusal or asks to replace a hotkey.
    /// Nobody is left to answer on the next step, so the note goes.
    @Test func leavingTheHotkeyStepDropsANoteNobodyAnswered() async throws {
        let bed = TestBed()
        let model = OnboardingModel(context: bed.context()) {}
        try #require(model.show(.hotkey))
        model.hotkey.beginRecording()
        model.hotkey.handle(key: .k, modifiers: [])
        #expect(model.hotkey.note != nil, "a key alone is refused with a note")
        await model.next()
        #expect(model.step != .hotkey)
        #expect(model.hotkey.state == .idle)

        try #require(model.show(.hotkey))
        model.hotkey.beginRecording()
        model.hotkey.handle(key: .k, modifiers: [])
        #expect(model.hotkey.note != nil)
        model.back()
        #expect(model.step == .welcome)
        #expect(model.hotkey.state == .idle)
    }
}

/// Clicks and keys routed through `NSWindow.sendEvent` into the real settings window, ordered in
/// far off every display, fully transparent and unable to become key, so AppKit does its own part
/// of each event.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RoutedRecorderTests {
    @Test func routedClicksAndKeysRecordEveryTimeAndOpeningRecordsNothing() throws {
        let bed = TestBed()
        bed.general[HostSettings.launcherHotkey] = KeyCombo(.space, .command)
        let model = SettingsModel(dependencies: bed.dependencies)
        let bench = SettingsWindowBench(model: model)
        defer { bench.close() }
        let window = bench.window
        let recorder = model.general.launcherHotkey
        // This Mac's keyboard navigation setting plays no part.
        let first = try #require(bench.field())
        first.keyboardNavigation = { false }
        try #require(bench.orderInOffscreen(), "the window stays off every display")
        #expect(!recorder.isRecording, "opening the window records nothing")
        #expect(!(window.firstResponder is HotkeyRecorderField), "the window starts on another view")

        for round in 1...3 {
            let field = try #require(bench.field())
            bench.send(click: field)
            #expect(recorder.isRecording == (round != 2), "click \(round)")
            bench.settle()
        }
        bench.send(.l, "l", [.command, .option])
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.l, [.command, .option]))
        #expect(!recorder.isRecording)
        bench.settle()
        bench.send(click: try #require(bench.field()))
        #expect(recorder.isRecording, "a click after a recorded shortcut records again")
        bench.send(.escape, "\u{1b}")
        #expect(!recorder.isRecording)

        // With keyboard navigation on, the window may start on the field. That records nothing either.
        window.orderOut(nil)
        try #require(bench.field()).keyboardNavigation = { true }
        try #require(bench.orderInOffscreen(), "the window stays off every display")
        #expect(!recorder.isRecording, "showing the window again records nothing")
        bench.send(click: try #require(bench.field()))
        #expect(recorder.isRecording)
        bench.send(click: try #require(bench.field()))
        #expect(!recorder.isRecording)

        #expect(!window.isKeyWindow)
        #expect(window.becameKey == 0)
        #expect(window.alphaValue == 0)
        #expect(window.frame.origin == SettingsWindowBench.origin)
        #expect(window.unanswered == 0)
    }

    /// The same rounds in a window that says it is key, where AppKit sends a click without asking
    /// the field whether it takes the first click.
    @Test func routedClicksRecordTheSameInTheKeyWindow() throws {
        let bed = TestBed()
        bed.general[HostSettings.launcherHotkey] = KeyCombo(.space, .command)
        let model = SettingsModel(dependencies: bed.dependencies)
        let bench = SettingsWindowBench(model: model)
        defer { bench.close() }
        let window = bench.window
        let recorder = model.general.launcherHotkey
        window.claimsKey = true
        try #require(bench.orderInOffscreen(), "the window stays off every display")
        #expect(window.isKeyWindow)
        #expect(!recorder.isRecording, "opening the window records nothing")

        for round in 1...3 {
            bench.send(click: try #require(bench.field()))
            #expect(recorder.isRecording == (round != 2), "click \(round)")
            bench.settle()
        }
        bench.send(.l, "l", [.command, .option])
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.l, [.command, .option]))
        #expect(!recorder.isRecording)
        #expect(!(window.firstResponder is HotkeyRecorderField))
        bench.settle()
        bench.send(click: try #require(bench.field()))
        #expect(recorder.isRecording, "a click after a recorded shortcut records again")
        bench.send(.escape, "\u{1b}")
        #expect(!recorder.isRecording)

        window.claimsKey = false
        #expect(window.becameKey == 0)
        #expect(window.alphaValue == 0)
        #expect(window.frame.origin == SettingsWindowBench.origin)
        #expect(window.unanswered == 0)
    }

    /// A click on the form or on the Clear button ends a recording, so the field doesn't take the
    /// next shortcut typed, such as Command-W to close the window.
    @Test func aClickAnywhereElseInTheWindowEndsARecording() throws {
        let bed = TestBed()
        bed.general[HostSettings.launcherHotkey] = KeyCombo(.space, .command)
        let model = SettingsModel(dependencies: bed.dependencies)
        let bench = SettingsWindowBench(model: model)
        defer { bench.close() }
        let window = bench.window
        let recorder = model.general.launcherHotkey
        try #require(bench.orderInOffscreen(), "the window stays off every display")

        var field = try #require(bench.field())
        bench.send(click: field)
        #expect(recorder.isRecording)
        let away = bench.pointLeft(of: field)
        let hit = try #require(bench.hit(at: away))
        #expect(!hit.isDescendant(of: field))
        bench.send(clickAt: away)
        #expect(!recorder.isRecording)
        #expect(window.firstResponder !== field, "no focus ring stays on the field")
        bench.send(.w, "w", [.command])
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.space, .command))
        #expect(window.unanswered == 1, "Command-W went on to the window")

        bench.settle()
        field = try #require(bench.field())
        bench.send(click: field)
        #expect(recorder.isRecording)
        let clear = bench.clearPoint(beside: field)
        #expect(bench.hit(at: clear).map { !$0.isDescendant(of: field) } == true)
        bench.send(clickAt: clear)
        #expect(!recorder.isRecording)
        #expect(window.firstResponder !== field)
        #expect(bench.eventually { bed.general[HostSettings.launcherHotkey] == nil }, "the Clear button still clears")

        #expect(window.becameKey == 0)
        #expect(window.alphaValue == 0)
        #expect(window.frame.origin == SettingsWindowBench.origin)
    }
}

/// A settings window for these tests. It stays where it is put, even off every display. It never
/// becomes key: the calls that would make it key do nothing, and it counts the times it did anyway.
/// With ``claimsKey`` it only says it is key, so AppKit and the field act as in the key window. It
/// notes each key press that reaches it through the responder chain, and counts a key press nothing
/// used instead of playing the alert sound.
final class TestWindow: SettingsWindow {
    private(set) var keysThatArrived: [UInt16] = []
    private(set) var unanswered = 0
    private(set) var becameKey = 0
    /// True only while the test orders the window in itself.
    var allowsOrdering = false
    /// True makes the window say it is key, without becoming key.
    var claimsKey = false

    override var isKeyWindow: Bool { claimsKey || super.isKeyWindow }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        keysThatArrived.append(event.keyCode)
        super.keyDown(with: event)
    }

    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)) {
            unanswered += 1
        } else {
            super.noResponder(for: eventSelector)
        }
    }

    override func makeKey() {}
    override func makeKeyAndOrderFront(_ sender: Any?) {}
    override func orderFront(_ sender: Any?) {}

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if allowsOrdering || place == .out { super.order(place, relativeTo: otherWin) }
    }

    override func orderFrontRegardless() {
        if allowsOrdering { super.orderFrontRegardless() }
    }

    override func becomeKey() {
        becameKey += 1
        super.becomeKey()
    }
}

/// One recorder field for the sample command's hotkey, in a titled window far off every display
/// that is never ordered in.
@MainActor final class RecorderBench {
    let bed = TestBed()
    let model: HotkeyRecorderModel
    let field = HotkeyRecorderField(frame: CGRect(x: 20, y: 20, width: 150, height: 24))
    let window: TestWindow

    init() {
        _ = NSApplication.shared
        model = bed.context().recorder(HotkeyTargets.item(TestBed.open, title: "Open", preferences: bed.preferences))
        window = TestWindow(
            contentRect: CGRect(x: -20000, y: -20000, width: 400, height: 120), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        field.model = model
        window.contentView?.addSubview(field)
    }

    func close() {
        window.close()
    }

    /// The middle of the field, in the window.
    var middle: CGPoint {
        field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
    }

    /// The view a click at a point in the window lands on.
    func hit(at point: CGPoint) -> NSView? {
        (window.contentView?.superview ?? window.contentView)?.hitTest(point)
    }

    func mouse(_ type: NSEvent.EventType, count: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        Events.mouse(type, at: middle, in: window, count: count, flags: flags)
    }

    /// Clicks the field. As the window does, it first makes the field first responder, unless
    /// `asTheWindowDoes` is false. A `count` of 2 is the second click of a double-click, and
    /// `flags` are the modifier keys held.
    func click(asTheWindowDoes: Bool = true, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
        if asTheWindowDoes, field.acceptsFirstResponder, window.firstResponder !== field {
            window.makeFirstResponder(field)
        }
        field.mouseDown(with: mouse(.leftMouseDown, count: count, flags: flags))
        field.mouseUp(with: mouse(.leftMouseUp, count: count, flags: flags))
    }

    func type(_ key: Key, _ characters: String, _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false) {
        Events.type(Events.key(key, characters, flags, repeating: repeating, in: window), in: window)
    }

    /// Adds a text field that Tab moves to from the recorder, and back.
    func addFieldAfter() -> NSTextField {
        let next = NSTextField(frame: CGRect(x: 200, y: 20, width: 150, height: 24))
        window.contentView?.addSubview(next)
        field.nextKeyView = next
        next.nextKeyView = field
        return next
    }

    /// Whether a text field has focus, through its field editor.
    func isFocused(_ textField: NSTextField) -> Bool {
        let responder = window.firstResponder
        return responder === textField || (responder as? NSTextView)?.delegate === textField
    }
}

/// The real settings view, or the real onboarding view, in a window far off every display. It is
/// never ordered in unless a test calls ``orderInOffscreen()``.
@MainActor final class SettingsWindowBench {
    static let origin = CGPoint(x: -20000, y: -20000)
    let window: TestWindow

    convenience init(model: SettingsModel) {
        self.init(
            SettingsRootView(model: model), size: NSSize(width: 900, height: 640),
            style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    }

    convenience init(onboarding model: OnboardingModel, toasts: ToastCenter) {
        self.init(
            OnboardingView(model: model, toasts: toasts), size: OnboardingView.size,
            style: [.titled, .closable, .fullSizeContentView])
    }

    init(_ root: some View, size: NSSize, style: NSWindow.StyleMask) {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: root)
        window = TestWindow(contentViewController: hosting)
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.setContentSize(size)
        window.setFrameOrigin(Self.origin)
        settle()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    /// Orders the window in where it is, fully transparent. Returns false, with the window ordered
    /// out again, when it did not stay there.
    func orderInOffscreen() -> Bool {
        window.alphaValue = 0
        window.setFrameOrigin(Self.origin)
        window.allowsOrdering = true
        window.orderFrontRegardless()
        window.allowsOrdering = false
        guard window.frame.origin == Self.origin, window.isVisible else {
            window.orderOut(nil)
            return false
        }
        settle()
        return true
    }

    /// Lets SwiftUI lay out and update.
    func settle() {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// Lets SwiftUI and the tasks it starts run until `condition` holds, for up to two seconds.
    func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<20 {
            if condition() { return true }
            settle()
        }
        return condition()
    }

    /// The first recorder field in the window.
    func field() -> HotkeyRecorderField? {
        Self.find(in: window.contentView)
    }

    private static func find(in view: NSView?) -> HotkeyRecorderField? {
        guard let view else { return nil }
        if let field = view as? HotkeyRecorderField { return field }
        for subview in view.subviews {
            if let found = find(in: subview) { return found }
        }
        return nil
    }

    func middle(of field: NSView) -> CGPoint {
        field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
    }

    /// The view a click at a point in the window lands on.
    func hit(at point: CGPoint) -> NSView? {
        (window.contentView?.superview ?? window.contentView)?.hitTest(point)
    }

    /// The middle of the Clear button to the right of a field, in the window.
    func clearPoint(beside field: NSView) -> CGPoint {
        field.convert(CGPoint(x: field.bounds.maxX + 14, y: field.bounds.midY), to: nil)
    }

    /// A point in the form well left of a field, on its row's label.
    func pointLeft(of field: NSView) -> CGPoint {
        field.convert(CGPoint(x: field.bounds.minX - 220, y: field.bounds.midY), to: nil)
    }

    /// Clicks the middle of a field as the window does: the view under the point becomes first
    /// responder, then gets mouseDown and mouseUp.
    func click(_ field: HotkeyRecorderField) {
        let point = middle(of: field)
        let top = window.contentView?.superview ?? window.contentView
        let hit = top?.hitTest(point)
        #expect(hit === field, "the click lands on the field")
        guard let hit else { return }
        if hit.acceptsFirstResponder, window.firstResponder !== hit { window.makeFirstResponder(hit) }
        hit.mouseDown(with: Events.mouse(.leftMouseDown, at: point, in: window))
        hit.mouseUp(with: Events.mouse(.leftMouseUp, at: point, in: window))
    }

    /// Clicks the middle of a field through the window's own event routing.
    func send(click field: HotkeyRecorderField) {
        send(clickAt: middle(of: field))
    }

    /// Clicks a point in the window through the window's own event routing. Only single clicks: at
    /// 6355571 a routed double-click on the field made the test process end early with exit status
    /// 0, which would hide the failures it found.
    func send(clickAt point: CGPoint) {
        window.sendEvent(Events.mouse(.leftMouseDown, at: point, in: window))
        window.sendEvent(Events.mouse(.leftMouseUp, at: point, in: window))
    }

    /// Presses a key through the window's own event routing.
    func send(_ key: Key, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        window.sendEvent(Events.key(key, characters, flags, in: window))
    }

    func type(_ key: Key, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        Events.type(Events.key(key, characters, flags, in: window), in: window)
    }
}

/// Made-up events for a window. None is posted to the system.
@MainActor enum Events {
    static func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, count: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
            pressure: type == .leftMouseDown ? 1 : 0)!
    }

    static func key(
        _ key: Key, _ characters: String, _ flags: NSEvent.ModifierFlags, repeating: Bool = false, in window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: key.code)!
    }

    /// Hands a key press on as the app does: as a key equivalent first, then to the first responder.
    static func type(_ event: NSEvent, in window: NSWindow) {
        if !window.performKeyEquivalent(with: event) { window.firstResponder?.keyDown(with: event) }
    }
}
