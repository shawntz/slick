import Foundation
import KitHosting
import KitTesting
import Synchronization

/// The system context in memory. Nothing is read from the Mac; the simulate methods play changes.
///
/// Call ``settle()`` after a simulate method to wait until every consumer of the streams has
/// handled what it received.
public final class FakeSystemContext: SystemContextService {
    private let state: Mutex<SystemContext>
    private let contexts = FakeBroadcast<SystemContext>()
    private let sessions = FakeBroadcast<Date>()

    /// - Parameter context: The starting context. Defaults to a synthetic editor app in front, on
    ///   power, one display, built-in speakers and no Focus.
    public init(
        _ context: SystemContext = SystemContext(
            frontmostBundleID: "com.example.editor", onBattery: false, displayCount: 1, audioRoute: .builtIn,
            isFocusOn: false)
    ) {
        state = Mutex(context)
    }

    public func current() -> SystemContext {
        state.withLock { $0 }
    }

    public func changes() -> AsyncStream<SystemContext> {
        contexts.stream()
    }

    public func sessionStarts() -> AsyncStream<Date> {
        sessions.stream()
    }

    /// Replaces the context. Every ``changes()`` stream hears of it when it differs from the last.
    public func simulate(_ context: SystemContext) {
        let changed = state.withLock { state in
            defer { state = context }
            return state != context
        }
        if changed { contexts.send(context) }
    }

    /// Changes part of the context, as in `simulateChange { $0.onBattery = true }`.
    public func simulateChange(_ change: (inout SystemContext) -> Void) {
        var context = current()
        change(&context)
        simulate(context)
    }

    /// Plays the Mac waking or the screen unlocking at a moment.
    public func simulateSessionStart(at date: Date) {
        sessions.send(date)
    }

    /// How many streams are open, both kinds together.
    public var listenerCount: Int {
        contexts.listenerCount + sessions.listenerCount
    }

    /// Returns once every stream's consumer has handled everything it received.
    public func settle() async {
        await contexts.waitUntilIdle()
        await sessions.waitUntilIdle()
    }
}
