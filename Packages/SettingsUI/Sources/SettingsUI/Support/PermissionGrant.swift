import Kit

/// The grant flow behind every Grant button in settings and onboarding.
///
/// It runs only after the user pressed a button that names the permission. The system can ask only
/// once: a permission it has never asked about is requested, and one the user denied, or one macOS
/// offers no request for, opens its System Settings pane instead.
struct PermissionGrant {
    let service: any PermissionService
    let custom: (@MainActor (Permission) async -> PermissionStatus)?

    /// The current status. Never prompts.
    func status(of permission: Permission) -> PermissionStatus {
        service.status(of: permission)
    }

    /// Runs the grant flow and returns the status after it.
    func grant(_ permission: Permission) async -> PermissionStatus {
        if let custom { return await custom(permission) }
        let status = service.status(of: permission)
        if status == .granted || status == .restricted { return status }
        if status == .denied || !Self.systemCanAsk(permission) {
            await service.openSettings(for: permission)
            return service.status(of: permission)
        }
        return await service.request(permission)
    }

    /// Opens the permission's pane in System Settings.
    func openSettings(for permission: Permission) async {
        await service.openSettings(for: permission)
    }

    /// False for permissions that only System Settings can grant.
    static func systemCanAsk(_ permission: Permission) -> Bool {
        switch permission {
        case .fullDiskAccess: false
        default: true
        }
    }
}

extension PermissionStatus {
    /// How settings names the status.
    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .restricted: "Blocked by a profile"
        }
    }
}
