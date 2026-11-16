import Foundation
import Kit
import Synchronization
import Testing

@testable import SlickApp

/// The scenario clock: moves wake waits, time never goes back, and a wait still ends with real
/// time. Nothing here waits on the real clock for long: real time is a stand-in that stands still.
@Suite("Scenario clock", .timeLimit(.minutes(1)))
struct ScenarioClockTests {
    /// A real time that only moves when the test says so.
    nonisolated final class StillTime: Sendable {
        let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        func read() -> Date { date.withLock { $0 } }
    }

    static let monday = Date(timeIntervalSince1970: 1_794_787_200)

    @Test func startsAtTheFileStartTimeInUTC() {
        let still = StillTime()
        let clock = ScenarioClock(startingAt: Self.monday, realNow: { still.read() })
        #expect(clock.now == Self.monday)
        #expect(clock.timeZone.secondsFromGMT() == 0)
        #expect(clock.calendar.component(.weekday, from: clock.now) == 2)
        #expect(clock.calendar.component(.hour, from: clock.now) == 0)
    }

    @Test func movesForwardAndNeverBack() {
        let still = StillTime()
        let clock = ScenarioClock(startingAt: Self.monday, realNow: { still.read() })
        let nine = Self.monday.addingTimeInterval(9 * 3_600)
        #expect(clock.move(to: nine))
        #expect(clock.now == nine)
        #expect(!clock.move(to: Self.monday))
        #expect(!clock.move(to: nine))
        #expect(clock.now == nine)
    }

    @Test func aMovePastTheEndOfAWaitEndsIt() async throws {
        let still = StillTime()
        let clock = ScenarioClock(startingAt: Self.monday, realNow: { still.read() })
        let waiting = Task { try await clock.sleep(for: .seconds(3_600)) }
        while clock.waitingCount == 0 { await Task.yield() }
        // A move that does not reach the end wakes the wait, which waits again.
        clock.move(to: Self.monday.addingTimeInterval(60))
        while clock.waitingCount == 0 { await Task.yield() }
        #expect(clock.waitingCount == 1)
        clock.move(to: Self.monday.addingTimeInterval(86_400))
        try await waiting.value
        #expect(clock.waitingCount == 0)
    }

    @Test func aCancelledWaitThrowsAndLeavesNothingBehind() async {
        let clock = ScenarioClock(startingAt: Self.monday)
        let waiting = Task { try await clock.sleep(for: .seconds(3_600)) }
        while clock.waitingCount == 0 { await Task.yield() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(clock.waitingCount == 0)
    }

    @Test func aShortWaitEndsWithRealTime() async throws {
        let clock = ScenarioClock()
        try await clock.sleep(for: .milliseconds(1))
        try await clock.sleep(for: .zero)
    }
}

@Suite("Scenario files with time, apps and settings")
struct ScenarioFileOptionsTests {
    @Test func readsTheNewAppSteps() throws {
        let text = """
            {
              "name": "Example",
              "startTime": "2026-11-16T00:00:00Z",
              "systemApps": true,
              "steps": [
                { "app": { "setTime": "2026-11-16T09:00:00Z", "sessionStart": true, "frontApp": "com.example.mail" } },
                { "app": { "select": "Calendar" } },
                { "app": { "openSettings": "rootSearch", "captureSettings": "root-search", "closeSettings": true } },
                { "app": { "setSettings": { "tabCommand": "cmd:ai.ask" } } },
                { "app": { "advanceClock": 1.5 } }
              ]
            }
            """
        let file = try ScenarioMode.load(Data(text.utf8))
        #expect(file.systemApps)
        #expect(file.startTime == Date(timeIntervalSince1970: 1_794_787_200))
        guard case .app(let context) = file.items[0], case .app(let select) = file.items[1],
            case .app(let settings) = file.items[2]
        else {
            Issue.record("the steps are not app steps")
            return
        }
        #expect(context.setTime == Date(timeIntervalSince1970: 1_794_787_200 + 9 * 3_600))
        #expect(context.sessionStart == true)
        #expect(context.frontApp == "com.example.mail")
        #expect(select.select == "Calendar")
        #expect(settings.openSettings == "rootSearch")
        #expect(settings.captureSettings == "root-search")
        #expect(settings.closeSettings == true)
        guard case .app(let advance) = file.items[4] else {
            Issue.record("the last step is not an app step")
            return
        }
        #expect(advance.advanceClock == 1.5)
    }

    @Test(arguments: [
        #"{ "name": "x", "steps": [], "unknown": 1 }"#,
        #"{ "name": "x", "steps": [], "startTime": "Monday" }"#,
        #"{ "name": "x", "steps": [ { "app": { "setTime": "9am" } } ] }"#,
        #"{ "name": "x", "steps": [ { "app": { "advanceClock": 0 } } ] }"#,
        #"{ "name": "x", "steps": [ { "app": { "advanceClock": -1 } } ] }"#,
    ])
    func refusesBadValues(text: String) {
        #expect(throws: (any Error).self) { try ScenarioMode.load(Data(text.utf8)) }
    }

    @Test func namesAnAppRootSearchDoesNotKnow() {
        #expect(ScenarioMode.appName("com.example.text-editor") == "Text Editor")
        #expect(ScenarioMode.appName("editor") == "Editor")
    }

    @Test func aScenarioRunGetsAClockItCanMove() throws {
        let file = ScenarioMode.File(name: "x", timeLimit: 5, items: [])
        let folder = FileManager.default.temporaryDirectory.appending(path: "clock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = try ScenarioMode.configuration(for: file, dataRoot: folder)
        #expect(configuration.environment == .scenario)
        #expect(configuration.clock is ScenarioClock)
        #expect(configuration.icons == nil)
        #expect(!FileManager.default.fileExists(atPath: SystemApps.appsTree(in: folder).path))
    }
}
