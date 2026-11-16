import Kit

/// The grant flow behind every Grant button in settings and onboarding.
///
/// It runs only after the user pressed a button that names the permission. The system can ask only
/// once: a permission it has never asked about is requested, and one the user denied, or one macOS
/// offers no request for, opens its System Settings pane instead. When the flow ends with the
/// permission granted, and it was not before, the features hear of it through the announcer.
///
/// An Automation permission that was never asked, whose app is not running, is never requested
/// here: a request would have to start the app. Its row says when macOS asks instead.
struct PermissionGrant {
    let service: any PermissionService
    let custom: (@MainActor (Permission) async -> PermissionStatus)?
    let announcer: GrantAnnouncer?
    let permissionWaitsForApp: @MainActor (Permission) -> Bool

    init(
        service: any PermissionService, custom: (@MainActor (Permission) async -> PermissionStatus)?,
        announcer: GrantAnnouncer? = nil,
        waitsForApp: @escaping @MainActor (Permission) -> Bool = SettingsDependencies.everyAutomationWaits
    ) {
        self.service = service
        self.custom = custom
        self.announcer = announcer
        permissionWaitsForApp = waitsForApp
    }

    /// True when the permission was never asked and can be asked only once its app runs. Settings
    /// then shows ``waitingSentence(appName:)`` and no button.
    func waitsForApp(_ permission: Permission, status: PermissionStatus) -> Bool {
        status == .notDetermined && permissionWaitsForApp(permission)
    }

    /// What a row says in place of an Allow button while its permission waits for its app.
    static func waitingSentence(appName: String?) -> String {
        "macOS asks the first time you control \(appName ?? "this app") while it is open."
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
        let status = service.status(of: permission)
        // Asking would start the app, which a settings button never does.
        if waitsForApp(permission, status: status) { return status }
        if let custom { return await custom(permission) }
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
