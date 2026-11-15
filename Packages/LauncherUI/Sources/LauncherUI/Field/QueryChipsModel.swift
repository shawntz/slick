/// One inline argument after a command's title in the query row.
nonisolated public struct QueryArgument: Sendable, Equatable {
    /// What the argument accepts.
    public enum Kind: Sendable, Equatable {
        case text
        /// Text drawn as dots, in AppKit's secure field editor.
        case secure
        /// A choice from fixed options; the value is the chosen option's id.
        case dropdown([MenuOption])
    }

    public var kind: Kind
    /// The hint shown while the argument is empty.
    public var placeholder: String
    /// The text, or the chosen option's id.
    public var value: String

    public init(kind: Kind = .text, placeholder: String, value: String = "") {
        self.kind = kind
        self.placeholder = placeholder
        self.value = value
    }
}

/// The dropdown at the trailing end of the query row that narrows a view, such as "All Types".
/// Command-P opens it when the host calls `QueryField.openFilterMenu()`.
nonisolated public struct QueryFilter: Sendable, Equatable {
    public var options: [MenuOption]
    public var selectedID: String
    /// What accessibility clients read for the chip, such as "Type".
    public var label: String

    public init(options: [MenuOption], selectedID: String, label: String) {
        self.options = options
        self.selectedID = selectedID
        self.label = label
    }

    /// The selected option's title.
    public var selectedTitle: String { options.first { $0.id == selectedID }?.title ?? "" }
}
