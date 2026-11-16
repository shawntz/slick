import Foundation
import Kit
import KitTesting
import Testing

@testable import Windows

/// Guards that keep the feature from touching real windows, and odd input.
@MainActor
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    @Test func everyRunOutsideTheAppGetsTheSimulatedDesktop() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let context = FakeServices().context(featureID: "windows", environment: environment)
            #expect(context.service(WindowServiceKey.self) is SimulatedWindows, "\(environment)")
        }
    }

    @Test func activatingAndSwitchingTheFeatureOffAndOnTouchesNothing() async throws {
        let windows = WindowsHarness(windows: SwitchWindowsTests.desk)
        await windows.harness.activate()
        await windows.harness.deactivate()
        await windows.harness.activate()
        #expect(windows.desktop.frameSets == 0)
        #expect(windows.desktop.windows == SwitchWindowsTests.desk)
        #expect(windows.harness.fakes.hotkeys.registered.isEmpty)
        #expect(windows.harness.fakes.permissions.requests.isEmpty)
        // It still works afterwards, and Restore still knows the frame from before.
        try await windows.press("maximize")
        try await windows.press("restore")
        #expect(windows.frame == SwitchWindowsTests.desk[0].frame)
    }

    @Test func closingNamesTheWindowAndItsApp() async throws {
        let windows = WindowsHarness(windows: SwitchWindowsTests.desk)
        try await windows.harness.run(WindowCommands.switchWindowsID)
        windows.harness.confirmationAnswer = false
        try windows.harness.select(title: "Start Page")
        try await windows.harness.perform("close")
        try windows.harness.select(title: "Example Player")
        try await windows.harness.perform("close")
        #expect(
            windows.harness.confirmations.map(\.title) == [
                "Close \u{201C}Start Page\u{201D}?", "Close this Example Player window?",
            ])
        #expect(
            windows.harness.confirmations.first?.message
                == "If it has unsaved changes, Example Browser asks what to do with them.")
        #expect(windows.desktop.windows.count == SwitchWindowsTests.desk.count, "nothing closed on No")
        #expect(windows.harness.issues.isEmpty)
        #expect(windows.harness.pendingIssues.isEmpty)
    }

    @Test func aLongTitleIsCutInTheQuestion() {
        let question = Strings.closeQuestion(title: String(repeating: "word ", count: 40), app: "Example Editor")
        #expect(question.count <= 64)
        #expect(question.hasSuffix("\u{2026}\u{201D}?"))
        #expect(Strings.closeQuestion(title: nil, app: nil) == "Close this window?")
        #expect(
            Strings.closeMessage(app: nil) == "If it has unsaved changes, the app asks what to do with them.")
    }

    @Test func titlesOfEveryKindStayOnOneLine() async throws {
        let odd: [SimulatedWindows.Window] = [
            SwitchWindowsTests.window(60, 1, "Report\nDraft\t2", "Example Editor"),
            SwitchWindowsTests.window(61, 1, "\u{05D8}\u{05D9}\u{05D5}\u{05D8}\u{05D4} \u{1F4DD}", "Example Notes"),
            SwitchWindowsTests.window(62, 1, "\u{0007}\u{200B}", "Example Bell"),
            SwitchWindowsTests.window(63, 1, String(repeating: "x", count: 5_000), "Example Long"),
        ]
        let windows = WindowsHarness(windows: odd)
        try await windows.harness.run(WindowCommands.switchWindowsID)
        let titles = windows.harness.rows.map(\.title)
        #expect(titles[0] == "Report Draft 2")
        #expect(titles[1] == "\u{05D8}\u{05D9}\u{05D5}\u{05D8}\u{05D4} \u{1F4DD}")
        #expect(titles.allSatisfy { !$0.contains("\n") && !$0.contains("\t") })
        #expect(titles[3].count == 5_000, "the host truncates what it draws")
        windows.harness.confirmationAnswer = false
        try windows.harness.select(at: 3)
        try await windows.harness.perform("close")
        #expect(
            windows.harness.confirmations.last?.title == "Close \u{201C}" + String(repeating: "x", count: 49)
                + "\u{2026}\u{201D}?")
        try await windows.harness.setQuery("report draft")
        #expect(windows.harness.rows.map(\.title) == ["Report Draft 2"])
        #expect(windows.harness.issues.isEmpty)
    }

    @Test func fiftyThousandWindowsListInStackOrder() {
        let processes = 500
        let perProcess = 100
        var listed: [ListedWindow] = []
        var stack: [(process: pid_t, frame: Frame)] = []
        listed.reserveCapacity(processes * perProcess)
        for process in 0..<processes {
            for slot in 0..<perProcess {
                let frame = Frame(x: Double(slot * 10), y: Double(process * 10), width: 400, height: 300)
                let window = OpenWindow(
                    ref: WindowRef(process: pid_t(1_000 + process), token: slot), title: "\(process)-\(slot)",
                    appName: "Example \(process)")
                listed.append(ListedWindow(window: window, frame: frame, positionInApp: slot))
                stack.append((pid_t(1_000 + process), frame))
            }
        }
        // The stack is the reverse of the order the apps answered in.
        stack.reverse()
        let ordered = AccessibilityWindows.mostRecentFirst(listed, stackingOrder: stack)
        #expect(ordered.count == listed.count)
        #expect(ordered.first?.title == "\(processes - 1)-\(perProcess - 1)")
        #expect(ordered.last?.title == "0-0")
        let rows = WindowList.rows(ordered)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func aDisplayWithNoAreaIsNeverATarget() async throws {
        let empty = Display(
            id: 9, frame: Frame(x: 3_432, y: 0, width: 1_920, height: 1_080),
            visibleFrame: Frame(x: 3_432, y: 0, width: 0, height: 0), scale: 1)
        let windows = WindowsHarness(displays: [Displays.laptop, Displays.rightExternal, empty])
        try await windows.press("next-display")
        try await windows.press("next-display")
        #expect(windows.frame.map { contains(Displays.laptop.visibleFrame, $0) } == true, "it skipped the empty one")

        var onEmpty = WindowsHarness.editor
        onEmpty.frame = Frame(x: 3_500, y: 100, width: 600, height: 400)
        let stranded = WindowsHarness(displays: [Displays.laptop, empty], windows: [onEmpty])
        try await stranded.press("left-half")
        #expect(stranded.harness.huds == [.failure(Strings.noDisplay)])
        #expect(stranded.desktop.frameSets == 0)
    }

    @Test func noDisplaysAtAllSaysSo() async throws {
        let windows = WindowsHarness(displays: [])
        try await windows.press("left-half")
        #expect(windows.harness.huds == [.failure(Strings.noDisplay)])
        #expect(windows.desktop.frameSets == 0)
    }
}
