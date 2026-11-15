import Foundation
import KitHosting
import Synchronization

/// The live system context service: the last context the monitor saw, and streams of changes and
/// session starts. ``SystemContextMonitor`` feeds it on the Mac; elsewhere it holds a fixed
/// synthetic context.
///
/// Focus is always reported off: reading it needs the Focus Status permission, and this service
/// never asks for one.
nonisolated public final class SystemContextCenter: SystemContextService {
    private let state: Mutex<SystemContext>
    private let contexts = Broadcast<SystemContext>()
    private let sessions = Broadcast<Date>()

    public init(_ initial: SystemContext = SystemContext()) {
        state = Mutex(initial)
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

    /// Changes part of the context, as in `update { $0.onBattery = true }`. Streams hear of it
    /// only when the context differs from before.
    public func update(_ change: (inout SystemContext) -> Void) {
        let changed = state.withLock { context -> SystemContext? in
            var next = context
            change(&next)
            guard next != context else { return nil }
            context = next
            return next
        }
        if let changed { contexts.send(changed) }
    }

    /// Records that a session at the Mac started: it woke or the screen unlocked.
    public func sessionStarted(at date: Date) {
        sessions.send(date)
    }

    /// How many streams are open, of both kinds.
    public var listenerCount: Int {
        contexts.listenerCount + sessions.listenerCount
    }
}
