import Foundation
import Kit

/// The notes folder as an actor: every scan, read and write runs here, one at a time, off the main
/// thread.
///
/// A scan lists the folder and reads only the notes whose size, inode or modification time changed
/// since the last scan, so the rescan after each file event costs one listing. Each scan and each
/// change gives a new ``NoteIndex`` with a higher generation, so the library never applies an
/// older result over a newer one.
actor NoteStore {
    private let disk: any NoteDisk
    private let limits: NoteLimits
    private var folder: NoteFolder
    /// The notes of the last scan by file name, reused while their files stay the same.
    private var records: [String: NoteRecord] = [:]
    private(set) var index: NoteIndex
    private var generation = 0

    init(disk: any NoteDisk, limits: NoteLimits, folder: NoteFolder) {
        self.disk = disk
        self.limits = limits
        self.folder = folder
        index = NoteIndex(folder: folder, generation: 0)
    }

    /// Points the store at a folder and, in the same step, reads it or marks it as waiting for the
    /// user. One step, so no other call on the store can come between the switch and the read: a
    /// read meant for one folder never lands on another, such as a guarded folder that waits for
    /// the user.
    func open(_ folder: NoteFolder, read: Bool) -> NoteIndex {
        use(folder)
        return read ? scan() : wait()
    }

    /// Lists the folder again when it is still `folder`. Otherwise reads nothing and returns the
    /// index as it stands, so a rescan for a folder the user has left never reads the new one.
    func rescan(_ folder: NoteFolder) -> NoteIndex {
        guard folder == self.folder, index.folder == folder, index.problem != .waitingForRead else { return index }
        return scan()
    }

    /// Points the store at another folder and forgets what the last one held.
    private func use(_ folder: NoteFolder) {
        guard folder != self.folder else { return }
        self.folder = folder
        records = [:]
    }

    /// An index for a guarded folder that waits for the user to start its first read.
    private func wait() -> NoteIndex {
        records = [:]
        return publish(NoteIndex(folder: folder, problem: .waitingForRead, generation: nextGeneration()))
    }

    // MARK: Scanning

    /// Lists the folder and reads what changed. A scan whose task is cancelled publishes nothing.
    @discardableResult
    func scan() -> NoteIndex {
        if folder.isDefault {
            do throws(DiskError) {
                try disk.prepare(folder.url)
            } catch {
                return fail(error)
            }
        }
        let listing: DiskListing
        do throws(DiskError) {
            listing = try disk.list(folder.url, limit: limits.entries)
        } catch {
            return fail(error)
        }
        var stats = ScanStats()
        stats.entriesCut = listing.isCut
        var candidates: [DiskEntry] = []
        for entry in listing.entries {
            switch entry.kind {
            case .regular: candidates.append(entry)
            case .link: stats.links += 1
            case .other: stats.notText += 1
            case .folder: break
            }
        }
        candidates.sort(by: Self.newestFirst)
        if candidates.count > limits.notes {
            stats.leftOut = candidates.count - limits.notes
            candidates.removeSubrange(limits.notes...)
        }
        var budget = limits.searchBytes
        var fresh: [String: NoteRecord] = [:]
        var notes: [NoteRecord] = []
        notes.reserveCapacity(candidates.count)
        for (position, entry) in candidates.enumerated() {
            if position % 64 == 0, Task.isCancelled { return index }
            guard let record = record(for: entry, budget: &budget, stats: &stats) else { continue }
            fresh[record.fileName] = record
            notes.append(record)
        }
        notes.sort { Self.newestFirst($0.modified, $0.fileName, $1.modified, $1.fileName) }
        records = fresh
        return publish(NoteIndex(folder: folder, notes: notes, stats: stats, generation: nextGeneration()))
    }

    /// The note for one entry: the last scan's when the file is the same, else read now. Nil for a
    /// file that is not text or cannot be read; the stats say which.
    private func record(for entry: DiskEntry, budget: inout Int, stats: inout ScanStats) -> NoteRecord? {
        if let old = records[entry.name], old.version == entry.version, old.isDataless == entry.isDataless,
            !(old.isTitleOnly && Int(clamping: entry.version.size) <= budget)
        {
            if old.isCut { stats.cut += 1 }
            if old.isDataless {
                stats.notDownloaded += 1
                return old
            }
            if let text = old.text {
                guard text.bytes <= budget else {
                    stats.titleOnly += 1
                    return old.titleOnly()
                }
                budget -= text.bytes
                return old
            }
            stats.titleOnly += 1
            return old
        }
        guard !entry.isDataless else {
            stats.notDownloaded += 1
            return placeholder(for: entry)
        }
        let read: DiskRead
        do throws(DiskError) {
            read = try disk.read(entry.name, in: folder.url, limit: limits.bytesPerNote)
        } catch .notDownloaded {
            stats.notDownloaded += 1
            return placeholder(for: entry)
        } catch .missing {
            return nil
        } catch .notRegularFile {
            stats.notText += 1
            return nil
        } catch {
            stats.unreadable += 1
            return nil
        }
        guard let text = NoteDecoding.text(read.data, isCut: read.isCut) else {
            stats.notText += 1
            return nil
        }
        if read.isCut { stats.cut += 1 }
        let parsed = NoteText.parse(text)
        let title = NoteTitles.title(parsed, fileName: entry.name)
        let bytes = text.utf8.count
        let fits = bytes <= budget
        if fits {
            budget -= bytes
        } else {
            stats.titleOnly += 1
        }
        return NoteRecord(
            fileName: entry.name, title: title, foldedTitle: NoteSearch.fold(title), tags: parsed.tags,
            preview: NoteTitles.preview(parsed), modified: read.entry.modified, version: read.entry.version,
            isCut: read.isCut, isDataless: false, text: fits ? NoteSearchText(text) : nil, isTitleOnly: !fits)
    }

    /// A note whose contents are only in the cloud, named by its file and never read here.
    private func placeholder(for entry: DiskEntry) -> NoteRecord {
        let title = NoteTitles.title(NoteText(title: "", style: .none, body: ""), fileName: entry.name)
        return NoteRecord(
            fileName: entry.name, title: title, foldedTitle: NoteSearch.fold(title), tags: [], preview: "",
            modified: entry.modified, version: entry.version, isCut: false, isDataless: true, text: nil,
            isTitleOnly: false)
    }

    // MARK: Reading one note

    /// A note's text as the file holds it now, at most `limit` bytes.
    func read(_ fileName: String, limit: Int) throws(NoteFailure) -> NoteRead {
        let read: DiskRead
        do throws(DiskError) {
            read = try disk.read(fileName, in: folder.url, limit: limit)
        } catch {
            throw .disk(error)
        }
        guard let text = NoteDecoding.text(read.data, isCut: read.isCut) else { throw .notText }
        let roundTrip = NoteDecoding.roundTrip(read.data, text: text)
        return NoteRead(
            text: text, data: read.data, version: read.entry.version, isCut: read.isCut,
            isExact: roundTrip.isExact && !read.isCut, byteOrderMark: roundTrip.byteOrderMark)
    }

    /// The note's file, after checking that it is still a regular file in the folder. Destructive
    /// actions call this just before they act, so a stale row cannot name something else.
    func liveFile(_ fileName: String) throws(NoteFailure) -> URL {
        guard NoteFileName.isNoteFile(fileName) else { throw .disk(.badName) }
        let entry: DiskEntry
        do throws(DiskError) {
            entry = try disk.entry(fileName, in: folder.url)
        } catch {
            throw .disk(error)
        }
        guard entry.kind == .regular else { throw .disk(.notRegularFile) }
        return folder.url.appending(path: fileName, directoryHint: .notDirectory)
    }

    // MARK: Changing notes

    /// Writes a new note named after its title, and returns its file name.
    func create(_ text: String, now: Date) throws(NoteFailure) -> String {
        try requireUsable()
        let data = Data(text.utf8)
        guard data.count <= limits.bytesForActions else { throw .tooLong }
        let base = NoteTitles.fileBase(NoteText.parse(text), fileName: nil)
        let name = try place(data, base: base, now: now)
        scan()
        return name
    }

    /// Replaces a note's text when the file is still the version the user started from, and
    /// renames the file when the title changed. Returns the file name it has now. Throws
    /// ``DiskError/changedElsewhere`` when another app changed it meanwhile; nothing is written then.
    /// A note that started with a UTF-8 byte order mark keeps it.
    func replace(
        _ fileName: String, with text: String, expected: FileVersion, byteOrderMark: Bool = false, now: Date
    ) throws(NoteFailure) -> String {
        try requireUsable()
        var data = byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(contentsOf: text.utf8)
        guard data.count <= limits.bytesForActions else { throw .tooLong }
        let current: DiskEntry
        do throws(DiskError) {
            current = try disk.entry(fileName, in: folder.url)
        } catch {
            throw .disk(error)
        }
        guard current.kind == .regular else { throw .disk(.notRegularFile) }
        guard current.version == expected else { throw .disk(.changedElsewhere) }
        let base = NoteTitles.fileBase(NoteText.parse(text), fileName: fileName)
        var name = fileName
        if !Self.name(fileName, fits: base) {
            name = try move(fileName, toBase: base)
        }
        do throws(DiskError) {
            try disk.write(data, named: name, in: folder.url, mode: .replace(expected: expected), modified: now)
        } catch {
            scan()
            throw .disk(error)
        }
        scan()
        return name
    }

    /// Writes a copy of the note's file, byte for byte, under a new name.
    func duplicate(_ fileName: String, now: Date) throws(NoteFailure) -> String {
        try requireUsable()
        let note = try read(fileName, limit: limits.bytesForActions)
        guard !note.isCut else { throw .tooLong }
        let base = NoteTitles.fileBase(NoteText.parse(note.text), fileName: fileName)
        let name = try place(note.data, base: base, now: now)
        scan()
        return name
    }

    /// Creates a file with a unique name made from `base`.
    private func place(_ data: Data, base: String, now: Date) throws(NoteFailure) -> String {
        // The default folder is the feature's own: if someone deleted it, it comes back.
        if folder.isDefault { try? disk.prepare(folder.url) }
        var taken = takenNames()
        for _ in 0..<1_000 {
            let name = NoteFileName.unique(base) { taken.contains(NoteFileName.comparable($0)) }
            do throws(DiskError) {
                try disk.write(data, named: name, in: folder.url, mode: .create, modified: now)
                return name
            } catch .nameTaken {
                taken.insert(NoteFileName.comparable(name))
            } catch {
                throw .disk(error)
            }
        }
        throw .disk(.nameTaken)
    }

    /// Renames a note to a unique name made from `base`.
    private func move(_ fileName: String, toBase base: String) throws(NoteFailure) -> String {
        var taken = takenNames()
        taken.remove(NoteFileName.comparable(fileName))
        for _ in 0..<1_000 {
            let name = NoteFileName.unique(base) { taken.contains(NoteFileName.comparable($0)) }
            do throws(DiskError) {
                try disk.move(fileName, to: name, in: folder.url)
                return name
            } catch .nameTaken {
                taken.insert(NoteFileName.comparable(name))
            } catch {
                throw .disk(error)
            }
        }
        throw .disk(.nameTaken)
    }

    /// The names in the folder now, compared as the volume compares them.
    private func takenNames() -> Set<String> {
        let entries = (try? disk.list(folder.url, limit: limits.entries).entries) ?? []
        return Set(entries.map { NoteFileName.comparable($0.name) })
    }

    /// True when the file's name already follows the title: the base itself, or the base and a
    /// number, as a second note with the same title gets.
    static func name(_ fileName: String, fits base: String) -> Bool {
        let stem = NoteFileName.comparable(NoteFileName.stem(fileName))
        let base = NoteFileName.comparable(base)
        guard stem != base else { return true }
        guard stem.hasPrefix(base + " ") else { return false }
        let number = stem.dropFirst(base.count + 1)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Changes go only to a folder that was read without a problem.
    private func requireUsable() throws(NoteFailure) {
        if let problem = index.problem { throw .unavailable(problem) }
    }

    // MARK: Publishing

    private func fail(_ error: DiskError) -> NoteIndex {
        records = [:]
        return publish(NoteIndex(folder: folder, problem: FolderProblem(error), generation: nextGeneration()))
    }

    private func publish(_ index: NoteIndex) -> NoteIndex {
        self.index = index
        return index
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private static func newestFirst(_ left: DiskEntry, _ right: DiskEntry) -> Bool {
        newestFirst(left.modified, left.name, right.modified, right.name)
    }

    private static func newestFirst(_ leftDate: Date, _ leftName: String, _ rightDate: Date, _ rightName: String)
        -> Bool
    {
        leftDate != rightDate ? leftDate > rightDate : leftName < rightName
    }
}

/// One note's text as read for an action.
nonisolated struct NoteRead: Sendable {
    var text: String
    /// The bytes as the file holds them, for a copy that keeps them exactly.
    var data: Data
    var version: FileVersion
    var isCut: Bool
    /// True when the bytes are exactly the text in UTF-8, after the byte order mark if any. Only such
    /// a note may be changed here; see ``NoteDecoding/roundTrip(_:text:)``.
    var isExact: Bool
    /// True when the file starts with a UTF-8 byte order mark, which a change keeps.
    var byteOrderMark: Bool
}

/// Why a change to a note failed.
nonisolated enum NoteFailure: Error, Hashable, Sendable {
    case disk(DiskError)
    /// The note is longer than the feature reads for this.
    case tooLong
    case notText
    /// The folder could not be read, so nothing is written there.
    case unavailable(FolderProblem)
    case nothingToAppend
}

extension FolderProblem {
    nonisolated init(_ error: DiskError) {
        switch error {
        case .folderMissing, .missing: self = .missing
        case .notAFolder, .notRegularFile: self = .notAFolder
        case .accessRefused: self = .refused
        case .outsideRun: self = .outsideRun
        case .system(let code): self = .failed(code)
        case .notDownloaded, .nameTaken, .changedElsewhere, .badName: self = .failed(EIO)
        }
    }
}
