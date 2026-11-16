import Foundation

/// Open and save dialogs, for importing and exporting files.
public protocol FileDialogService: Sendable {
    /// Lets the user choose files or folders. Empty when they cancel.
    func chooseFiles(_ request: OpenDialogRequest) async -> [URL]

    /// Lets the user choose where to save. Nil when they cancel.
    func chooseSaveLocation(_ request: SaveDialogRequest) async -> URL?
}

/// What an open dialog offers.
public struct OpenDialogRequest: Hashable, Sendable {
    public var title: String?
    /// File extensions or uniform type identifiers. Empty allows any file.
    public var allowedTypes: [String]
    public var allowsMultiple: Bool
    public var canChooseDirectories: Bool
    /// False offers folders only, such as a folder to move a file into. True by default.
    public var canChooseFiles: Bool

    public init(
        title: String? = nil, allowedTypes: [String] = [], allowsMultiple: Bool = false,
        canChooseDirectories: Bool = false, canChooseFiles: Bool = true
    ) {
        self.title = title
        self.allowedTypes = allowedTypes
        self.allowsMultiple = allowsMultiple
        self.canChooseDirectories = canChooseDirectories
        self.canChooseFiles = canChooseFiles
    }
}

/// What a save dialog offers.
public struct SaveDialogRequest: Hashable, Sendable {
    public var title: String?
    public var suggestedName: String
    public var allowedTypes: [String]

    public init(title: String? = nil, suggestedName: String, allowedTypes: [String] = []) {
        self.title = title
        self.suggestedName = suggestedName
        self.allowedTypes = allowedTypes
    }
}
