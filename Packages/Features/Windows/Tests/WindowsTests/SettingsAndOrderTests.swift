import Kit
import KitTesting
import Testing

@testable import Windows

@MainActor
@Suite("Settings pane and window order", .timeLimit(.minutes(1)))
struct SettingsAndOrderTests {
    @Test func thePaneOffersTheExpectedChoicesWithSafeDefaults() throws {
        let harness = WindowsHarness().harness
        let pane = try #require(harness.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        let keys = Set(items.compactMap { $0.control.key?.name })
        #expect(keys == ["windowGap", "screenGap", "almostMaximizePercent", "repeatBehavior", "showsLayoutName"])
        // The first thing the pane says is that the feature binds nothing and can be turned off whole.
        let notes = pane.sections[0].items.map(\.title)
        #expect(notes == [Strings.noHotkeysNote, Strings.turnOffNote])
        #expect(items.contains { if case .permission(.accessibility) = $0.control { true } else { false } })

        let defaults = WindowsSettings.options(harness.context.settings)
        #expect(
            defaults
                == LayoutOptions(screenGap: 0, windowGap: 0, repeatBehavior: .cycleSizes, almostMaximizeFraction: 0.9))
        #expect(harness.context.settings[WindowsSettings.showsLayoutName] == false)
    }

    /// The settings window draws a feature's hotkey presets above its own sections.
    @Test func theHotkeysNoteSaysThePresetsAreAbove() {
        #expect(Strings.noHotkeysNote.contains("the presets above"))
        #expect(!Strings.noHotkeysNote.contains("below"))
    }

    @Test func everyRepeatChoiceHasATitle() throws {
        let harness = WindowsHarness().harness
        let picker = try #require(
            harness.feature.settingsPane?.sections.flatMap(\.items).first { $0.control.key?.name == "repeatBehavior" })
        guard case .picker(_, let options) = picker.control else {
            Issue.record("not a picker")
            return
        }
        #expect(options.map(\.title) == RepeatBehavior.allCases.map(Strings.repeatTitle))
        #expect(options.map(\.value) == RepeatBehavior.allCases.map { .string($0.rawValue) })
    }

    @Test func userTextFollowsTheWritingRules() {
        let sentences = [
            Strings.summary, Strings.accessibilityReason, Strings.noHotkeysNote, Strings.turnOffNote,
            Strings.closeMessage(app: "Example Editor"), Strings.closeMessage(app: nil), Strings.windowGapInfo,
            Strings.screenGapInfo, Strings.almostMaximizeInfo, Strings.needsAccessMessage, Strings.noWindowsMessage,
            Strings.repeatInfo, Strings.showsLayoutNameInfo, Strings.accessInfo,
        ]
        for sentence in sentences {
            #expect(!sentence.contains("\u{2014}"), "no em dashes: \(sentence)")
            #expect(!sentence.contains("("), "no asides: \(sentence)")
        }
        #expect(Strings.accessibilityReason.hasPrefix("Move"), "a permission reason starts with a verb")
        #expect(!Strings.accessibilityReason.contains(Brand.name))
    }

    // MARK: - Most recent first, as the live service orders Accessibility windows

    func listed(_ process: Int32, _ token: Int, x: Double, minimized: Bool = false, position: Int = 0) -> ListedWindow {
        ListedWindow(
            window: OpenWindow(
                ref: WindowRef(process: process, token: token), title: "\(process).\(token)", appName: "App",
                isMinimized: minimized),
            frame: Frame(x: x, y: 0, width: 100, height: 100), positionInApp: position)
    }

    @Test func windowsFollowTheStackingOrderAcrossApps() {
        let listed = [
            listed(1, 1, x: 0, position: 0), listed(1, 2, x: 200, position: 1), listed(2, 1, x: 400),
            listed(3, 1, x: 600, minimized: true), listed(4, 1, x: 800),
        ]
        // Front to back: app 2, then app 1's second window, then its first. App 4 is on another Space.
        let stack: [(process: Int32, frame: Frame)] = [
            (2, Frame(x: 400, y: 0, width: 100, height: 100)),
            (1, Frame(x: 201, y: 1, width: 100, height: 100)),
            (1, Frame(x: 0, y: 0, width: 100, height: 100)),
        ]
        let ordered = AccessibilityWindows.mostRecentFirst(listed, stackingOrder: stack)
        #expect(ordered.map(\.title) == ["2.1", "1.2", "1.1", "4.1", "3.1"])
    }

    @Test func twoWindowsWithTheSameFrameEachTakeTheirOwnPlace() {
        let listed = [listed(1, 1, x: 0, position: 0), listed(1, 2, x: 0, position: 1)]
        let stack: [(process: Int32, frame: Frame)] = [
            (1, Frame(x: 0, y: 0, width: 100, height: 100)), (1, Frame(x: 0, y: 0, width: 100, height: 100)),
        ]
        #expect(AccessibilityWindows.mostRecentFirst(listed, stackingOrder: stack).map(\.title) == ["1.1", "1.2"])
    }
}
