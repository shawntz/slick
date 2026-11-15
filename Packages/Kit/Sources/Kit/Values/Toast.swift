/// A short message about something an action did, such as "Moved to Trash".
///
/// Show one with ``ActionContext/showToast(_:)``. The host draws it inside the panel while the panel
/// is visible, and as a HUD when it is not, for example after ``ActionContext/dismiss()`` or for a
/// command started by a hotkey. A later toast replaces the current one.
public struct Toast: Sendable {
    /// How the toast looks.
    public enum Style: Sendable, Hashable {
        /// A check mark.
        case success
        /// A red mark. Use it when something did not happen.
        case failure
        /// A spinner, for work that is still running. Update or dismiss it through its handle.
        case progress
        /// No mark.
        case info
    }

    public var style: Style
    public var title: String
    public var message: String?
    /// One button on the toast, such as "Open Settings" or "Show Details". Dropped when the toast is
    /// drawn as a HUD.
    public var action: ToastAction?

    public init(_ style: Style, _ title: String, message: String? = nil, action: ToastAction? = nil) {
        self.style = style
        self.title = title
        self.message = message
        self.action = action
    }

    /// A success toast.
    public static func success(_ title: String, message: String? = nil) -> Toast {
        Toast(.success, title, message: message)
    }

    /// A failure toast.
    public static func failure(_ title: String, message: String? = nil) -> Toast {
        Toast(.failure, title, message: message)
    }

    /// A progress toast with a spinner.
    public static func progress(_ title: String, message: String? = nil) -> Toast {
        Toast(.progress, title, message: message)
    }
}

/// A button on a toast. It runs like an action, with the context of the action that showed the
/// toast, so it can push a page or ask for a permission.
public struct ToastAction: Sendable {
    public var title: String
    public var run: Action.Handler

    public init(_ title: String, run: @escaping Action.Handler) {
        self.title = title
        self.run = run
    }
}

/// Identifies one toast, so it can be updated or dismissed.
public struct ToastID: Hashable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

/// A toast that is showing. Update it as work progresses, for example from a progress toast to a
/// success toast, or dismiss it.
public struct ToastHandle: Sendable {
    public let id: ToastID
    private let host: any ActionHost

    init(id: ToastID, host: any ActionHost) {
        self.id = id
        self.host = host
    }

    /// Replaces what the toast shows.
    @MainActor public func update(_ toast: Toast) {
        host.showToast(toast, id: id)
    }

    /// Hides the toast now.
    @MainActor public func dismiss() {
        host.dismissToast(id)
    }
}
