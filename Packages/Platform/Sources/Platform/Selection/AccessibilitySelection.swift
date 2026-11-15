import ApplicationServices
import Foundation
import Kit

/// The live selection service, on the Accessibility API.
///
/// It reads the focused element of the frontmost app other than this one: its selected text, or
/// the files of its selected rows or children where the app exposes their `AXURL`, as file
/// managers do. A folder's URL has `hasDirectoryPath` set. Without the Accessibility permission it
/// returns nil and reads nothing; nothing here prompts. Every read runs off the main thread and
/// gives up on an app that does not answer within a quarter second.
nonisolated public final class AccessibilitySelection: SelectionService {
    private let permissions: any PermissionService
    private let focusedElement: @Sendable () -> (any AccessibilityElement)?
    private let isDirectory: @Sendable (URL) -> Bool

    /// - Parameters:
    ///   - permissions: Where the Accessibility permission is read. Never asked.
    ///   - focusedElement: The focused element of the app the selection belongs to.
    ///   - isDirectory: Whether a file URL without a trailing "/" names a folder.
    public init(
        permissions: any PermissionService,
        focusedElement: @escaping @Sendable () -> (any AccessibilityElement)?,
        isDirectory: @escaping @Sendable (URL) -> Bool = AccessibilitySelection.isDirectoryOnDisk
    ) {
        self.permissions = permissions
        self.focusedElement = focusedElement
        self.isDirectory = isDirectory
    }

    /// The live service: the focused element of the app the tracker says is frontmost.
    public static func live(permissions: any PermissionService, frontmost: FrontmostTracker) -> AccessibilitySelection {
        AccessibilitySelection(permissions: permissions) {
            guard let processID = frontmost.currentProcessID else { return nil }
            return AXElement.focusedElement(ofProcess: processID)
        }
    }

    @concurrent public func currentSelection() async -> Selection? {
        guard permissions.status(of: .accessibility) == .granted else { return nil }
        return SelectionReader.selection(in: focusedElement(), isDirectory: isDirectory)
    }

    /// Asks the file system whether the URL is a folder.
    public static func isDirectoryOnDisk(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// A selection service that never finds a selection, for run environments other than `live`.
nonisolated public struct NoSelection: SelectionService {
    public init() {}

    @concurrent public func currentSelection() async -> Selection? { nil }
}

/// Finds the selection in an accessibility tree. Pure apart from the elements it reads.
///
/// Each read is a message to another app, so a search is bounded: at most ``maximumItems``
/// selected items and ``maximumReads`` reads in all. A list of thousands of selected rows, or a
/// deep tree without file URLs, ends early with what was found so far.
nonisolated enum SelectionReader {
    static let selectedText = "AXSelectedText"
    static let selectedRows = "AXSelectedRows"
    static let selectedChildren = "AXSelectedChildren"
    static let children = "AXChildren"
    static let url = "AXURL"
    /// How deep below a selected item the reader looks for its URL.
    static let searchDepth = 3
    /// The most selected items read.
    static let maximumItems = 200
    /// The most attribute reads one search makes.
    static let maximumReads = 600

    /// The reads a search has left.
    final class Budget {
        private(set) var remaining: Int

        init(reads: Int = SelectionReader.maximumReads) {
            remaining = reads
        }

        /// Reads the attribute when reads are left, and counts it.
        func value(of attribute: String, in element: any AccessibilityElement) -> AccessibilityValue? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return element.value(of: attribute)
        }
    }

    /// Selected text, as a URL when it is exactly one web address, else the selected files.
    static func selection(
        in focused: (any AccessibilityElement)?, isDirectory: (URL) -> Bool, budget: Budget = Budget()
    ) -> Selection? {
        guard let focused else { return nil }
        if case .text(let text)? = budget.value(of: selectedText, in: focused),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return textSelection(text)
        }
        let files = selectedFiles(in: focused, budget: budget)
        guard !files.isEmpty else { return nil }
        return .files(files.map { directoryAware($0, isDirectory: isDirectory) })
    }

    /// Text, or a URL when the text is one http or https address and nothing else.
    static func textSelection(_ text: String) -> Selection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil
        {
            return .url(url)
        }
        return .text(text)
    }

    /// The file URLs of the selected rows or children, in order, without duplicates.
    static func selectedFiles(in focused: any AccessibilityElement, budget: Budget = Budget()) -> [URL] {
        var items: [any AccessibilityElement] = []
        for attribute in [selectedRows, selectedChildren] {
            if case .elements(let found)? = budget.value(of: attribute, in: focused), !found.isEmpty {
                items = found
                break
            }
        }
        var seen = Set<String>()
        var urls: [URL] = []
        for item in items.prefix(maximumItems) {
            guard budget.remaining > 0 else { break }
            guard let url = fileURL(in: item, depth: 0, budget: budget),
                seen.insert(url.standardizedFileURL.path).inserted
            else { continue }
            urls.append(url)
        }
        return urls
    }

    /// The first file URL on the element or below it.
    static func fileURL(in element: any AccessibilityElement, depth: Int, budget: Budget = Budget()) -> URL? {
        switch budget.value(of: url, in: element) {
        case .url(let found)? where found.isFileURL: return found
        case .text(let text)?: if let found = URL(string: text), found.isFileURL { return found }
        default: break
        }
        guard depth < searchDepth, case .elements(let children)? = budget.value(of: children, in: element) else {
            return nil
        }
        for child in children.prefix(32) {
            if let found = fileURL(in: child, depth: depth + 1, budget: budget) { return found }
        }
        return nil
    }

    /// The URL with `hasDirectoryPath` set when it names a folder.
    static func directoryAware(_ url: URL, isDirectory: (URL) -> Bool) -> URL {
        let folder = url.hasDirectoryPath || isDirectory(url)
        return URL(filePath: url.path(percentEncoded: false), directoryHint: folder ? .isDirectory : .notDirectory)
    }
}
