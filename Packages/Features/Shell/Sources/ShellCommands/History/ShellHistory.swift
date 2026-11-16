import Foundation
import Kit
import KitStorage
import os

/// One command that ran and ended.
nonisolated struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    /// The run's ID, so a run whose output is still in memory can show it.
    var id: UUID
    /// The command without spaces and tabs at either end.
    var command: String
    /// When it started.
    var date: Date
    /// Seconds from start to end.
    var duration: TimeInterval
    /// The exit status, or nil when the shell did not exit by itself.
    var exitStatus: Int32?
    /// True when the user stopped it.
    var stopped: Bool

    init(id: UUID, command: String, date: Date, duration: TimeInterval, exitStatus: Int32?, stopped: Bool) {
        self.id = id
        self.command = command
        self.date = date
        self.duration = duration
        self.exitStatus = exitStatus
        self.stopped = stopped
    }

    private enum CodingKeys: String, CodingKey {
        case id, command, date, duration, exitStatus, stopped
    }

    /// Reads an entry a person may have edited: the ID, the command and the date must be there; a
    /// missing duration reads as zero and a missing stop as false.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        command = try container.decode(String.self, forKey: .command)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        exitStatus = try container.decodeIfPresent(Int32.self, forKey: .exitStatus)
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }

    /// The entry for a run that ended, or nil while it goes on.
    @MainActor init?(_ run: ShellRun) {
        guard let ending = run.ending, let endedAt = run.endedAt else { return nil }
        let status: Int32? =
            switch ending {
            case .exit(let code): code
            case .stopped, .couldNotStart: nil
            }
        self.init(
            id: run.id, command: run.command.trimmed, date: run.startedAt,
            duration: max(0, endedAt.timeIntervalSince(run.startedAt)), exitStatus: status,
            stopped: ending == .stopped)
    }
}

/// The history file. Versioned, so a later version can read it.
nonisolated struct HistoryFile: Codable, Hashable, Sendable {
    /// The format this version writes. A file with a higher number came from a newer version.
    static let currentVersion = 1

    var version = currentVersion
    var entries: [HistoryEntry] = []
}

/// Only the version of a history file, read first, so a file from a newer version is never set
/// aside when its entries do not read in this version.
nonisolated struct HistoryVersion: Codable, Hashable, Sendable {
    var version: Int
}

/// What reading the history file found.
nonisolated struct HistoryRead: Sendable {
    var entries: [HistoryEntry]
    /// The file came from a newer version, so this one never saves over it.
    var isNewer = false
}

/// Commands that ran, newest first, at most ``limit``, kept in `history.json` in the feature's data
/// folder. The working copy lives in memory; every change is saved off the main thread.
///
/// A command typed with a space before it never gets here, and nothing is recorded while history is
/// off. The same command run again moves to the top with its new status. Nothing the history holds
/// is ever logged.
final class ShellHistory {
    nonisolated static let fileName = "history.json"
    /// The most commands kept.
    nonisolated static let limit = 200

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []
    /// True when the file came from a newer version. Changes then stay in memory and the file is
    /// never written.
    private(set) var isReadOnly = false
    /// Sent after every change, so an open history page reloads.
    let changes: ChangeSignal
    /// Sent when ``isReadOnly`` changes, so settings shows the feature's status again.
    let statusChanges = ChangeSignal()

    private let store: JSONFileStore<HistoryFile>
    private let versionStore: JSONFileStore<HistoryVersion>
    private let settings: FeatureSettings
    private let log: Logger
    private var loading: Task<Void, Never>?

    init(context: FeatureContext, changes: ChangeSignal) {
        store = JSONFileStore(url: context.storage.dataFile(Self.fileName))
        versionStore = JSONFileStore(url: context.storage.dataFile(Self.fileName))
        settings = context.settings
        log = context.log
        self.changes = changes
    }

    /// True when the user keeps a history.
    var isEnabled: Bool { settings[ShellSettings.keepsHistory] }

    /// Reads the file again, off the main thread. Called at each activation, so edits made while
    /// the feature was off are seen. A file that cannot be read is set aside, never overwritten.
    func reload() {
        let (store, versionStore) = (self.store, self.versionStore)
        let previous = loading
        loading = Task { [weak self] in
            await previous?.value
            let read = await Self.read(store, version: versionStore)
            guard let self else { return }
            entries = read.entries
            if isReadOnly != read.isNewer {
                isReadOnly = read.isNewer
                statusChanges.send()
            }
            changes.send()
        }
    }

    /// Waits until the file was read.
    func loaded() async {
        if loading == nil { reload() }
        await loading?.value
    }

    /// Keeps a command that ended, unless history is off. An earlier entry for the same command
    /// goes.
    func record(_ entry: HistoryEntry) async {
        guard isEnabled else { return }
        await loaded()
        var next = entries.filter { $0.command != entry.command && $0.id != entry.id }
        next.insert(entry, at: 0)
        await commit(Array(next.prefix(Self.limit)))
    }

    /// Removes one entry.
    func delete(_ id: UUID) async {
        await loaded()
        await commit(entries.filter { $0.id != id })
    }

    /// Removes every entry, and the damaged files set aside beside the history.
    func clear() async {
        await loaded()
        await commit([])
        await Self.removeSetAside(in: store.url.deletingLastPathComponent())
    }

    /// The entry with this ID, if it is still kept.
    func entry(_ id: UUID) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    private func commit(_ next: [HistoryEntry]) async {
        guard next != entries else { return }
        entries = next
        changes.send()
        guard !isReadOnly else {
            log.notice("Shell history was not saved: the file came from a newer version")
            return
        }
        do {
            try await store.save(HistoryFile(entries: next))
            await Self.leaveOutOfBackups(store.url.deletingLastPathComponent())
        } catch {
            log.error("Shell history was not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// The stored history, newest first. A file from a newer version is read as far as this version
    /// can and marked, so it is never saved over; when its entries do not read, the history shows
    /// none. A damaged file of this version or older is renamed beside itself, with a number, and an
    /// empty history starts, so the user's file is never lost or overwritten.
    @concurrent private static func read(
        _ store: JSONFileStore<HistoryFile>, version versionStore: JSONFileStore<HistoryVersion>
    ) async -> HistoryRead {
        let version: Int
        do {
            guard let stored = try await versionStore.load() else { return HistoryRead(entries: []) }
            version = stored.version
            markLeftOutOfBackups(store.url.deletingLastPathComponent())
        } catch {
            setAside(store.url)
            return HistoryRead(entries: [])
        }
        let isNewer = version > HistoryFile.currentVersion
        do {
            let file = try await store.load(default: HistoryFile())
            return HistoryRead(entries: cleaned(file.entries), isNewer: isNewer)
        } catch {
            if !isNewer { setAside(store.url) }
            return HistoryRead(entries: [], isNewer: isNewer)
        }
    }

    /// Entries a person or another program may have edited, made safe to show and to put back in
    /// root search: commands the feature would run, trimmed; durations that are numbers and not
    /// negative; each ID and each command once; newest first; at most ``limit``.
    nonisolated static func cleaned(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var seenIDs = Set<UUID>()
        var seenCommands = Set<String>()
        var kept: [HistoryEntry] = []
        for var entry in entries.sorted(by: { $0.date > $1.date }) {
            guard case .success(let command) = ShellCommand.check(entry.command) else { continue }
            entry.command = command.trimmed
            entry.duration = entry.duration.isFinite ? max(0, entry.duration) : 0
            guard seenIDs.insert(entry.id).inserted, seenCommands.insert(entry.command).inserted else { continue }
            kept.append(entry)
            if kept.count == limit { break }
        }
        return kept
    }

    /// Marks the feature's folder, and so the history and any copy set aside, as left out of Time
    /// Machine and other backups, as Clipboard does. The history can hold a secret typed into a
    /// command.
    @concurrent private static func leaveOutOfBackups(_ folder: URL) async {
        markLeftOutOfBackups(folder)
    }

    nonisolated private static func markLeftOutOfBackups(_ folder: URL) {
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Deletes the copies ``setAside(_:)`` made, and nothing else in the folder.
    @concurrent private static func removeSetAside(in folder: URL) async {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix("history-damaged-") && name.hasSuffix(".json") {
            try? manager.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    nonisolated private static func setAside(_ url: URL) {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        for number in 1...999 {
            let target = folder.appending(path: "history-damaged-\(number).json", directoryHint: .notDirectory)
            guard !manager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try? manager.moveItem(at: url, to: target)
            return
        }
    }
}
