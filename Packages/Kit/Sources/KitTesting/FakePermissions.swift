import Kit
import Synchronization

/// Permissions in memory. Every permission is granted unless a test says otherwise with
/// ``set(_:to:)``. Requests are recorded, so a test can assert that nothing asked by surprise.
public final class FakePermissions: PermissionService {
    private struct State {
        var statuses: [Permission: PermissionStatus] = [:]
        var defaultStatus: PermissionStatus
        var answer: PermissionStatus = .granted
        var requests: [Permission] = []
        var openedSettings: [Permission] = []
    }

    private struct Change: Sendable {
        var permission: Permission
        var status: PermissionStatus
    }

    private let state: Mutex<State>
    private let broadcast = FakeBroadcast<Change>()

    /// - Parameter defaultStatus: The status of every permission not set explicitly.
    public init(defaultStatus: PermissionStatus = .granted) {
        state = Mutex(State(defaultStatus: defaultStatus))
    }

    /// Sets a permission's status, as if the user changed it in System Settings. Every
    /// ``changes(of:)`` stream for it hears of the change.
    public func set(_ permission: Permission, to status: PermissionStatus) {
        let changed = state.withLock { state in
            let previous = state.statuses[permission] ?? state.defaultStatus
            state.statuses[permission] = status
            return previous != status
        }
        if changed { broadcast.send(Change(permission: permission, status: status)) }
    }

    /// What the user answers when a permission is requested. Default `.granted`.
    public var answer: PermissionStatus {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }

    /// Every request, in order. In the app each one may have shown a system prompt.
    public var requests: [Permission] { state.withLock { $0.requests } }

    /// Permissions whose settings pane was opened.
    public var openedSettings: [Permission] { state.withLock { $0.openedSettings } }

    /// Returns once every ``changes(of:)`` consumer has handled every change it received.
    public func settle() async {
        await broadcast.waitUntilIdle()
    }

    var isSettled: Bool { broadcast.isIdle }

    /// The ``changes(of:)`` streams open now. In the app each one checks the system every second,
    /// so a feature should hold one only while it waits for a grant.
    public var openStreamCount: Int { broadcast.listenerCount }

    public func status(of permission: Permission) -> PermissionStatus {
        state.withLock { $0.statuses[permission] ?? $0.defaultStatus }
    }

    public func request(_ permission: Permission) async -> PermissionStatus {
        let answer = state.withLock { state in
            state.requests.append(permission)
            return state.answer
        }
        set(permission, to: answer)
        return answer
    }

    public func openSettings(for permission: Permission) async {
        state.withLock { $0.openedSettings.append(permission) }
    }

    public func changes(of permission: Permission) -> AsyncStream<PermissionStatus> {
        broadcast.stream { $0.permission == permission ? $0.status : nil }
    }
}
