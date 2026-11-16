import Kit

/// The groups that the permissions step and the Permissions pane list permissions in, each under a
/// small heading, in this order. A group with no permission is left out.
///
/// - Typing and Pasting: Accessibility, Input Monitoring, Paste from Other Apps.
/// - Files and Folders: Full Disk Access first, then Desktop, Documents, Downloads, iCloud Drive,
///   removable volumes and network volumes.
/// - Calendar and Contacts: Calendars, Reminders, Contacts, then Location Services, which fits no
///   group and sits with the other personal data.
/// - Other Apps: every Automation permission, in the order features name them, then Screen
///   Recording, which reads other apps' window titles.
/// - Network: Local Network. Kit has no such permission yet, so the group shows only once one is
///   added.
enum PermissionGroup: Int, CaseIterable, Comparable {
    case typing
    case files
    case personal
    case otherApps
    case network

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .typing: "Typing and Pasting"
        case .files: "Files and Folders"
        case .personal: "Calendar and Contacts"
        case .otherApps: "Other Apps"
        case .network: "Network"
        }
    }

    /// The group a permission belongs to.
    static func of(_ permission: Permission) -> PermissionGroup {
        switch permission {
        case .accessibility, .inputMonitoring, .pasteboard: .typing
        case .fullDiskAccess, .protectedFolder: .files
        case .calendars, .reminders, .contacts, .location: .personal
        case .automation, .screenRecording: .otherApps
        }
    }

    /// Where a permission sits inside its group. Permissions with the same place keep the order
    /// features name them in.
    static func place(of permission: Permission) -> Int {
        switch permission {
        case .accessibility: 0
        case .inputMonitoring: 1
        case .pasteboard: 2
        case .fullDiskAccess: 0
        case .protectedFolder(.desktop): 1
        case .protectedFolder(.documents): 2
        case .protectedFolder(.downloads): 3
        case .protectedFolder(.iCloudDrive): 4
        case .protectedFolder(.removableVolumes): 5
        case .protectedFolder(.networkVolumes): 6
        case .calendars: 0
        case .reminders: 1
        case .contacts: 2
        case .location: 3
        case .automation: 0
        case .screenRecording: 1
        }
    }

    /// The items in group order, each group's items in their places, ties in the order given.
    static func sorted<Item>(_ items: [Item], by permission: (Item) -> Permission) -> [Item] {
        items.enumerated()
            .sorted { lhs, rhs in
                let left = permission(lhs.element)
                let right = permission(rhs.element)
                let leftKey = (of(left).rawValue, place(of: left), lhs.offset)
                let rightKey = (of(right).rawValue, place(of: right), rhs.offset)
                return leftKey < rightKey
            }
            .map(\.element)
    }

    /// The items split into their groups, in order, leaving out groups with no item.
    static func grouped<Item>(_ items: [Item], by permission: (Item) -> Permission) -> [(
        group: PermissionGroup, items: [Item]
    )] {
        let ordered = sorted(items, by: permission)
        return allCases.compactMap { group in
            let members = ordered.filter { of(permission($0)) == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// The line under Full Disk Access's reasons when folders it also allows are listed below it.
    /// It says what ``Platform``'s permission center does: Full Disk Access granted counts as every
    /// protected folder granted except iCloud Drive.
    static let fullDiskAccessCoversFolders = "Allowing this also allows the folders below, except iCloud Drive."

    /// True when the listed permissions include a folder that Full Disk Access also allows.
    static func listsFolderFullDiskAccessAllows(_ permissions: [Permission]) -> Bool {
        permissions.contains { permission in
            if case .protectedFolder(let folder) = permission { return folder != .iCloudDrive }
            return false
        }
    }
}

extension Permission {
    /// Where in System Settings a person allows the permission by hand, after Privacy & Security.
    /// Nil for one that only Privacy & Security itself leads to.
    var settingsPlace: String? {
        switch self {
        case .protectedFolder: "Files & Folders"
        case .pasteboard: nil
        default: displayName
        }
    }
}
