import AppKit

/// What the action bar shows. Every string comes resolved from the host.
nonisolated public struct ActionBarContent: Sendable, Equatable {
    /// The current view's icon, shown before its name. Nil shows the name alone.
    public var viewIcon: CGImage?
    /// The current view's name.
    public var viewTitle: String
    /// The primary action's title, or nil when the selection has no action.
    public var primaryTitle: String?
    /// The keys of the primary action's shortcut.
    public var primaryKeys: [String]
    /// The title of the action panel entry, or nil to hide it.
    public var actionsTitle: String?
    /// The keys that open the action panel.
    public var actionsKeys: [String]

    public init(
        viewIcon: CGImage? = nil, viewTitle: String, primaryTitle: String? = nil, primaryKeys: [String] = ["↩"],
        actionsTitle: String? = "Actions", actionsKeys: [String] = ["⌘", "K"]
    ) {
        self.viewIcon = viewIcon
        self.viewTitle = viewTitle
        self.primaryTitle = primaryTitle
        self.primaryKeys = primaryKeys
        self.actionsTitle = actionsTitle
        self.actionsKeys = actionsKeys
    }

    public static func == (lhs: ActionBarContent, rhs: ActionBarContent) -> Bool {
        lhs.viewIcon === rhs.viewIcon && lhs.viewTitle == rhs.viewTitle && lhs.primaryTitle == rhs.primaryTitle
            && lhs.primaryKeys == rhs.primaryKeys && lhs.actionsTitle == rhs.actionsTitle
            && lhs.actionsKeys == rhs.actionsKeys
    }
}

/// A short status message in the action bar's left region.
nonisolated public struct ActionBarToast: Sendable, Equatable {
    /// The symbol before the text.
    public enum Style: Sendable, Equatable {
        /// A spinner, for work in progress.
        case progress
        /// A checkmark.
        case success
        /// A warning triangle.
        case failure
        /// No mark: the text alone, for a neutral note.
        case info
    }

    public var style: Style
    public var text: String
    /// A button after the text, such as "Open Settings". Nil draws none. A press calls
    /// `ActionBar.onToastButton`.
    public var buttonTitle: String?
    /// The keys that press the button, drawn as one keycap inside it, such as `["⌘", "O"]`.
    public var buttonKeys: [String]

    public init(_ style: Style, _ text: String) {
        self.style = style
        self.text = text
        buttonTitle = nil
        buttonKeys = []
    }

    public init(_ style: Style, _ text: String, buttonTitle: String?, buttonKeys: [String] = []) {
        self.style = style
        self.text = text
        self.buttonTitle = buttonTitle
        self.buttonKeys = buttonKeys
    }
}
