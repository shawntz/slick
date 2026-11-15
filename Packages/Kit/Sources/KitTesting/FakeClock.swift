import Foundation
import Kit
import Synchronization

/// A clock that stands still until a test moves it. ``sleep(for:)`` waits until ``advance(by:)``
/// passes its deadline, so debounces and timers run instantly and in a fixed order.
///
/// The default time zone is UTC and the default locale `en_US_POSIX`, so formatted dates in tests do
/// not depend on the machine.
public final class FakeClock: ClockService {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var cancelledBeforeSleeping: Set<Int> = []
        var nextID = 0
    }

    private let state: Mutex<State>
    public let timeZone: TimeZone
    public let locale: Locale

    /// - Parameter now: The starting time. Defaults to 2026-11-14 09:30 UTC, a Saturday.
    public init(
        now: Date = Date(timeIntervalSince1970: 1_794_648_600),
        timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .gmt,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) {
        state = Mutex(State(now: now))
        self.timeZone = timeZone
        self.locale = locale
    }

    public var now: Date { state.withLock { $0.now } }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// How many tasks are waiting in ``sleep(for:)``.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Sets the time without waking sleepers whose deadline passed; call ``advance(by:)`` for that.
    public func set(_ date: Date) {
        state.withLock { $0.now = date }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed. Sleepers woken by one call
    /// resume as separate tasks, in no guaranteed order; advance in steps to order them.
    public func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.addingTimeInterval(duration.fakeClockSeconds)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Waits until at least `count` tasks are sleeping, so a test can advance time knowing the work
    /// it scheduled is waiting. Gives up after `limit` yields.
    public func waitForSleepers(_ count: Int = 1, limit: Int = 10_000) async {
        var attempts = 0
        while sleeperCount < count, attempts < limit {
            attempts += 1
            await Task.yield()
        }
    }

    public func sleep(for duration: Duration) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case wait, wake, cancel }
                let start = state.withLock { state -> Start in
                    if state.cancelledBeforeSleeping.remove(id) != nil { return .cancel }
                    let deadline = state.now.addingTimeInterval(duration.fakeClockSeconds)
                    if deadline <= state.now { return .wake }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch start {
                case .wait: break
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledBeforeSleeping.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

extension Duration {
    fileprivate var fakeClockSeconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
