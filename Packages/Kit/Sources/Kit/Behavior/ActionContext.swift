import Foundation
import Synchronization

/// Everything an action or a command can reach while it runs: the feature's services, what the user
/// typed and selected, and the host's panel.
///
/// Every member of ``FeatureContext`` reads through, so `context.pasteboard`, `context.usage` and
/// `context.fileDialogs` all work.
@dynamicMemberLookup
public struct ActionContext: Sendable {
    /// The running feature's context.
    public let feature: FeatureContext
    /// The text in the search field when the action ran. For a ``LaunchSource/fallback`` or
    /// ``LaunchSource/tabFromRoot`` launch it is the text the user typed in root search, whether or
    /// not the command declares an argument for it.
    public let query: String
    /// Argument values by name: those the user typed for a command's arguments, and any others a
    /// ``ActionOutcome/run(_:arguments:)`` passed along.
    public let arguments: CommandArguments
    /// How the action or command was started.
    public let launch: LaunchSource
    /// The row the action belongs to, if any.
    public let row: Row?

    private let host: any ActionHost

    /// Made by the host and by `FeatureHarness`. Features receive one; they never make one.
    public init(
        feature: FeatureContext,
        host: any ActionHost,
        query: String = "",
        arguments: CommandArguments = CommandArguments(),
        launch: LaunchSource = .root,
        row: Row? = nil
    ) {
        self.feature = feature
        self.host = host
        self.query = query
        self.arguments = arguments
        self.launch = launch
        self.row = row
    }

    /// Reads a member of the feature's context, such as a service.
    public subscript<Value>(dynamicMember keyPath: KeyPath<FeatureContext, Value>) -> Value {
        feature[keyPath: keyPath]
    }

    // MARK: Panel

    /// Shows a toast: in the panel while it is visible, as a HUD otherwise. A later toast replaces
    /// this one. Keep the handle to turn a progress toast into a result or to dismiss it.
    @MainActor @discardableResult public func showToast(_ toast: Toast) -> ToastHandle {
        let id = ToastID(Self.nextToastID.add(1, ordering: .relaxed).newValue)
        host.showToast(toast, id: id)
        return ToastHandle(id: id, host: host)
    }

    /// Asks the current page to load again after the action finishes.
    @MainActor public func reload() {
        host.reload()
    }

    /// Replaces the text in the search field, which filters or loads the page as typing would.
    @MainActor public func setQuery(_ text: String) {
        host.setQuery(text)
    }

    /// Asks the system for a permission. This may show a system prompt, which is why only actions
    /// can call it: an action always follows something the user did. Prefer declaring
    /// ``Action/requires``, or returning ``ActionOutcome/needsPermission(_:)`` when a handler finds
    /// one missing, and letting the host run its grant flow.
    @MainActor public func requestPermission(_ permission: Permission) async -> PermissionStatus {
        await host.requestPermission(permission)
    }

    /// Shows Quick Look previews of local files inside the panel.
    @MainActor public func quickLook(_ urls: [URL]) {
        host.quickLook(urls)
    }

    /// Opens the system share menu for the items.
    @MainActor public func share(_ items: [ShareItem]) {
        host.share(items)
    }

    /// Asks a question inside the panel and returns true if the user went ahead. Prefer
    /// ``Action/confirmation`` or ``Command/confirmation`` when the question does not depend on what
    /// the handler finds.
    @MainActor public func confirm(_ confirmation: Confirmation) async -> Bool {
        await host.confirm(confirmation)
    }

    /// Closes the panel now while the handler keeps running, as a silent script does. Report the
    /// result with ``showToast(_:)``, which then appears as a HUD, or with
    /// ``ActionOutcome/close(hud:)``.
    @MainActor public func dismiss() {
        host.dismiss()
    }

    private static let nextToastID = Atomic<UInt64>(0)
}

/// The panel, as actions see it. The host implements it; so do the settings window and
/// `FeatureHarness`, which records every call for tests.
@MainActor public protocol ActionHost: AnyObject, Sendable {
    /// Shows a toast, or replaces the one with the same ID.
    func showToast(_ toast: Toast, id: ToastID)
    func dismissToast(_ id: ToastID)
    func reload()
    func setQuery(_ text: String)
    func requestPermission(_ permission: Permission) async -> PermissionStatus
    func quickLook(_ urls: [URL])
    func share(_ items: [ShareItem])
    func confirm(_ confirmation: Confirmation) async -> Bool
    func dismiss()
}
