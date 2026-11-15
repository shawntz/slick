import Foundation

/// Something the user can do: a row's primary action, an entry in the action panel, a submenu.
///
/// Actions are made on demand by the source that owns a row, so they may capture whatever they need.
/// Their closures run on the main actor; anything slow inside them should `await` a service or a
/// `@concurrent` function.
///
/// What the host does with a handler:
///
/// - It checks ``requires`` first and asks ``confirmation``, then runs the handler under
///   ``runPolicy``.
/// - A thrown error shows a failure toast titled by the error's `LocalizedError.errorDescription`,
///   or as a HUD when the panel is not visible. Throw ``ActionFailure`` for a message of your own.
///   `CancellationError` shows nothing.
/// - Closing the panel does not cancel a running handler, so a slow script or download still
///   finishes and reports. Turning the feature off cancels it.
public struct Action: Identifiable, Sendable {
    /// Runs an action and says what the panel does next.
    public typealias Handler = @MainActor @Sendable (ActionContext) async throws -> ActionOutcome
    /// Builds the entries of a submenu when the user opens it.
    public typealias SubmenuLoader = @MainActor @Sendable (ActionContext) async -> [Action]

    /// How an action is drawn.
    public enum Style: Sendable, Hashable {
        case regular
        /// Drawn in red, and its confirmation's button too. Pair it with a ``Confirmation`` when the
        /// action cannot be undone.
        case destructive
    }

    /// What choosing the action does.
    public enum Kind: Sendable {
        /// Runs a handler.
        case run(Handler)
        /// Opens a nested list of actions, such as "Open With" and its applications.
        case submenu(SubmenuLoader)
    }

    /// Unique within the actions of one row. Defaults to the title.
    public var id: String
    public var title: String
    public var icon: Icon?
    /// A key combination that runs the action without opening the panel.
    public var shortcut: KeyCombo?
    public var style: Style
    /// A heading in the action panel. Consecutive actions with the same section are grouped.
    public var section: String?
    /// When set, the host asks inside the panel before running the action.
    public var confirmation: Confirmation?
    /// Permissions the action needs. When one is missing, the host explains why and offers to grant
    /// it instead of running the action. The reason comes from the feature's manifest.
    public var requires: [Permission]
    /// A command the action hands work to, possibly another feature's. The host hides the action
    /// while that command is unavailable, such as when its feature is off or not installed.
    public var requiresCommand: ItemID?
    /// What happens when the user starts the action again before an earlier run has finished.
    public var runPolicy: RunPolicy
    public var kind: Kind

    /// An action that runs a handler.
    public init(
        _ title: String,
        id: String? = nil,
        icon: Icon? = nil,
        shortcut: KeyCombo? = nil,
        style: Style = .regular,
        section: String? = nil,
        confirmation: Confirmation? = nil,
        requires: [Permission] = [],
        requiresCommand: ItemID? = nil,
        runPolicy: RunPolicy = .serial,
        run: @escaping Handler
    ) {
        self.id = id ?? title
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.style = style
        self.section = section
        self.confirmation = confirmation
        self.requires = requires
        self.requiresCommand = requiresCommand
        self.runPolicy = runPolicy
        self.kind = .run(run)
    }

    /// An action that opens a submenu. The loader runs when the user opens it.
    public static func submenu(
        _ title: String,
        id: String? = nil,
        icon: Icon? = nil,
        shortcut: KeyCombo? = nil,
        section: String? = nil,
        actions: @escaping SubmenuLoader
    ) -> Action {
        var action = Action(title, id: id, icon: icon, shortcut: shortcut, section: section) { _ in .keepOpen }
        action.kind = .submenu(actions)
        return action
    }
}

/// A question the host asks inside the panel before an action or command runs.
public struct Confirmation: Hashable, Sendable {
    public var title: String
    public var message: String?
    /// The label of the button that goes ahead, such as "Delete".
    public var confirmTitle: String
    /// True draws the button in red. It is red anyway when the action's style is destructive.
    public var isDestructive: Bool
    /// When set, the host offers "Don't ask again" and remembers the answer. The host keeps it as
    /// `<feature id>.<key>`, so two features may use the same key.
    public var suppressionKey: String?

    public init(
        _ title: String,
        message: String? = nil,
        confirmTitle: String = "Confirm",
        isDestructive: Bool = false,
        suppressionKey: String? = nil
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.suppressionKey = suppressionKey
    }
}

/// What the host does when the user starts an action or command while an earlier run is still going.
public enum RunPolicy: Hashable, Sendable {
    /// Waits for the feature's earlier serial runs to finish, then runs. The default: a handler that
    /// reads state, awaits, then writes it, such as cycling a window's size on repeated presses,
    /// always sees the previous run's result.
    case serial
    /// Ignores the new start while a run of the same action or command is going.
    case dropWhileRunning
    /// Runs at once, alongside anything else. For long work that does not share state, such as a
    /// script that runs for minutes.
    case concurrent
}

/// An error whose title and message the host shows as is, as a failure toast or HUD.
public struct ActionFailure: LocalizedError, Hashable, Sendable, CustomStringConvertible {
    public var title: String
    public var message: String?

    public init(_ title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    public var errorDescription: String? { title }
    public var failureReason: String? { message }
    public var description: String { message.map { "\(title): \($0)" } ?? title }
}
