import Kit
import KitHosting

/// Tells the features when a permission turns granted while the settings window or onboarding
/// watches it, through ``KitHosting/FeatureDirectory/permissionGranted(_:)``. A Grant button and a
/// pane's status stream may both see one grant; the features hear of it once.
///
/// Call ``watch(_:)`` before a grant flow starts or when a pane starts following a status, and
/// ``check(_:)`` after the flow returns or when the status may have changed. A permission is
/// announced only when it was seen not granted and is now granted, so a permission that was
/// granted all along is never announced.
final class GrantAnnouncer {
    private let service: any PermissionService
    private let directory: any FeatureDirectory
    private var seen: [Permission: PermissionStatus] = [:]

    init(service: any PermissionService, directory: any FeatureDirectory) {
        self.service = service
        self.directory = directory
    }

    /// Remembers the status now, unless one is remembered already.
    func watch(_ permission: Permission) {
        if seen[permission] == nil { seen[permission] = service.status(of: permission) }
    }

    /// Reads the status again and tells the features when it turned granted since it was last seen.
    func check(_ permission: Permission) async {
        let now = service.status(of: permission)
        let before = seen[permission]
        seen[permission] = now
        guard now == .granted, let before, before != .granted else { return }
        await directory.permissionGranted(permission)
    }
}
