import Foundation
import Synchronization

/// Running apps that exist only in memory, for scenarios, self-tests and tests. Quitting removes an
/// app from the list and records the request; no real process is touched.
nonisolated final class SimulatedRunningApps: RunningAppsService {
    /// What a caller asked the service to do.
    enum Request: Hashable, Sendable {
        case quit(pid: Int32)
        case forceQuit(pid: Int32)
        case hide(pid: Int32)
    }

    private struct State {
        var apps: [RunningApp]
        var requests: [Request] = []
        /// Apps that ignore a quit request, as an app with unsaved changes does.
        var refusesToQuit: Set<Int32> = []
        var listeners: [Int: AsyncStream<Void>.Continuation] = [:]
        var nextListener = 0
    }

    private let state: Mutex<State>

    init(_ apps: [RunningApp] = []) {
        state = Mutex(State(apps: apps))
    }

    /// Every request, in order.
    var requests: [Request] { state.withLock { $0.requests } }

    /// Starts an app, as if the user opened it.
    func launch(_ app: RunningApp) {
        change { $0.apps.append(app) }
    }

    /// Ends an app, as if it quit by itself.
    func terminate(pid: Int32) {
        change { $0.apps.removeAll { $0.pid == pid } }
    }

    /// Makes an app ignore quit requests.
    func refuseToQuit(pid: Int32) {
        state.withLock { _ = $0.refusesToQuit.insert(pid) }
    }

    func apps() async -> [RunningApp] {
        state.withLock { $0.apps }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            return state.nextListener
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        return stream
    }

    func quit(_ app: RunningApp) async -> Bool {
        change { state in
            state.requests.append(.quit(pid: app.pid))
            if !state.refusesToQuit.contains(app.pid) {
                state.apps.removeAll { $0.pid == app.pid }
            }
        }
        return true
    }

    func forceQuit(_ app: RunningApp) async -> Bool {
        change { state in
            state.requests.append(.forceQuit(pid: app.pid))
            state.apps.removeAll { $0.pid == app.pid }
        }
        return true
    }

    func hide(_ app: RunningApp) async -> Bool {
        change { state in
            state.requests.append(.hide(pid: app.pid))
            if let index = state.apps.firstIndex(where: { $0.pid == app.pid }) {
                state.apps[index].isHidden = true
            }
        }
        return true
    }

    func waitUntilQuit(_ app: RunningApp, timeout: Duration) async -> Bool {
        state.withLock { state in !state.apps.contains { $0.pid == app.pid } }
    }

    /// Applies a change, then tells every listener.
    private func change(_ body: (inout State) -> Void) {
        let listeners = state.withLock { state in
            body(&state)
            return Array(state.listeners.values)
        }
        for listener in listeners {
            listener.yield()
        }
    }
}
