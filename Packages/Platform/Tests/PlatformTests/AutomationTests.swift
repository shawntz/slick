import Foundation
import Kit
import Synchronization
import Testing

@testable import Platform

/// Automation over a fake Apple Event Manager. No app is started and nothing is asked.
@Suite(.timeLimit(.minutes(1))) struct AutomationTests {
    let bundleID = "com.example.events"

    @Test func aCheckNeverStartsTheAppAndNeverAsks() {
        let system = FakeAutomationSystem(running: false)
        #expect(AutomationPermission.check(bundleID, using: system) == nil)
        system.setRunning(true, answer: OSStatus(errAEEventWouldRequireUserConsent))
        #expect(AutomationPermission.check(bundleID, using: system) == .notDetermined)
        #expect(system.launches == 0)
        #expect(system.asks == 0)
    }

    @Test func aRequestStartsTheAppHiddenThenAsks() async {
        let system = FakeAutomationSystem(running: false)
        system.answerAfterLaunch = noErr
        #expect(await AutomationPermission.request(bundleID, using: system) == .granted)
        #expect(system.launches == 1)
        #expect(system.asks == 1)
    }

    @Test func aRequestToARunningAppAsksWithoutStartingIt() async {
        let system = FakeAutomationSystem(running: true, answer: OSStatus(errAEEventNotPermitted))
        #expect(await AutomationPermission.request(bundleID, using: system) == .denied)
        #expect(system.launches == 0)
    }

    @Test func anAppThatJustStartedIsAskedAgainUntilItAnswers() async {
        let system = FakeAutomationSystem(running: false)
        system.answerAfterLaunch = noErr
        system.notFoundAsks = 2
        #expect(await AutomationPermission.request(bundleID, using: system) == .granted)
        #expect(system.asks == 3)

        let silent = FakeAutomationSystem(running: false)
        silent.answerAfterLaunch = OSStatus(procNotFound)
        #expect(await AutomationPermission.request(bundleID, using: silent, wait: .milliseconds(250)) == nil)
    }

    @Test func anAppThatCannotStartIsNeverAsked() async {
        let system = FakeAutomationSystem(running: false)
        system.launchSucceeds = false
        #expect(await AutomationPermission.request(bundleID, using: system) == nil)
        #expect(system.asks == 0)
    }

    @Test func theLiveSystemsChecksGoThroughTheSeam() {
        let fake = FakeAutomationSystem(running: true, answer: noErr)
        let live = MacPermissionSystem(homeDirectory: URL(filePath: "/synthetic/home"), automation: fake)
        #expect(live.check(.automation(bundleID: bundleID)) == .granted)
        #expect(fake.asks == 0)
    }
}

/// An Apple Event Manager that answers from settings and starts nothing.
nonisolated final class FakeAutomationSystem: AutomationSystem {
    private struct State {
        var running: Bool
        var answer: OSStatus
        var answerAfterLaunch: OSStatus = noErr
        var launchSucceeds = true
        var notFoundAsks = 0
        var launches = 0
        var asks = 0
    }

    private let state: Mutex<State>

    init(running: Bool, answer: OSStatus = noErr) {
        state = Mutex(State(running: running, answer: answer))
    }

    var launches: Int { state.withLock { $0.launches } }
    var asks: Int { state.withLock { $0.asks } }

    var answerAfterLaunch: OSStatus {
        get { state.withLock { $0.answerAfterLaunch } }
        set { state.withLock { $0.answerAfterLaunch = newValue } }
    }

    var launchSucceeds: Bool {
        get { state.withLock { $0.launchSucceeds } }
        set { state.withLock { $0.launchSucceeds = newValue } }
    }

    /// How many asks after a launch still find no app, as just after it started.
    var notFoundAsks: Int {
        get { state.withLock { $0.notFoundAsks } }
        set { state.withLock { $0.notFoundAsks = newValue } }
    }

    func setRunning(_ running: Bool, answer: OSStatus) {
        state.withLock { state in
            state.running = running
            state.answer = answer
        }
    }

    func isRunning(_ bundleID: String) -> Bool {
        state.withLock { $0.running }
    }

    func launchHidden(_ bundleID: String) async -> Bool {
        state.withLock { state in
            state.launches += 1
            guard state.launchSucceeds else { return false }
            state.running = true
            state.answer = state.answerAfterLaunch
            return true
        }
    }

    func determine(_ bundleID: String, askingIfNeeded: Bool) -> OSStatus {
        state.withLock { state in
            if askingIfNeeded { state.asks += 1 }
            guard state.running else { return OSStatus(procNotFound) }
            if askingIfNeeded, state.notFoundAsks > 0 {
                state.notFoundAsks -= 1
                return OSStatus(procNotFound)
            }
            return state.answer
        }
    }
}
