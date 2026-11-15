import Kit
import KitHosting
import ServiceManagement

/// The live login item switch, on `SMAppService.mainApp`. Registering may post a system
/// notification, so only the user's switch in settings calls ``setEnabled(_:)``. Never called in
/// tests.
///
/// When the user turned the app off in Login Items before, registering succeeds but macOS waits
/// for approval. Then the switch opens the Login Items pane and throws
/// ``LoginItemError/needsApproval``, so settings says what to do instead of the switch flipping
/// back without a word.
@MainActor public final class MainAppLoginItem: LoginItemControl {
    private let service: any LoginItemService

    /// - Parameter service: The registration. Tests pass a fake; the default is the app's own.
    public init(service: any LoginItemService = MainAppLoginItemService()) {
        self.service = service
    }

    public var isEnabled: Bool {
        service.status == .enabled
    }

    /// True when the app is registered but the user has to allow it in System Settings.
    public var needsApproval: Bool {
        service.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        let status = service.status
        if enabled {
            if status == .enabled { return }
            if status != .requiresApproval { try service.register() }
            if service.status == .requiresApproval {
                service.openLoginItemsSettings()
                throw LoginItemError.needsApproval
            }
        } else {
            // Unregistering what is not registered fails, and there is nothing to undo.
            if status == .notRegistered || status == .notFound { return }
            try service.unregister()
        }
    }

    /// Opens the Login Items pane, where the user allows a registration that needs approval.
    public func openSettings() {
        service.openLoginItemsSettings()
    }
}

/// What ``MainAppLoginItem`` asks of ServiceManagement.
@MainActor public protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

/// The app's own registration, `SMAppService.mainApp`.
@MainActor public final class MainAppLoginItemService: LoginItemService {
    public init() {}

    public var status: SMAppService.Status { SMAppService.mainApp.status }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Why the login item switch did not turn on.
nonisolated public enum LoginItemError: Error, Hashable, Sendable, LocalizedError {
    /// The user has to allow the app in Login Items, which is now open in System Settings.
    case needsApproval

    /// A title, as settings shows it on a toast.
    public var errorDescription: String? {
        switch self {
        case .needsApproval: "Allow \(Brand.name) in Login Items"
        }
    }

    public var failureReason: String? {
        switch self {
        case .needsApproval: "Turn on \(Brand.name) in Login Items in System Settings, which is open now."
        }
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
