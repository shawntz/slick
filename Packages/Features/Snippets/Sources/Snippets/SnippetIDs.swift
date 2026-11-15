import Kit

/// The feature's identifiers, readable from any thread.
nonisolated enum SnippetIDs {
    /// The feature's manifest ID.
    static let feature = "snippets"
    /// Snippet rows in the list, in root search's catalog and in the instant answer for a keyword.
    static let namespace = "snippet"
    /// The argument that names a snippet by ID, for the hidden commands.
    static let snippetArgument = "snippet"
    /// Optional text and name handed to Create Snippet by other features and the universal action.
    static let textArgument = "text"
    static let nameArgument = "name"

    // Command IDs.
    static let searchCommand = "search"
    static let createCommand = "create"
    static let editCommand = "edit"
    static let fillCommand = "fill"
    static let importCommand = "import"
    static let exportCommand = "export"
    static let turnOnCommand = "turn-on-expansion"
    static let turnOffCommand = "turn-off-expansion"

    /// The command a typed keyword opens when its snippet asks for arguments.
    static let fillCommandID = ItemID.command(feature: feature, command: fillCommand)

    static func command(_ id: String) -> ItemID {
        ItemID.command(feature: feature, command: id)
    }

    static func row(_ snippetID: String) -> ItemID {
        ItemID(namespace, snippetID)
    }
}
