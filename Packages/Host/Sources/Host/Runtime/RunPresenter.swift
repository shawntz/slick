import Foundation
import Kit

/// Where a run came from: the feature, what the user typed and how it started. The pipeline hands
/// it to the presenter with each outcome and toast, so a pushed page gets its feature's context and
/// a toast's button runs with the context of the action that showed it.
public struct RunOrigin: Sendable {
    public var featureID: String
    public var feature: FeatureContext
    public var query: String
    public var arguments: CommandArguments
    public var launch: LaunchSource
    public var row: Row?
    /// The panel's ``RunPresenter/sessionID`` when the run started with the panel on screen, or
    /// nil when it started while the panel was hidden, as a hotkey run does. The pipeline sets it.
    public var session: Int?
    /// The title of the command the run started from, when it started from one. A page the run
    /// pushes without a title of its own shows it in the breadcrumb.
    public var commandTitle: String?

    public init(
        featureID: String, feature: FeatureContext, query: String = "",
        arguments: CommandArguments = CommandArguments(),
        launch: LaunchSource, row: Row? = nil
    ) {
        self.featureID = featureID
        self.feature = feature
        self.query = query
        self.arguments = arguments
        self.launch = launch
        self.row = row
    }
}

/// What the run pipeline needs from the panel. The panel controller implements it; tests use a
/// recording double, so the pipeline runs headless.
@MainActor public protocol RunPresenter: AnyObject {
    /// True while the panel is on screen. Toasts show in it; otherwise they show as HUDs.
    var isPanelVisible: Bool { get }
    /// Changes every time the panel opens. A run that started in one session and ends after the
    /// panel closed, or in a later session, does not move the panel: see ``apply(_:origin:)``.
    var sessionID: Int { get }
    /// Shows a toast, or replaces the one showing. `origin` is the run that showed it.
    func showToast(_ toast: Toast, id: ToastID, origin: RunOrigin?)
    func dismissToast(_ id: ToastID)
    /// Shows a HUD, as after the panel closed.
    func showHUD(_ hud: HUD)
    /// Asks inside the panel, opening it first when it is closed, as for a hotkey launch. True when
    /// the user went ahead.
    func confirm(_ confirmation: Confirmation, isDestructive: Bool) async -> Bool
    /// Asks as ``confirm(_:isDestructive:)`` does, with a "Don't ask again" box when
    /// `suppressionKey` is set: `<feature id>.<suppression key>`. When the user goes ahead with the
    /// box checked, the presenter stores the suppression. The default ignores the key.
    func confirm(_ confirmation: Confirmation, isDestructive: Bool, suppressionKey: String?) async -> Bool
    /// Shows the permission card, opening the panel first when it is closed. True when the user
    /// pressed the button that asks the system.
    func askForPermission(_ permission: Permission, featureName: String, reason: String) async -> Bool
    /// Applies an outcome that changes the panel: close, push, replace, pop, popToRoot, showRoot.
    /// The pipeline handles keepOpen, run and needsPermission itself. When the run started in a
    /// session that has ended, the panel shows a close's HUD and ignores the rest, so a slow action
    /// never reopens or closes a panel the user moved on from.
    func apply(_ outcome: ActionOutcome, origin: RunOrigin)
    /// Loads the top page again, after an action called ``ActionContext/reload()``.
    func reloadTopPage()
    /// Replaces the search field's text, which filters or loads as typing does.
    func setQuery(_ text: String)
    func quickLook(_ urls: [URL])
    func share(_ items: [ShareItem])
    /// Closes the panel while the handler keeps running.
    func dismissPanel()
}

extension RunPresenter {
    public func confirm(_ confirmation: Confirmation, isDestructive: Bool, suppressionKey: String?) async -> Bool {
        await confirm(confirmation, isDestructive: isDestructive)
    }
}
