import AppKit
import Foundation
import Kit
import UniformTypeIdentifiers

/// The live file dialogs, on `NSOpenPanel` and `NSSavePanel`. The app becomes active first, because
/// an accessory app's panel would otherwise open behind the frontmost app. Never run in tests.
nonisolated public struct PanelFileDialogs: FileDialogService {
    public init() {}

    public func chooseFiles(_ request: OpenDialogRequest) async -> [URL] {
        await Self.runOpenPanel(request)
    }

    public func chooseSaveLocation(_ request: SaveDialogRequest) async -> URL? {
        await Self.runSavePanel(request)
    }

    @MainActor private static func runOpenPanel(_ request: OpenDialogRequest) async -> [URL] {
        let panel = NSOpenPanel()
        if let title = request.title { panel.message = title }
        panel.allowsMultipleSelection = request.allowsMultiple
        panel.canChooseDirectories = request.canChooseDirectories
        panel.canChooseFiles = request.canChooseFiles
        let types = DialogTypes.contentTypes(for: request.allowedTypes)
        if !types.isEmpty { panel.allowedContentTypes = types }
        NSApplication.shared.activate()
        guard await panel.begin() == .OK else { return [] }
        return panel.urls
    }

    @MainActor private static func runSavePanel(_ request: SaveDialogRequest) async -> URL? {
        let panel = NSSavePanel()
        if let title = request.title { panel.message = title }
        panel.nameFieldStringValue = request.suggestedName
        let types = DialogTypes.contentTypes(for: request.allowedTypes)
        if !types.isEmpty { panel.allowedContentTypes = types }
        NSApplication.shared.activate()
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}

/// Turns Kit's allowed types, file extensions or type identifiers, into content types.
nonisolated enum DialogTypes {
    /// One content type per entry that names a known type: an identifier such as "public.json",
    /// else a file extension with or without its dot. Unknown entries are dropped.
    static func contentTypes(for allowed: [String]) -> [UTType] {
        var types: [UTType] = []
        for entry in allowed {
            let trimmed = entry.hasPrefix(".") ? String(entry.dropFirst()) : entry
            let type =
                trimmed.contains(".")
                ? UTType(trimmed) ?? UTType(filenameExtension: trimmed)
                : UTType(filenameExtension: trimmed)
            if let type, !types.contains(type) { types.append(type) }
        }
        return types
    }
}

/// File dialogs that always answer as if the user cancelled, for run environments other than
/// `live`, which must show no dialog.
nonisolated public struct CancellingFileDialogs: FileDialogService {
    public init() {}

    public func chooseFiles(_ request: OpenDialogRequest) async -> [URL] { [] }

    public func chooseSaveLocation(_ request: SaveDialogRequest) async -> URL? { nil }
}
