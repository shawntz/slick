import Foundation
import Kit
import KitStorage
import os

/// One answer the user copied or pasted.
nonisolated struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// What the user typed, trimmed.
    var question: String
    /// The answer as shown.
    var answer: String
    /// The answer as a plain number, when it is one.
    var plainNumber: String?
    var date: Date
}

/// The history file. Versioned, so a later change can read it.
nonisolated struct HistoryFile: Codable, Hashable, Sendable {
    /// The format this version writes. A file with a higher number came from a newer version.
    static let currentVersion = 1

    var version = currentVersion
    var entries: [HistoryEntry] = []
}

/// What reading the history file found.
nonisolated struct HistoryRead: Sendable {
    var entries: [HistoryEntry]
    /// The file came from a newer version, so this one must never save over it.
    var isNewer = false
}

/// Answers the user copied or pasted, newest first, kept in `history.json` in the feature's data
/// folder. The working copy lives in memory; every change is saved off the main thread.
final class CalcHistory {
    nonisolated static let fileName = "history.json"

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []
    /// True when the file came from a newer version. Changes then stay in memory and the file is
    /// never written, so nothing the newer version stored is lost.
    private(set) var isReadOnly = false
    /// Sent after every change, so an open history page reloads.
    let changes = ChangeSignal()
    /// Sent when ``isReadOnly`` changes, so settings shows the feature's status again.
    let statusChanges = ChangeSignal()

    private let store: JSONFileStore<HistoryFile>
    private let settings: FeatureSettings
    private let clock: any ClockService
    private let log: Logger
    private var loading: Task<Void, Never>?

    init(context: FeatureContext) {
        store = JSONFileStore(url: context.storage.dataFile(Self.fileName))
        settings = context.settings
        clock = context.clock
        log = context.log
    }

    /// True when the user keeps a history.
    var isEnabled: Bool { settings[CalcSettings.keepsHistory] }

    /// The most entries kept, from settings, within sane bounds.
    var limit: Int {
        let range = CalcSettings.historyLimitRange
        return min(max(settings[CalcSettings.historyLimit], range.lowerBound), range.upperBound)
    }

    /// Reads the file again, off the main thread. Called at each activation, so edits made while the
    /// feature was off are seen. A file that cannot be read is set aside, never overwritten.
    func reload() {
        let store = self.store
        let previous = loading
        loading = Task { [weak self] in
            await previous?.value
            let read = await Self.read(store)
            guard let self else { return }
            self.entries = read.entries
            if self.isReadOnly != read.isNewer {
                self.isReadOnly = read.isNewer
                self.statusChanges.send()
            }
            self.changes.send()
        }
    }

    /// Waits until the file was read.
    func loaded() async {
        if loading == nil { reload() }
        await loading?.value
    }

    /// Keeps an answer, unless history is off. The same question asked again moves to the top
    /// with its new answer.
    func record(question: String, answer: String, plainNumber: String?) async {
        let question = CalcStrings.oneLine(question)
        let answer = CalcStrings.oneLine(answer)
        guard isEnabled, !question.isEmpty, !answer.isEmpty else { return }
        await loaded()
        let entry = HistoryEntry(
            id: UUID(), question: question, answer: answer, plainNumber: plainNumber, date: clock.now)
        var next = entries.filter { $0.question != question }
        next.insert(entry, at: 0)
        await commit(Array(next.prefix(limit)))
    }

    /// Removes one entry.
    func delete(_ id: UUID) async {
        await loaded()
        await commit(entries.filter { $0.id != id })
    }

    /// Removes every entry.
    func clear() async {
        await loaded()
        await commit([])
    }

    /// Drops the oldest entries past the limit, after the user lowered it.
    func applyLimit() async {
        await loaded()
        guard entries.count > limit else { return }
        await commit(Array(entries.prefix(limit)))
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
            log.notice("Calculator history was not saved: the file came from a newer version")
            return
        }
        do {
            try await store.save(HistoryFile(entries: next))
        } catch {
            log.error("Calculator history was not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// The stored history, newest first. A damaged file is renamed beside itself, with a number,
    /// and an empty history starts, so the user's file is never lost or overwritten. A file from a
    /// newer version is read but marked, so it is never saved over in this version's format.
    @concurrent private static func read(_ store: JSONFileStore<HistoryFile>) async -> HistoryRead {
        let file: HistoryFile
        do {
            file = try await store.load(default: HistoryFile())
        } catch {
            setAside(store.url)
            return HistoryRead(entries: [])
        }
        return HistoryRead(
            entries: cleaned(file.entries), isNewer: file.version > HistoryFile.currentVersion)
    }

    /// Entries a person or another program may have edited, made safe to show: question and
    /// answer on one line, entries without either dropped, the same ID kept once, newest first.
    nonisolated static func cleaned(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<UUID>()
        var kept: [HistoryEntry] = []
        for var entry in entries.sorted(by: { $0.date > $1.date }) {
            entry.question = CalcStrings.oneLine(entry.question)
            entry.answer = CalcStrings.oneLine(entry.answer)
            entry.plainNumber = entry.plainNumber.map(CalcStrings.oneLine)
            guard !entry.question.isEmpty, !entry.answer.isEmpty, seen.insert(entry.id).inserted else { continue }
            kept.append(entry)
        }
        return kept
    }

    nonisolated private static func setAside(_ url: URL) {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        for number in 1...999 {
            let target = folder.appending(path: "history-damaged-\(number).json", directoryHint: .notDirectory)
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.moveItem(at: url, to: target)
            return
        }
    }
}
