import Foundation
import Kit
import KitStorage
import os

/// Where a color in the history came from.
nonisolated enum ColorSource: String, Codable, Hashable, Sendable {
    /// Pick Color, from the screen.
    case picked
    /// A color typed in root search and copied or pasted.
    case typed
}

/// One color in the history.
nonisolated struct ColorEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var color: ColorValue
    /// A name the user gave it, shown instead of the hex value.
    var name: String?
    var isPinned: Bool
    /// When it was picked or copied last.
    var date: Date
    var source: ColorSource

    init(
        id: UUID = UUID(), color: ColorValue, name: String? = nil, isPinned: Bool = false, date: Date,
        source: ColorSource
    ) {
        self.id = id
        self.color = color
        self.name = name
        self.isPinned = isPinned
        self.date = date
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, color, name, isPinned, date, source
    }

    /// Only the ID, the color and the date are required, so a file a person edited by hand still
    /// reads. A source this version does not know reads as picked.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        color = try container.decode(ColorValue.self, forKey: .color)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        date = try container.decode(Date.self, forKey: .date)
        let source = try container.decodeIfPresent(String.self, forKey: .source)
        self.source = source.flatMap(ColorSource.init(rawValue:)) ?? .picked
    }
}

/// The history file. Versioned, so a later change can read it.
nonisolated struct ColorHistoryFile: Codable, Hashable, Sendable {
    /// The format this version writes. A file with a higher number came from a newer version.
    static let currentVersion = 1

    var version = currentVersion
    var entries: [ColorEntry] = []
}

/// What reading the history file found.
nonisolated struct ColorHistoryRead: Sendable {
    var entries: [ColorEntry]
    /// The file came from a newer version, so this one must never save over it.
    var isNewer = false
}

/// Colors the user picked, or typed and copied, newest first, kept in `history.json` in the
/// feature's data folder. The working copy lives on the main actor; every change is saved off it.
final class ColorHistory {
    nonisolated static let fileName = "history.json"
    /// The longest name a color may have, in characters.
    nonisolated static let nameLimit = 60

    /// Newest first.
    private(set) var entries: [ColorEntry] = []
    /// True when the file came from a newer version. Changes then stay in memory and the file is
    /// never written, so nothing the newer version stored is lost.
    private(set) var isReadOnly = false
    /// Sent after every change, so an open history page reloads.
    let changes = ChangeSignal()
    /// Sent when ``isReadOnly`` changes, so settings shows the feature's status again.
    let statusChanges = ChangeSignal()

    private let store: JSONFileStore<ColorHistoryFile>
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

    /// The most unpinned colors kept, from settings, within sane bounds.
    var limit: Int {
        let range = ColorSettings.historyLimitRange
        return min(max(settings[ColorSettings.historyLimit], range.lowerBound), range.upperBound)
    }

    /// The pinned colors, newest first.
    var pinned: [ColorEntry] { entries.filter(\.isPinned) }

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

    /// The entry with this ID, if it is still kept.
    func entry(_ id: UUID) -> ColorEntry? {
        entries.first { $0.id == id }
    }

    /// Keeps a color and returns its entry. The same color again moves to the top and keeps its
    /// name and pin. Nil for a color whose components are not numbers.
    @discardableResult
    func add(_ color: ColorValue, source: ColorSource) async -> ColorEntry? {
        guard let color = color.sanitized else { return nil }
        await loaded()
        var next = entries
        var entry = ColorEntry(color: color, date: clock.now, source: source)
        if let index = next.firstIndex(where: { $0.color.matches(color) }) {
            let old = next.remove(at: index)
            entry.id = old.id
            entry.name = old.name
            entry.isPinned = old.isPinned
        }
        next.insert(entry, at: 0)
        await commit(trimmed(next))
        return entry
    }

    /// Removes one color.
    func delete(_ id: UUID) async {
        await loaded()
        await commit(entries.filter { $0.id != id })
    }

    /// Removes every color that is not pinned.
    func clear() async {
        await loaded()
        await commit(entries.filter(\.isPinned))
    }

    /// Pins or unpins a color. An unpinned color counts against the limit again from the next
    /// color kept, so unpinning never deletes a color at once.
    func setPinned(_ id: UUID, _ isPinned: Bool) async {
        await loaded()
        await commit(
            entries.map { entry in
                var entry = entry
                if entry.id == id { entry.isPinned = isPinned }
                return entry
            })
    }

    /// Names a color, or removes its name when the name shows nothing.
    func rename(_ id: UUID, to name: String) async {
        await loaded()
        let cleaned = Self.cleanName(name)
        await commit(
            entries.map { entry in
                var entry = entry
                if entry.id == id { entry.name = cleaned }
                return entry
            })
    }

    /// Drops the oldest unpinned colors past the limit, after the user lowered it.
    func applyLimit() async {
        await loaded()
        await commit(trimmed(entries))
    }

    /// The entries with the oldest unpinned ones past the limit dropped.
    private func trimmed(_ entries: [ColorEntry]) -> [ColorEntry] {
        var unpinned = 0
        let limit = self.limit
        return entries.filter { entry in
            guard !entry.isPinned else { return true }
            unpinned += 1
            return unpinned <= limit
        }
    }

    private func commit(_ next: [ColorEntry]) async {
        guard next != entries else { return }
        entries = next
        changes.send()
        guard !isReadOnly else {
            log.notice("Color history was not saved: the file came from a newer version")
            return
        }
        do {
            try await store.save(ColorHistoryFile(entries: next))
        } catch {
            // A file error names the file's path, which holds the account name.
            log.error("Color history was not saved: \(String(describing: error), privacy: .private)")
        }
    }

    /// A name made safe to show: on one line, without spaces at either end, at most ``nameLimit``
    /// characters. Nil when nothing in it is visible.
    nonisolated static func cleanName(_ name: String) -> String? {
        let line = DisplayText.oneLine(name).trimmingCharacters(in: .whitespaces)
        let visible = line.unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
                && scalar != "\u{FFFD}"
        }
        guard visible else { return nil }
        return line.count > nameLimit ? String(line.prefix(nameLimit)) : line
    }

    /// The stored history, newest first. A damaged file is renamed beside itself, with a number,
    /// and an empty history starts, so the user's file is never lost or overwritten. A file from a
    /// newer version is read but marked, so it is never saved over in this version's format. That
    /// holds too when its entries have a shape this version cannot read: it stays where it is, and
    /// the history shows nothing until that version runs again.
    @concurrent private static func read(_ store: JSONFileStore<ColorHistoryFile>) async -> ColorHistoryRead {
        let file: ColorHistoryFile
        do {
            file = try await store.load(default: ColorHistoryFile())
        } catch {
            if isFromNewerVersion(store.url) { return ColorHistoryRead(entries: [], isNewer: true) }
            setAside(store.url)
            return ColorHistoryRead(entries: [])
        }
        return ColorHistoryRead(entries: cleaned(file.entries), isNewer: file.version > ColorHistoryFile.currentVersion)
    }

    /// Only the version of a history file.
    private nonisolated struct FileVersion: Decodable {
        var version: Int
    }

    /// True when the file says it comes from a newer version, whatever else it holds.
    nonisolated private static func isFromNewerVersion(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(FileVersion.self, from: data)
        else { return false }
        return file.version > ColorHistoryFile.currentVersion
    }

    /// Entries a person or another program may have edited, made safe to show: names on one line
    /// and visible, colors with numbers in range, the same ID kept once, newest first.
    nonisolated static func cleaned(_ entries: [ColorEntry]) -> [ColorEntry] {
        var seen = Set<UUID>()
        var kept: [ColorEntry] = []
        for var entry in entries.sorted(by: { $0.date > $1.date }) {
            guard let color = entry.color.sanitized, seen.insert(entry.id).inserted else { continue }
            entry.color = color
            entry.name = entry.name.flatMap(cleanName)
            kept.append(entry)
        }
        return kept
    }

    nonisolated private static func setAside(_ url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let folder = url.deletingLastPathComponent()
        for number in 1...999 {
            let target = folder.appending(path: "history-damaged-\(number).json", directoryHint: .notDirectory)
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.moveItem(at: url, to: target)
            return
        }
    }
}
