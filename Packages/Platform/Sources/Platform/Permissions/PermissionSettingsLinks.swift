import Foundation
import Kit

/// The System Settings pane where the user grants each permission by hand.
nonisolated public enum PermissionSettingsLinks {
    /// Privacy and Security.
    static let privacyAndSecurity = "x-apple.systempreferences:com.apple.preference.security"

    /// The pane's URL. Paste from Other Apps opens Privacy and Security itself: Apple asked a
    /// developer not to link to that pane directly.
    public static func url(for permission: Permission) -> URL {
        let anchor: String? =
            switch permission {
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            case .screenRecording: "Privacy_ScreenCapture"
            case .fullDiskAccess: "Privacy_AllFiles"
            case .calendars: "Privacy_Calendars"
            case .reminders: "Privacy_Reminders"
            case .contacts: "Privacy_Contacts"
            case .location: "Privacy_LocationServices"
            case .automation: "Privacy_Automation"
            case .protectedFolder: "Privacy_FilesAndFolders"
            case .pasteboard: nil
            }
        return URL(string: anchor.map { privacyAndSecurity + "?" + $0 } ?? privacyAndSecurity)!
    }
}
