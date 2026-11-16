import Kit
import KitHosting
import Observation

/// The permissions pane: every permission any feature's manifest names, the features that want it
/// and why, its live status, a Grant button and a link to System Settings.
@Observable final class PermissionsModel {
    /// One feature's need for a permission.
    struct Want: Identifiable, Hashable {
        var featureID: String
        var featureName: String
        var reason: String
        var isFeatureEnabled: Bool
        var id: String { featureID }
    }

    /// One permission and who wants it.
    struct Entry: Identifiable {
        var permission: Permission
        var wants: [Want]
        var status: PermissionStatus
        /// What the row says in place of Allow while the permission waits for its app to run.
        var waitingSentence: String?
        var id: String { permission.settingsKey }
    }

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()

    init(context: SettingsContext) {
        self.context = context
        tasks.follow(context.directory.changes, bumping: revision)
    }

    /// Every permission in the order features first name it.
    var entries: [Entry] {
        revision.track()
        var order: [Permission] = []
        var wants: [Permission: [Want]] = [:]
        for feature in context.directory.features {
            for need in feature.manifest.permissions {
                if wants[need.permission] == nil { order.append(need.permission) }
                wants[need.permission, default: []].append(
                    Want(
                        featureID: feature.id, featureName: feature.manifest.name, reason: need.reason,
                        isFeatureEnabled: feature.isEnabled))
            }
        }
        return order.map { permission in
            let status = context.permissions.status(of: permission)
            return Entry(
                permission: permission, wants: wants[permission] ?? [], status: status,
                waitingSentence: context.waitingSentence(for: permission, status: status))
        }
    }

    /// Runs the grant flow for a permission. Only a button the user pressed calls this.
    func grant(_ permission: Permission) async {
        _ = await context.permissions.grant(permission)
        revision.bump()
    }

    /// Opens the permission's pane in System Settings. The pane's status streams announce a grant
    /// made there.
    func openSettings(for permission: Permission) async {
        context.grants.watch(permission)
        await context.permissions.openSettings(for: permission)
    }

    /// Reads every status again.
    func refresh() {
        revision.bump()
    }

    /// Follows status changes of every listed permission while the pane is visible. The live
    /// service checks only while a stream is open, so the view runs this in a task that ends when
    /// the pane goes away. A permission the user granted in System Settings while the pane watched
    /// is announced to the features.
    func watch() async {
        let permissions = entries.map(\.permission)
        for permission in permissions { context.grants.watch(permission) }
        await withTaskGroup(of: Void.self) { group in
            for permission in permissions {
                let stream = context.services.permissions.changes(of: permission)
                group.addTask { [weak self] in
                    for await _ in stream { await self?.statusChanged(permission) }
                }
            }
        }
    }

    /// Reads every status again and tells the features when this one turned granted.
    func statusChanged(_ permission: Permission) async {
        refresh()
        await context.grants.check(permission)
    }
}

extension Permission {
    /// A stable string for lists and accessibility identifiers.
    var settingsKey: String {
        switch self {
        case .automation(let bundleID): "automation." + bundleID
        case .protectedFolder(let folder): "folder." + folder.rawValue
        default: displayName
        }
    }

    /// An SF Symbol for the permission.
    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .fullDiskAccess: "internaldrive"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .location: "location"
        case .pasteboard: "doc.on.clipboard"
        case .automation: "gearshape.2"
        case .protectedFolder: "folder"
        }
    }
}
