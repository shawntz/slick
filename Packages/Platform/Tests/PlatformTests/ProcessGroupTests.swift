import Darwin
import Foundation
import Synchronization
import Testing

@testable import Platform

/// The one function that signals. Every test here replaces the system call with a recorder, so no
/// test in this suite sends a real signal.
@Suite(.timeLimit(.minutes(1))) struct ProcessGroupTests {
    @Test func idsBelowTwoAreRefusedEvenWhenAdmitted() {
        let recorder = SignalRecorder()
        let groups = ProcessGroups(systemCall: recorder.call)
        for id: pid_t in [1, 0, -1, -4242, .min] {
            groups.admit(id)
            #expect(!groups.send(SIGTERM, toGroup: id))
            #expect(!groups.send(SIGKILL, toGroup: id))
        }
        #expect(groups.liveGroups.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func aGroupThatWasNeverAdmittedIsRefused() {
        let recorder = SignalRecorder()
        let groups = ProcessGroups(systemCall: recorder.call)
        groups.admit(4242)
        #expect(!groups.send(SIGTERM, toGroup: 4243))
        #expect(!groups.send(SIGTERM, toGroup: 2))
        #expect(recorder.calls.isEmpty)
    }

    @Test func aLiveGroupGetsTheSignalThroughTheSystemCall() {
        let recorder = SignalRecorder()
        let groups = ProcessGroups(systemCall: recorder.call)
        groups.admit(4242)
        #expect(groups.send(SIGTERM, toGroup: 4242))
        #expect(groups.send(SIGKILL, toGroup: 4242))
        #expect(recorder.calls == [.init(group: 4242, signal: SIGTERM), .init(group: 4242, signal: SIGKILL)])
    }

    @Test func aRetiredGroupIsRefused() {
        let recorder = SignalRecorder()
        let groups = ProcessGroups(systemCall: recorder.call)
        groups.admit(4242)
        groups.retire(4242)
        #expect(!groups.send(SIGTERM, toGroup: 4242))
        #expect(!groups.send(SIGKILL, toGroup: 4242))
        #expect(groups.liveGroups.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func aSystemCallThatFailsIsReportedAsNotSent() {
        let recorder = SignalRecorder(result: -1)
        let groups = ProcessGroups(systemCall: recorder.call)
        groups.admit(4242)
        #expect(!groups.send(SIGTERM, toGroup: 4242))
        #expect(recorder.calls.count == 1)
    }

    /// A retire that races a signal either lands after the signal or refuses it. It never lets a
    /// signal through once it has returned.
    @Test func noSignalPassesOnceTheGroupIsRetired() async {
        let recorder = SignalRecorder()
        let groups = ProcessGroups(systemCall: recorder.call)
        for group: pid_t in 100..<300 { groups.admit(group) }
        await withTaskGroup(of: Void.self) { tasks in
            for group: pid_t in 100..<300 {
                tasks.addTask { groups.send(SIGTERM, toGroup: group) }
                tasks.addTask { groups.retire(group) }
            }
        }
        for group: pid_t in 100..<300 {
            #expect(!groups.send(SIGKILL, toGroup: group))
        }
        #expect(recorder.calls.allSatisfy { $0.signal == SIGTERM })
        #expect(groups.liveGroups.isEmpty)
    }
}

/// Records each signal the runner would send. It sends none unless a test passes the real call.
nonisolated final class SignalRecorder: Sendable {
    struct Call: Hashable, Sendable {
        var group: pid_t
        var signal: Int32
    }

    private let recorded = Mutex<[Call]>([])
    private let result: Int32
    private let forward: ProcessGroups.SystemCall?

    init(result: Int32 = 0, forward: ProcessGroups.SystemCall? = nil) {
        self.result = result
        self.forward = forward
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    var call: ProcessGroups.SystemCall {
        { [self] group, signal in
            recorded.withLock { $0.append(Call(group: group, signal: signal)) }
            return forward?(group, signal) ?? result
        }
    }
}
