import AppKit
import Synchronization

/// The real running apps, from `NSWorkspace`. Used only when the app runs for a person; scenarios,
/// self-tests and tests get ``SimulatedRunningApps``.
///
/// The lab measured `NSWorkspace.runningApplications` at under 0.01 ms per read once warm: it is a
/// cached array the system keeps current while the main run loop runs. So the service reads it
/// afresh on each call and keeps no copy. It listens to the workspace's launch, quit, hide and
/// unhide notifications only while someone holds a stream from ``changes()``.
nonisolated final class WorkspaceRunningApps: RunningAppsService {
    private struct State {
        var listeners: [Int: AsyncStream<Void>.Continuation] = [:]
        var nextListener = 0
        var observers: [Observer] = []
    }

    /// A notification observer token. `NotificationCenter` may remove an observer from any thread, and
    /// the token is used for nothing else, so it can cross threads.
    private final class Observer: @unchecked Sendable {
        let token: any NSObjectProtocol

        init(_ token: any NSObjectProtocol) {
            self.token = token
        }
    }

    private let state = Mutex(State())

    private static let notifications: [Notification.Name] = [
        NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
        NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
    ]

    deinit {
        let observers = state.withLock { $0.observers }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer.token)
        }
    }

    @concurrent func apps() async -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { app in
                RunningApp(
                    pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                    path: app.bundleURL?.path, isHidden: app.isHidden)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let (id, needsObservers) = state.withLock { state in
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            return (state.nextListener, state.observers.isEmpty)
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        if needsObservers { startObserving() }
        return stream
    }

    @concurrent func quit(_ app: RunningApp) async -> Bool {
        NSRunningApplication(processIdentifier: app.pid)?.terminate() ?? false
    }

    @concurrent func forceQuit(_ app: RunningApp) async -> Bool {
        NSRunningApplication(processIdentifier: app.pid)?.forceTerminate() ?? false
    }

    @concurrent func hide(_ app: RunningApp) async -> Bool {
        NSRunningApplication(processIdentifier: app.pid)?.hide() ?? false
    }

    @concurrent func waitUntilQuit(_ app: RunningApp, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    /// Adds the workspace observers once. Their blocks run on the thread that posts, the main thread,
    /// and only signal: readers fetch the new state through ``apps()`` off the main thread.
    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        let observers = Self.notifications.map { name in
            Observer(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.signal()
                })
        }
        // Two streams may start at once; the second set of observers is removed again.
        let extra = state.withLock { state -> [Observer] in
            guard state.observers.isEmpty else { return observers }
            state.observers = observers
            return []
        }
        for observer in extra {
            center.removeObserver(observer.token)
        }
    }

    private func signal() {
        let listeners = state.withLock { Array($0.listeners.values) }
        for listener in listeners {
            listener.yield()
        }
    }
}
