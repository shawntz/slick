import CoreBridge
import Foundation
import Kit
import UniformTypeIdentifiers

/// What the detail pane and Get Info show about one file or folder: a Quick Look preview when the
/// file's type can draw one, and the file's own icon beside its kind otherwise, then its size,
/// dates and folder.
///
/// Whether a preview can draw is decided from the type the file's metadata names, never by opening
/// the file. The icon is ``Icon/file(path:)``, which the host's icon service resolves off the main
/// thread behind its read guard, so a file in a place macOS guards shows a generic icon instead of
/// raising a prompt. A file that is not there, as in scenarios, has no type and shows its icon.
nonisolated struct FileDetails: Sendable {
    let controller: IndexController
    let fileSystem: any FileSystem

    /// The detail for a row the scope allows, with its facts read off the main thread. Nil for a row
    /// outside the scope, whose facts are never read.
    @concurrent func detail(for row: Row, locale: Locale) async throws -> Detail? {
        guard row.id.namespace == FileRows.namespace else { return nil }
        let path = row.id.key
        guard let index = controller.index, let plan = controller.plan, plan.allows(path) else { return nil }
        let entry = Self.entry(at: path, in: index)
        try Task.checkCancellation()
        let facts = await fileSystem.facts(of: path) ?? FileFacts()
        try Task.checkCancellation()
        return Self.detail(
            path: path, item: FileRows.item(of: row), entry: entry, facts: facts, home: plan.home, locale: locale)
    }

    /// What Get Info shows: the detail when the scope allows the row, and otherwise what the row
    /// itself says, read from nothing.
    @concurrent func info(for row: Row, locale: Locale) async throws -> Detail {
        if let detail = try await detail(for: row, locale: locale) { return detail }
        return Self.detail(
            path: row.id.key, item: FileRows.item(of: row), entry: nil, facts: FileFacts(),
            home: controller.plan?.home ?? "/", locale: locale)
    }

    /// The detail from what is known. Pure.
    static func detail(
        path: String, item: FileItem, entry: FileEntry?, facts: FileFacts, home: String, locale: Locale
    ) -> Detail {
        let name = Paths.name(of: path)
        let preview = canPreview(contentType: facts.contentType, item: item)
        let guessed =
            entry.flatMap { FileKind.of(name: name, flags: $0.flags) }
            ?? FileKind.of(name: name, isFolder: item.isFolder, isPackage: item.isPackage)
        let kind = facts.kind ?? guessed.map(Strings.Kinds.singular) ?? Strings.Detail.unknownKind(item)
        var metadata: [MetadataItem] = [
            .label(Strings.Detail.kind, value: kind, icon: preview ? nil : .file(path: path))
        ]
        if !item.isFolder || item.isPackage, let size = facts.size ?? entry?.size.map(Int64.init) {
            metadata.append(.label(Strings.Detail.size, value: Strings.Detail.size(size, locale: locale)))
        }
        if let created = facts.created { metadata.append(.date(Strings.Detail.created, created)) }
        let indexed = entry.map { Date(timeIntervalSince1970: TimeInterval($0.modified)) }
        if let modified = facts.modified ?? indexed { metadata.append(.date(Strings.Detail.modified, modified)) }
        metadata.append(
            .label(Strings.Detail.location, value: FileRows.oneLine(Paths.display(Paths.parent(of: path), home: home))))
        let url = URL(filePath: path, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
        return Detail(preview ? .preview(url) : nil, metadata: metadata)
    }

    /// True when Quick Look draws a preview of this type: images, PDF, text and code, movies,
    /// presentations, spreadsheets, documents, fonts and 3D models. Folders, applications,
    /// archives, disk images, audio and unknown types show their icon.
    static func canPreview(contentType identifier: String?, item: FileItem) -> Bool {
        guard !item.isFolder || item.isPackage, let identifier, let type = UTType(identifier) else { return false }
        if refused.contains(where: { type.conforms(to: $0) }) { return false }
        return previewable.contains { type.conforms(to: $0) }
    }

    private static let previewable: [UTType] =
        [.image, .pdf, .text, .movie, .presentation, .spreadsheet, .font, .threeDContent]
        + [UTType("public.composite-content")].compactMap(\.self)

    private static let refused: [UTType] = [.archive, .diskImage, .application, .executable]

    private static func entry(at path: String, in index: FileIndex) -> FileEntry? {
        guard let snapshot = try? index.snapshot(), let id = snapshot.lookup(path: path) else { return nil }
        return snapshot.entry(id)
    }
}

/// The Get Info page: the file's detail, read when the page opens, and the actions that only look
/// at the file or copy what it is.
final class FileInfoSource: DetailSource {
    private let row: Row
    private let details: FileDetails
    private let locale: Locale
    private let pageActions: [Action]

    init(row: Row, details: FileDetails, locale: Locale, actions: [Action]) {
        self.row = row
        self.details = details
        self.locale = locale
        pageActions = actions
    }

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        let (row, details, locale) = (row, details, locale)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    continuation.yield(.replace(try await details.info(for: row, locale: locale)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func actions(for detail: Detail) -> [Action] {
        pageActions
    }
}
