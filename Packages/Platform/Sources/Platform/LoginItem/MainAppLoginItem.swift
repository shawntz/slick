import KitHosting
import ServiceManagement

/// The live login item switch, on `SMAppService.mainApp`. Registering may post a system
/// notification, so only the user's switch in settings calls ``setEnabled(_:)``. Never called in
/// tests.
@MainActor public final class MainAppLoginItem: LoginItemControl {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the app is registered but the user has to allow it in System Settings.
    public var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens the Login Items pane, where the user allows a registration that needs approval.
    public func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// A login item switch in memory, for run environments other than `live`.
@MainActor public final class MemoryLoginItem: LoginItemControl {
    public private(set) var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
