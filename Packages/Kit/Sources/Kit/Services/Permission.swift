/// A macOS permission a feature may need.
public enum Permission: Hashable, Sendable, Codable {
    /// Moving other apps' windows, pasting, reading the selection, typing text.
    case accessibility
    /// Watching keystrokes, for text expansion and double-tap hotkeys.
    case inputMonitoring
    /// Reading other apps' window titles.
    case screenRecording
    /// Reading protected files such as browser bookmarks. macOS offers no request; the host opens the
    /// right settings pane.
    case fullDiskAccess
    case calendars
    case reminders
    case contacts
    case location
    /// Reading what other apps copied. No prompt exists on macOS 27.2; the status reports whether a
    /// future system would ask.
    case pasteboard
    /// Sending Apple Events to the app with this bundle ID.
    case automation(bundleID: String)
    /// Reading a folder macOS guards on its own, such as Desktop. The first read shows a system
    /// prompt, so a file index lists these folders only after the user granted them through the
    /// host's card, or granted Full Disk Access.
    case protectedFolder(ProtectedFolder)

    /// The name System Settings uses.
    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .location: "Location Services"
        case .pasteboard: "Paste from Other Apps"
        case .automation: "Automation"
        case .protectedFolder(let folder): folder.displayName
        }
    }
}

/// A folder whose first read macOS guards with its own prompt.
public enum ProtectedFolder: String, Hashable, Sendable, Codable, CaseIterable {
    case desktop
    case documents
    case downloads
    case removableVolumes
    case networkVolumes

    /// The name System Settings uses under Files and Folders.
    public var displayName: String {
        switch self {
        case .desktop: "Desktop Folder"
        case .documents: "Documents Folder"
        case .downloads: "Downloads Folder"
        case .removableVolumes: "Removable Volumes"
        case .networkVolumes: "Network Volumes"
        }
    }
}

/// Where a permission stands.
public enum PermissionStatus: Hashable, Sendable {
    case granted
    case denied
    /// Never asked. Requesting may show a system prompt.
    case notDetermined
    /// Blocked by a profile or parental control; the user cannot grant it.
    case restricted

    public var isGranted: Bool { self == .granted }
}

/// A permission with the reason a feature gives for it, shown before the host asks.
public struct PermissionNeed: Hashable, Sendable {
    public var permission: Permission
    /// One sentence, starting with a verb: "Paste the selected entry into the frontmost app."
    public var reason: String

    public init(_ permission: Permission, reason: String) {
        self.permission = permission
        self.reason = reason
    }
}
