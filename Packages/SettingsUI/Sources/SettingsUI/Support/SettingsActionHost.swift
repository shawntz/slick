import Foundation
import Kit

/// The settings window as an ``ActionHost``, for buttons in a feature's settings pane.
///
/// A button runs with an ``ActionContext`` whose launch is ``LaunchSource/settings``. Its toasts show
/// at the bottom of the settings window, its confirmations as alerts, and its permission requests
/// run the window's grant flow. The window has no query, page or Quick Look, so those calls do
/// nothing.
final class SettingsActionHost: ActionHost {
    private let toasts: ToastCenter
    private let confirmations: ConfirmationCenter
    private let permissions: PermissionGrant
    private let onReload: () -> Void

    init(
        toasts: ToastCenter, confirmations: ConfirmationCenter, permissions: PermissionGrant,
        onReload: @escaping () -> Void
    ) {
        self.toasts = toasts
        self.confirmations = confirmations
        self.permissions = permissions
        self.onReload = onReload
    }

    func showToast(_ toast: Toast, id: ToastID) {
        toasts.show(toast, id: id)
    }

    func dismissToast(_ id: ToastID) {
        toasts.dismiss(id)
    }

    func reload() {
        onReload()
    }

    func setQuery(_ text: String) {}

    func requestPermission(_ permission: Permission) async -> PermissionStatus {
        await permissions.grant(permission)
    }

    func quickLook(_ urls: [URL]) {}

    func share(_ items: [ShareItem]) {}

    func confirm(_ confirmation: Confirmation) async -> Bool {
        await confirmations.ask(confirmation)
    }

    func dismiss() {}
}
