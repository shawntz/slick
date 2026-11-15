import Foundation

/// Something the user has selected or a row stands for: text, a URL or files. Universal actions
/// receive one, and the `{selection}` placeholder reads one.
public enum Selection: Hashable, Sendable, Codable {
    case text(String)
    case url(URL)
    /// Files and folders. A folder's URL has `hasDirectoryPath` set.
    case files([URL])

    /// The kind, for matching against ``UniversalActionProvider/accepts``.
    public var kind: SelectionKinds {
        switch self {
        case .text: .text
        case .url: .url
        case .files: .files
        }
    }

    /// The selection as text: the text itself, the URL string, or the file paths one per line.
    public var text: String {
        switch self {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .files(let urls): urls.map(\.path).joined(separator: "\n")
        }
    }
}

/// A set of selection kinds.
public struct SelectionKinds: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let text = SelectionKinds(rawValue: 1 << 0)
    public static let url = SelectionKinds(rawValue: 1 << 1)
    public static let files = SelectionKinds(rawValue: 1 << 2)
    public static let all: SelectionKinds = [.text, .url, .files]
}

/// Something to hand to the system share menu.
public enum ShareItem: Hashable, Sendable {
    case text(String)
    case url(URL)
    case file(URL)
}
