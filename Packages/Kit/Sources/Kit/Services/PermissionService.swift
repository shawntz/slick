/// Checks and requests permissions.
///
/// The rule is that Slick never prompts by surprise. ``status(of:)`` never prompts. ``request(_:)``
/// may show a system prompt, so only the host calls it, and only right after the user pressed a
/// button that says what will happen. Features see a ``PermissionReader`` on their context and ask
/// through ``ActionContext/requestPermission(_:)`` or, better, by declaring ``Action/requires``.
public protocol PermissionService: Sendable {
    /// The current status. Never prompts, never blocks.
    func status(of permission: Permission) -> PermissionStatus

    /// Asks the system for the permission and returns the new status. May show a prompt.
    func request(_ permission: Permission) async -> PermissionStatus

    /// Opens the System Settings pane where the user grants the permission by hand.
    func openSettings(for permission: Permission) async

    /// The permission's status each time it changes from now on, such as when the user grants it in
    /// System Settings. Never prompts. The live service checks only while a stream is open, so keep
    /// one open only while something waits on the answer. It ends when the consuming task is
    /// cancelled.
    func changes(of permission: Permission) -> AsyncStream<PermissionStatus>
}

/// The read-only view of permissions a feature gets on its context.
public struct PermissionReader: Sendable {
    private let service: any PermissionService

    public init(_ service: any PermissionService) {
        self.service = service
    }

    /// The current status. Never prompts.
    public func status(of permission: Permission) -> PermissionStatus {
        service.status(of: permission)
    }

    /// True when the permission is granted.
    public func isGranted(_ permission: Permission) -> Bool {
        service.status(of: permission).isGranted
    }

    /// The status each time it changes from now on. Use it to start work that waited for a grant,
    /// such as text expansion after the user allows Input Monitoring.
    public func changes(of permission: Permission) -> AsyncStream<PermissionStatus> {
        service.changes(of: permission)
    }
}
