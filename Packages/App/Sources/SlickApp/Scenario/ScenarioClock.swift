import Foundation
import Kit
import Synchronization

/// The clock of a scenario run. It reads the real time plus an offset that a `setTime` step moves
/// forward, in UTC and US English, so a scenario reads the same hours, dates and numbers on every
/// Mac. A file's `startTime` starts it at a fixed moment, so a scenario that names dates passes on
/// any day it runs.
///
/// A wait ends when the run's time reaches its end, either because real time passed or because a
/// step moved the clock past it. So root search's hourly tick and every feature's timer wake when a
/// scenario jumps to the next morning, and nothing waits on the real hours in between.
nonisolated final class ScenarioClock: ClockService, Sendable {
    private struct State {
        var offset: TimeInterval = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<Int> = []
        var nextWaiter = 0
    }

    private let state: Mutex<State>
    /// What `Date()` reads. Tests replace it to stand still.
    private let realNow: @Sendable () -> Date

    /// - Parameters:
    ///   - start: The run's time at this moment. Nil starts at the real time.
    ///   - realNow: The real time. Tests replace it.
    init(startingAt start: Date? = nil, realNow: @escaping @Sendable () -> Date = { Date() }) {
        self.realNow = realNow
        state = Mutex(State(offset: start.map { $0.timeIntervalSince(realNow()) } ?? 0))
    }

    var now: Date {
        realNow().addingTimeInterval(state.withLock { $0.offset })
    }

    let timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let locale = Locale(identifier: "en_US")

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// Moves the run's time forward to `date` and wakes every wait that it reaches. False, and
    /// nothing changes, when `date` is not later than now: a run's time never goes back.
    @discardableResult
    func move(to date: Date) -> Bool {
        let woken = state.withLock { state -> [CheckedContinuation<Void, Never>]? in
            let current = realNow().addingTimeInterval(state.offset)
            guard date > current else { return nil }
            state.offset += date.timeIntervalSince(current)
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        guard let woken else { return false }
        for waiter in woken { waiter.resume() }
        return true
    }

    func sleep(for duration: Duration) async throws {
        let parts = duration.components
        let end = now.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        while true {
            try Task.checkCancellation()
            let left = end.timeIntervalSince(now)
            guard left > 0 else { return }
            // Whichever comes first: the real time left, or a move of the clock. Then look again.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(for: .seconds(left)) }
                group.addTask { await self.nextMove() }
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// How many waits are parked until the next move. For tests.
    var waitingCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// Returns at the next ``move(to:)``, or when the task is cancelled.
    private func nextMove() async {
        let id = state.withLock { state -> Int in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.cancelled.remove(id) != nil { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let continuation = state.waiters.removeValue(forKey: id) { return continuation }
                state.cancelled.insert(id)
                return nil
            }
            continuation?.resume()
        }
        // A cancel that came after a move left its mark; drop it.
        state.withLock { _ = $0.cancelled.remove(id) }
    }
}
