import AppKit
import Foundation
import Synchronization

/// Whether one of this app's windows has key focus. The launcher's panel takes key focus without
/// making the app frontmost, so the frontmost app alone cannot tell where typing goes. Text
/// expansion ignores typing while this is true, and a paste waits until it is false.
nonisolated public final class OwnKeyFocus: Sendable {
    private let state = Mutex(false)
    private let changed = Broadcast<Void>()

    public init() {}

    /// True while one of this app's windows is key.
    public var isKey: Bool {
        state.withLock { $0 }
    }

    /// A signal each time key focus enters or leaves this app's windows, from now on.
    public func changes() -> AsyncStream<Void> {
        changed.stream()
    }

    /// Records where key focus is. Streams hear of it only when it changed.
    public func set(_ isKey: Bool) {
        let didChange = state.withLock { current -> Bool in
            defer { current = isKey }
            return current != isKey
        }
        if didChange { changed.send(()) }
    }
}

/// Feeds an ``OwnKeyFocus`` from AppKit's key window notifications, which only this app's own
/// windows post. Reads nothing from other apps.
@MainActor public final class OwnKeyFocusObserver {
    private let focus: OwnKeyFocus
    private let notifications: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter notifications: Where windows post. Tests pass a private center.
    public init(focus: OwnKeyFocus, notifications: NotificationCenter = .default) {
        self.focus = focus
        self.notifications = notifications
    }

    isolated deinit {
        stop()
    }

    /// Starts listening. Calling it again does nothing.
    public func start() {
        guard observers.isEmpty else { return }
        // A window resigns before the next one becomes key, so the last notification wins.
        let pairs: [(Notification.Name, Bool)] = [
            (NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false),
        ]
        for (name, isKey) in pairs {
            observers.append(
                notifications.addObserver(forName: name, object: nil, queue: nil) { [focus] _ in
                    focus.set(isKey)
                })
        }
    }

    public func stop() {
        for observer in observers {
            notifications.removeObserver(observer)
        }
        observers = []
    }
}

/// One stream that signals whenever any of the given streams does. It ends the given streams when
/// it ends.
nonisolated func mergedSignals(_ streams: [AsyncStream<Void>]) -> AsyncStream<Void> {
    let (merged, continuation) = AsyncStream.makeStream(of: Void.self)
    let relays = streams.map { stream in
        Task {
            for await _ in stream {
                continuation.yield()
            }
        }
    }
    continuation.onTermination = { _ in
        for relay in relays {
            relay.cancel()
        }
    }
    return merged
}
