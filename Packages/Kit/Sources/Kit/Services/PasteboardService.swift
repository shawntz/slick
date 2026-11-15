import Foundation

/// The general pasteboard: copying, pasting into the frontmost app, and watching what other apps copy.
///
/// The live service never reads the pasteboard on the main thread and skips items marked concealed,
/// transient or auto-generated. What Slick writes is marked transient with Slick as its source, so
/// other clipboard managers and Slick's own history skip it.
public protocol PasteboardService: Sendable {
    /// Replaces the pasteboard's contents.
    func copy(_ content: PasteboardContent, options: CopyOptions) async

    /// Copies the content, closes the panel, waits for the previous app to become frontmost and sends
    /// Command-V to it, then presses Left `charactersAfterCursor` times to place the insertion point.
    /// Needs ``Permission/accessibility``; declare it on the action. Throws ``PasteError`` when the
    /// paste could not be sent; the content is on the pasteboard either way.
    func paste(_ content: PasteboardContent, charactersAfterCursor: Int) async throws

    /// The current contents. Read it only in response to the user, never on a timer.
    @concurrent func read() async -> PasteboardEntry?

    /// Text copied earlier: offset 0 is the current text, 1 the one before, and so on. Answered from
    /// the clipboard history a feature provides (see ``ProvidedService/clipboardHistory(_:)``) when
    /// one is on, otherwise from the entries the service has seen since launch. Nil when there is no
    /// such entry. Used by the `{clipboard offset=N}` placeholder.
    @concurrent func recentText(offset: Int) async -> String?

    /// A number that changes whenever any app writes the pasteboard. Cheap enough to read anywhere.
    var changeCount: Int { get }

    /// What other apps copy, one entry per change, from now on. The live service polls off the main
    /// thread at 4 Hz and applies the ignore rules first. Each call returns its own stream; it ends
    /// when the consuming task is cancelled.
    func entries() -> AsyncStream<PasteboardEntry>
}

extension PasteboardService {
    /// Copies plain text.
    public func copy(_ text: String) async {
        await copy(.text(text), options: [])
    }

    /// Pastes content and leaves the insertion point at its end.
    public func paste(_ content: PasteboardContent) async throws {
        try await paste(content, charactersAfterCursor: 0)
    }

    /// Pastes plain text into the frontmost app.
    public func paste(_ text: String) async throws {
        try await paste(.text(text), charactersAfterCursor: 0)
    }

    /// Pastes an expansion's text and places the insertion point where its `{cursor}` was.
    public func paste(_ expansion: Expansion) async throws {
        try await paste(.text(expansion.text), charactersAfterCursor: expansion.charactersAfterCursor)
    }
}

/// One representation of pasteboard contents.
public enum PasteboardContent: Hashable, Sendable {
    case text(String)
    /// Styled text with its plain-text form.
    case richText(rtf: Data, plain: String)
    case url(URL)
    case files([URL])
    /// Image bytes with their uniform type identifier, such as `public.png`.
    case image(Data, typeIdentifier: String)

    /// The content as plain text, when it has one.
    public var plainText: String? {
        switch self {
        case .text(let text): text
        case .richText(_, let plain): plain
        case .url(let url): url.absoluteString
        case .files(let urls): urls.map(\.path).joined(separator: "\n")
        case .image: nil
        }
    }
}

/// One change to the pasteboard made by another app.
public struct PasteboardEntry: Hashable, Sendable {
    /// The representations the service kept, richest first.
    public var contents: [PasteboardContent]
    /// The bundle ID of the app that wrote it, when known. ``WorkspaceService/application(bundleID:)``
    /// gives its name.
    public var sourceBundleID: String?
    public var date: Date
    /// The pasteboard's change count for this entry.
    public var changeCount: Int

    public init(contents: [PasteboardContent], sourceBundleID: String? = nil, date: Date, changeCount: Int) {
        self.contents = contents
        self.sourceBundleID = sourceBundleID
        self.date = date
        self.changeCount = changeCount
    }

    /// The first representation with plain text.
    public var plainText: String? {
        contents.lazy.compactMap(\.plainText).first
    }
}

/// How content is written to the pasteboard.
public struct CopyOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Marks the content concealed, as password managers do, so clipboard managers do not store it.
    public static let concealed = CopyOptions(rawValue: 1 << 0)
}

/// Why a paste did not reach the frontmost app.
public enum PasteError: Error, Hashable, Sendable {
    /// Sending Command-V needs a permission the user has not granted.
    case permissionMissing(Permission)
    /// The previous app did not become frontmost in time.
    case targetDidNotActivate
}
