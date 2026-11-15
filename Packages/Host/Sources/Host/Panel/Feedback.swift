import AppKit
import Kit
import LauncherUI

/// Where HUDs go: a small window after the panel closed. A protocol so tests record HUDs instead
/// of putting a window on screen.
@MainActor public protocol HUDDisplay: AnyObject {
    func show(_ hud: HUD)
    /// Renders once while hidden, so the first HUD costs what later ones do.
    func prewarm()
    func apply(_ theme: Theme)
}

/// HUDs in LauncherUI's ``HUDWindow``.
@MainActor public final class HUDWindowDisplay: HUDDisplay {
    public let window: HUDWindow

    public init(theme: Theme = .standard) {
        window = HUDWindow(theme: theme)
    }

    public func show(_ hud: HUD) {
        window.show(HUDContent(hud.title, symbolName: Self.symbolName(hud.style)))
    }

    public func prewarm() {
        window.prewarm()
    }

    public func apply(_ theme: Theme) {
        window.theme = theme
    }

    /// The symbol a HUD of this style shows.
    public nonisolated static func symbolName(_ style: Toast.Style) -> String? {
        switch style {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .progress: "hourglass"
        case .info: nil
        }
    }
}

/// Toasts in the action bar while the panel shows, HUDs while it does not.
///
/// One toast shows at a time. A toast with the ID of the one showing updates it in place; any other
/// toast replaces it. Toasts other than progress hide after ``lifetime``.
@MainActor final class ToastController {
    /// How long a finished toast stays.
    static let lifetime: Duration = .seconds(3)

    /// The toast showing now, with the run that showed it.
    private(set) var visible: (id: ToastID, toast: Toast, origin: RunOrigin?)?
    private let actionBar: ActionBar
    private let hud: any HUDDisplay
    private var hideTask: Task<Void, Never>?

    init(actionBar: ActionBar, hud: any HUDDisplay) {
        self.actionBar = actionBar
        self.hud = hud
    }

    func show(_ toast: Toast, id: ToastID, origin: RunOrigin?, panelVisible: Bool) {
        guard panelVisible else {
            hud.show(HUD(toast.title, style: toast.style))
            return
        }
        visible = (id, toast, origin)
        actionBar.show(Self.barToast(toast))
        hideTask?.cancel()
        hideTask = nil
        guard toast.style != .progress else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: ToastID) {
        guard visible?.id == id else { return }
        clear()
    }

    func clear() {
        hideTask?.cancel()
        hideTask = nil
        visible = nil
        actionBar.show(nil)
    }

    /// A Kit toast as the action bar draws it, with its action as the bar's button. The action
    /// panel also lists the action first, so the keyboard reaches it.
    nonisolated static func barToast(_ toast: Toast) -> ActionBarToast {
        let style: ActionBarToast.Style =
            switch toast.style {
            case .progress: .progress
            case .failure: .failure
            case .success: .success
            case .info: .info
            }
        let text = toast.message.map { "\(toast.title): \($0)" } ?? toast.title
        return ActionBarToast(style, text, buttonTitle: toast.action?.title)
    }
}
