import Foundation
import Kit
import KitHosting
import LauncherUI

/// What every pane model shares: the dependencies, the general settings, the window's toasts and
/// confirmations, and the grant flow.
final class SettingsContext {
    let dependencies: SettingsDependencies
    let general: FeatureSettings
    let toasts = ToastCenter()
    let confirmations = ConfirmationCenter()
    let permissions: PermissionGrant
    /// Tells the features about grants made here. Grant buttons use it through ``permissions``, and
    /// panes that follow a status use it directly.
    let grants: GrantAnnouncer
    let icons: IconResolver

    init(_ dependencies: SettingsDependencies) {
        self.dependencies = dependencies
        general = HostSettings.settings(dependencies.services.settings)
        let grants = GrantAnnouncer(service: dependencies.services.permissions, directory: dependencies.features)
        self.grants = grants
        permissions = PermissionGrant(
            service: dependencies.services.permissions, custom: dependencies.grantPermission, announcer: grants,
            waitsForApp: dependencies.permissionWaitsForApp)
        icons = IconResolver(provider: dependencies.icons)
    }

    var services: Services { dependencies.services }
    var directory: any FeatureDirectory { dependencies.features }
    var preferences: any ItemPreferences { dependencies.preferences }

    /// The sentence a permission's row shows in place of its Allow button while the permission
    /// waits for its app, naming the app when the workspace knows it. Nil when a button may ask.
    func waitingSentence(for permission: Permission, status: PermissionStatus) -> String? {
        guard permissions.waitsForApp(permission, status: status) else { return nil }
        var name: String?
        if case .automation(let bundleID) = permission {
            name = services.workspace.application(bundleID: bundleID).map { DisplayText.oneLine($0.name) }
        }
        return PermissionGrant.waitingSentence(appName: name)
    }

    /// How a permission's row is titled: an Automation permission by its app, such as "Music
    /// Automation", so the rows of several apps differ. The name comes from the workspace, or for
    /// Apple's helpers outside the app folders, which the workspace does not list, from
    /// ``systemAppNames``.
    func title(for permission: Permission) -> String {
        guard case .automation(let bundleID) = permission,
            let name = services.workspace.application(bundleID: bundleID)?.name ?? Self.systemAppNames[bundleID]
        else { return permission.displayName }
        return "\(DisplayText.oneLine(name)) \(permission.displayName)"
    }

    /// The names of Apple's own apps that features control and that live in
    /// /System/Library/CoreServices, outside the folders the app catalog reads.
    static let systemAppNames = [
        "com.apple.finder": "Finder", "com.apple.systemevents": "System Events",
        "com.apple.loginwindow": "Login Window",
    ]

    /// How an item reads in settings: a command's title, a known row's title, or its raw ID.
    func title(for id: ItemID) -> String {
        if let command = directory.command(id) { return command.command.title }
        if let row = dependencies.lookUpItem(id) { return row.title }
        return id.rawValue
    }

    /// The icon of an item, when known.
    func icon(for id: ItemID) -> Icon? {
        if let command = directory.command(id) {
            return command.command.icon ?? directory.feature(command.featureID)?.manifest.icon
        }
        return dependencies.lookUpItem(id)?.icon
    }

    /// How a hotkey conflict's owner reads: an item's title when the owner is one of the user's
    /// items, as the fake directory and some hosts report it, otherwise the owner as given.
    func describe(_ conflict: HotkeyConflict) -> String {
        if let id = ItemID(rawValue: conflict.owner), directory.command(id) != nil || dependencies.lookUpItem(id) != nil
        {
            return title(for: id)
        }
        return conflict.owner
    }

    /// The launcher hotkey's binding, when App passed it.
    var launcherHotkey: (any LauncherHotkeyStatus)? { dependencies.launcherHotkey }

    /// Opens the Keyboard pane of System Settings on its Spotlight shortcuts. Only a button the user
    /// pressed calls it.
    func openKeyboardSettings() {
        let workspace = services.workspace
        let toasts = toasts
        Task {
            do {
                try await workspace.open(SpotlightShortcutGuide.keyboardSettingsURL)
            } catch {
                toasts.show(error, title: "Could Not Open Keyboard Settings")
            }
        }
    }

    /// A recorder model for a target, with conflicts named for people. The recorder keeps the
    /// context; the context never holds a recorder, so there is no cycle.
    func recorder(_ target: HotkeyTarget) -> HotkeyRecorderModel {
        HotkeyRecorderModel(target: target, describe: { self.describe($0) })
    }
}
