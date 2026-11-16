import Darwin
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import MarkdownNotes

/// Synthetic notes for tests. Nothing here comes from a real person.
enum Sample {
    static let groceries = "# Groceries\n\nMilk and eggs\n\n#errands\n"
    static let budget = "# Budget 2027\n\nRent, travel and savings.\n"
    static let trip = "Trip ideas\n\nVisit the coast and plan the budget for the ferry.\n"
    static let meeting = "## Weekly sync\n\n- Agenda\n- Notes from the café\n\n#work #team\n"
}

/// Days before the fake clock's now, as dates.
func daysAgo(_ days: Double, hours: Double = 0, clock: FakeClock) -> Date {
    clock.now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
}

extension FeatureHarness where F == NotesFeature {
    /// A harness whose default folder holds these notes, activated and loaded. Each note is dated
    /// one hour older than the one before it, in the order given.
    static func make(
        _ notes: [(String, String)] = [], limits: NoteLimits = .standard, fakes: FakeServices = FakeServices(),
        activate: Bool = true
    ) async throws -> FeatureHarness<NotesFeature> {
        let harness = FeatureHarness(fakes: fakes) { NotesFeature(context: $0, limits: limits) }
        for (position, (name, text)) in notes.enumerated() {
            try harness.write(name, text, modified: daysAgo(0, hours: Double(position) + 1, clock: fakes.clock))
        }
        if activate { try await harness.start() }
        return harness
    }

    /// Activates the feature and waits for the first scan.
    func start() async throws {
        await activate()
        await feature.waitUntilReady()
    }

    var library: NoteLibrary { feature.library }

    /// The default notes folder.
    var defaultFolder: URL { NoteLibrary.defaultFolderURL(for: context) }

    /// The synthetic home folder of this run.
    var home: URL { context.storage.homeDirectory }

    /// Writes a file into a folder, the default one unless given, and dates it.
    func write(_ name: String, _ text: String, in folder: URL? = nil, modified: Date? = nil) throws {
        try writeData(name, Data(text.utf8), in: folder, modified: modified)
    }

    func writeData(_ name: String, _ data: Data, in folder: URL? = nil, modified: Date? = nil) throws {
        let folder = folder ?? defaultFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        try setModified(name, modified ?? fakes.clock.now, in: folder)
    }

    func setModified(_ name: String, _ date: Date, in folder: URL? = nil) throws {
        let url = (folder ?? defaultFolder).appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// What a file in the default folder holds now.
    func text(of name: String, in folder: URL? = nil) throws -> String {
        try String(contentsOf: (folder ?? defaultFolder).appending(path: name), encoding: .utf8)
    }

    /// Every name in a folder, hidden ones too, sorted.
    func names(in folder: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (folder ?? defaultFolder).path).sorted()
    }

    /// Plays a change in the notes folder and waits until the feature has read it.
    func announceChange(in folder: URL? = nil) async throws {
        fakes.fileWatcher.simulateChange([folder ?? library.index.folder.url])
        try await settle()
    }

    /// Opens Search Notes.
    func openSearch() async throws {
        try await run(NoteIDs.searchCommand)
    }

    /// The titles of the visible sections.
    var sectionTitles: [String?] { sections.map(\.title) }

    /// The IDs of the selected row's actions.
    func actionIDs(of title: String) throws -> [String] {
        try select(title: title)
        return actions().map(\.id)
    }
}

/// A disk that forwards to another and records every name it read, for checking that a file was
/// never opened.
nonisolated final class RecordingDisk: NoteDisk {
    private let base: any NoteDisk
    private let reads = Mutex<[String]>([])
    private let lists = Mutex<[String]>([])
    /// Entries to report as dataless, by name.
    let dataless: Set<String>

    init(base: any NoteDisk, dataless: Set<String> = []) {
        self.base = base
        self.dataless = dataless
    }

    var readNames: [String] { reads.withLock { $0 } }
    /// The folders listed, by last path component.
    var listedFolders: [String] { lists.withLock { $0 } }

    func list(_ folder: URL, limit: Int) throws(DiskError) -> DiskListing {
        lists.withLock { $0.append(folder.lastPathComponent) }
        var listing = try base.list(folder, limit: limit)
        listing.entries = listing.entries.map { entry in
            var entry = entry
            if dataless.contains(entry.name) { entry.isDataless = true }
            return entry
        }
        return listing
    }

    func read(_ name: String, in folder: URL, limit: Int) throws(DiskError) -> DiskRead {
        reads.withLock { $0.append(name) }
        if dataless.contains(name) { throw .notDownloaded }
        return try base.read(name, in: folder, limit: limit)
    }

    func entry(_ name: String, in folder: URL) throws(DiskError) -> DiskEntry {
        try base.entry(name, in: folder)
    }

    func write(_ data: Data, named name: String, in folder: URL, mode: WriteMode, modified: Date) throws(DiskError) {
        try base.write(data, named: name, in: folder, mode: mode, modified: modified)
    }

    func move(_ name: String, to newName: String, in folder: URL) throws(DiskError) {
        try base.move(name, to: newName, in: folder)
    }

    func prepare(_ folder: URL) throws(DiskError) {
        try base.prepare(folder)
    }
}
