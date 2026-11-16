import Kit

/// The grant flow behind every Grant button in settings and onboarding.
///
/// It runs only after the user pressed a button that names the permission. The system can ask only
/// once: a permission it has never asked about is requested, and one the user denied, or one macOS
/// offers no request for, opens its System Settings pane instead. When the flow ends with the
/// permission granted, and it was not before, the features hear of it through the announcer.
struct PermissionGrant {
    let service: any PermissionService
    let custom: (@MainActor (Permission) async -> PermissionStatus)?
    let announcer: GrantAnnouncer?

    init(
        service: any PermissionService, custom: (@MainActor (Permission) async -> PermissionStatus)?,
        announcer: GrantAnnouncer? = nil
    ) {
        self.service = service
        self.custom = custom
        self.announcer = announcer
    }

    /// The current status. Never prompts.
    func status(of permission: Permission) -> PermissionStatus {
        service.status(of: permission)
    }

    /// Runs the grant flow and returns the status after it. Tells the features when it granted the
    /// permission.
    func grant(_ permission: Permission) async -> PermissionStatus {
        announcer?.watch(permission)
        let status = await flow(permission)
        await announcer?.check(permission)
        return status
    }

    private func flow(_ permission: Permission) async -> PermissionStatus {
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
