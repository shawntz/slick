import Foundation
import Kit
import KitStorage

/// AI Chat's conversations: one JSON file each in the feature's `Chats` folder, named by the
/// conversation's ID and written atomically.
///
/// Each file's modification date is set to the conversation's last change, so pruning old chats
/// reads only the folder listing, never what the chats say. The store reads the files the first
/// time the list or a chat needs them and keeps them in memory after that.
actor ConversationStore {
    /// The folder of conversation files. Nothing exists until the first save.
    nonisolated let folder: URL
    /// Sent after every change, so an open chat list loads again.
    nonisolated let changes = ChangeSignal()

    private var cache: [String: Conversation]?

    init(folder: URL) {
        self.folder = folder
    }

    /// Every conversation, the most recently changed first. A file that cannot be read is skipped.
    func all() async throws -> [Conversation] {
        try await loaded().values.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
    }

    /// One conversation, or nil when there is no such file.
    func conversation(id: String) async throws -> Conversation? {
        try await loaded()[id]
    }

    /// Writes a conversation. Refuses one written by a newer version, so its extra data survives.
    func save(_ conversation: Conversation) async throws {
        guard Self.isValidID(conversation.id) else { throw Strings.Failures.chatNotSaved }
        guard !conversation.isFromNewerVersion else { throw Strings.Failures.newerChat }
        let url = fileURL(for: conversation.id)
        try await JSONFileStore<Conversation>(url: url).save(conversation)
        try? FileManager.default.setAttributes([.modificationDate: conversation.updated], ofItemAtPath: url.path)
        var current = try await loaded()
        current[conversation.id] = conversation
        cache = current
        changes.send()
    }

    /// Deletes one conversation. Does nothing when it is already gone.
    func delete(id: String) async throws {
        guard Self.isValidID(id) else { return }
        try await JSONFileStore<Conversation>(url: fileURL(for: id)).delete()
        cache?[id] = nil
        changes.send()
    }

    /// Deletes every conversation and returns how many there were. Signals only when it deleted
    /// something, so a list that prunes as it loads does not load again for nothing.
    @discardableResult
    func deleteAll() throws -> Int {
        var count = 0
        for url in try files() {
            try FileManager.default.removeItem(at: url)
            count += 1
        }
        let hadCached = !(cache?.isEmpty ?? true)
        cache = [:]
        if count > 0 || hadCached { changes.send() }
        return count
    }

    /// Deletes conversations last changed before `cutoff` and returns how many. Reads only the
    /// folder listing and the files' modification dates.
    @discardableResult
    func prune(before cutoff: Date) throws -> Int {
        var removed = 0
        for url in try files() {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try FileManager.default.removeItem(at: url)
            cache?[url.deletingPathExtension().lastPathComponent] = nil
            removed += 1
        }
        if let stale = cache?.values.filter({ $0.updated < cutoff }), !stale.isEmpty {
            for conversation in stale {
                try? FileManager.default.removeItem(at: fileURL(for: conversation.id))
                cache?[conversation.id] = nil
                removed += 1
            }
        }
        if removed > 0 { changes.send() }
        return removed
    }

    // MARK: - Files

    private func loaded() async throws -> [String: Conversation] {
        if let cache { return cache }
        var result: [String: Conversation] = [:]
        for url in try files() {
            try Task.checkCancellation()
            let id = url.deletingPathExtension().lastPathComponent
            guard Self.isValidID(id), var conversation = try? await JSONFileStore<Conversation>(url: url).load() else {
                continue
            }
            conversation.id = id
            result[id] = conversation
        }
        cache = result
        return result
    }

    /// The conversation files in the folder. Empty when the folder does not exist yet.
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func fileURL(for id: String) -> URL {
        folder.appending(path: id + ".json", directoryHint: .notDirectory)
    }

    /// An ID that is safe as a file name: letters, digits and "-", at most 64 characters.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}
