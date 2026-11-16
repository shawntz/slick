import Foundation
import Kit
import KitStorage
import os

/// The notes as the main thread sees them: the last index, the pins, and every change, each handed
/// to ``NoteStore`` so no file work runs here.
///
/// Pins live in `pins.json` in the feature's data folder, keyed by folder and file name, never in
/// the notes. A pin is the launcher's state, like a favorite: writing it into a note would change
/// the file, its modification date and so its place in the list, and would show up as a change in
/// every other editor and in sync.
final class NoteLibrary {
    /// Where the pins file stands.
    enum PinState: Hashable {
        case loading
        case ready
        /// The file exists and cannot be read. It is kept, and pins cannot change.
        case unreadable
        /// The file was written by a newer version. Its pins show, and nothing is saved over it.
        case newerVersion
    }

    /// Sent when the notes, their pins or the folder's problems change. Pages and root search
    /// reload on it.
    let changes = ChangeSignal()
    /// Sent when what settings shows changes: the folder, its problem or the pins' state.
    let statusChanges = ChangeSignal()
    let limits: NoteLimits

    private(set) var index: NoteIndex
    private(set) var pinned: Set<String> = []
    private(set) var pinState = PinState.loading

    private let context: FeatureContext
    private let store: NoteStore
    private let pinStore: JSONFileStore<PinFile>
    private var pinFile = PinFile()
    private var startup: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private var watchedFolder: NoteFolder?
    /// The folder the last open asked for, set before it awaits, so a second request for the same
    /// folder does nothing.
    private var target: NoteFolder?

    /// Does no I/O: the store and the pins file are paths until ``start()``.
    init(context: FeatureContext, disk: any NoteDisk, limits: NoteLimits) {
        self.context = context
        self.limits = limits
        let folder = Self.folder(for: context)
        index = NoteIndex(folder: folder, generation: 0)
        store = NoteStore(disk: disk, limits: limits, folder: folder)
        pinStore = JSONFileStore(url: context.storage.dataFile("pins.json"))
    }

    /// The folder the settings name now. A value that is not an absolute path reads as the default.
    static func folder(for context: FeatureContext) -> NoteFolder {
        let defaultURL = defaultFolderURL(for: context)
        let path = context.settings[NotesSettings.folder]
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            return NoteFolder(url: defaultURL, isDefault: true, guarded: nil)
        }
        let url = URL(filePath: path, directoryHint: .isDirectory)
        if PosixNoteDisk.comparablePath(url) == PosixNoteDisk.comparablePath(defaultURL) {
            return NoteFolder(url: defaultURL, isDefault: true, guarded: nil)
        }
        return NoteFolder(
            url: url, isDefault: false, guarded: GuardedPlace.of(url, home: context.storage.homeDirectory))
    }

    /// The folder in the feature's own data folder.
    static func defaultFolderURL(for context: FeatureContext) -> URL {
        context.storage.dataDirectory.appending(path: NoteFolder.defaultName, directoryHint: .isDirectory)
    }

    // MARK: Lifecycle

    /// Loads the pins and opens the folder the settings name, in a task.
    @discardableResult
    func start() -> Task<Void, Never> {
        startup?.cancel()
        target = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadPins()
            guard !Task.isCancelled else { return }
            await self.open(Self.folder(for: self.context), userAsked: false)
        }
        startup = task
        return task
    }

    /// Stops the watch and any loading in progress, and waits until both have ended.
    func stop() async {
        let tasks = [startup, watch].compactMap(\.self)
        startup = nil
        watch = nil
        watchedFolder = nil
        target = nil
        for task in tasks {
            task.cancel()
            await task.value
        }
    }

    /// Waits for the first load after ``start()``.
    func ready() async {
        await startup?.value
    }

    /// Opens a folder: reads it, or, for a guarded folder whose first read the user has not
    /// started since choosing it, marks it as waiting without touching it. A read the user asked
    /// for may make macOS ask for access; that is the first read after the choice.
    func open(_ folder: NoteFolder, userAsked: Bool) async {
        target = folder
        let isConfirmed = context.settings[NotesSettings.confirmedFolder] == folder.path
        let mayRead = userAsked || folder.guarded == nil || isConfirmed
        let result = await store.open(folder, read: mayRead)
        apply(result)
        guard result.folder == folder else { return }
        if folder.guarded != nil, mayRead { remember(result) }
        follow(result.problem == nil ? folder : nil)
    }

    /// Follows the folder setting after it changed. Nothing happens when the folder is the one
    /// already open or asked for.
    func followFolderSetting(userAsked: Bool) async {
        let folder = Self.folder(for: context)
        guard userAsked || folder != (target ?? index.folder) else { return }
        await open(folder, userAsked: userAsked)
    }

    /// Lists the folder again and reads what changed. A folder that waits for the user is left
    /// alone.
    func rescan() async {
        guard index.problem != .waitingForRead else { return }
        let result = await store.rescan(index.folder)
        apply(result)
        if result.folder.guarded != nil, result.folder == index.folder { remember(result) }
    }

    /// Remembers a guarded folder after its first read worked, so later launches read it, and
    /// forgets it when macOS refused, so later launches wait for the user again.
    private func remember(_ result: NoteIndex) {
        let key = NotesSettings.confirmedFolder
        switch result.problem {
        case nil:
            if context.settings[key] != result.folder.path { context.settings[key] = result.folder.path }
        case .refused?:
            if context.settings[key] == result.folder.path { context.settings.reset(key) }
        default:
            break
        }
    }

    /// Watches the folder that reads, so an edit in another app shows at once.
    private func follow(_ folder: NoteFolder?) {
        guard folder != watchedFolder || watch == nil else { return }
        watch?.cancel()
        watch = nil
        watchedFolder = folder
        guard let folder else { return }
        // Subscribe before the task starts, so a change in between is not lost.
        let changes = context.fileWatcher.watch([folder.url])
        let path = folder.path
        watch = Task { [weak self] in
            for await paths in changes {
                // The watch covers every folder below, but notes live only in the folder itself, so
                // churn deeper down, such as in a home folder's Library, reads nothing.
                guard paths.contains(where: { Self.isInFolder($0, folder: path) }) else { continue }
                guard let self else { return }
                await self.rescan()
            }
        }
    }

    /// True for the folder itself or an item directly in it.
    nonisolated static func isInFolder(_ url: URL, folder: String) -> Bool {
        let path = PosixNoteDisk.comparablePath(url)
        return path == folder || PosixNoteDisk.comparablePath(url.deletingLastPathComponent()) == folder
    }

    /// Takes a newer index and tells whoever shows it.
    private func apply(_ result: NoteIndex) {
        guard result.generation > index.generation else { return }
        let before = index
        index = result
        if before.folder != result.folder { refreshPinned() }
        if before.fingerprint != result.fingerprint { changes.send() }
        if before.problem != result.problem || before.folder != result.folder { statusChanges.send() }
    }

    private func refreshIndex() async {
        apply(await store.index)
    }

    // MARK: Reading

    /// A note's text as the file holds it now.
    func read(_ fileName: String, limit: Int) async throws -> NoteRead {
        do throws(NoteFailure) {
            return try await store.read(fileName, limit: limit)
        } catch {
            throw error.actionFailure(folder: index.folder)
        }
    }

    /// A note's text for a change made here: Edit, Rename or Append. Refuses a note longer than the
    /// feature reads, and one whose bytes are not exactly its text in UTF-8, such as a note in
    /// Latin-1 or UTF-16: writing its text back would change bytes the user never touched.
    func readForChange(_ fileName: String) async throws -> NoteRead {
        let note = try await read(fileName, limit: limits.bytesPerNote)
        guard !note.isCut else { throw Strings.tooLong }
        guard note.isExact else { throw Strings.notPlainText }
        return note
    }

    /// The whole note, for an action that hands it on, such as Copy as Markdown.
    func wholeText(_ fileName: String) async throws -> String {
        let note = try await read(fileName, limit: limits.bytesForActions)
        guard !note.isCut else { throw Strings.tooLong }
        return note.text
    }

    /// The note's file after a check on the disk that it is still a regular file in the folder.
    func liveFile(_ fileName: String) async throws -> URL {
        do throws(NoteFailure) {
            return try await store.liveFile(fileName)
        } catch {
            throw error.actionFailure(folder: index.folder)
        }
    }

    // MARK: Changing

    /// Writes a new note and returns its file name.
    func create(_ text: String) async throws -> String {
        await ready()
        do throws(NoteFailure) {
            let name = try await store.create(text, now: context.clock.now)
            await refreshIndex()
            return name
        } catch {
            await refreshIndex()
            throw error.actionFailure(folder: index.folder)
        }
    }

    /// What a save from the editor did.
    enum SaveResult: Hashable {
        case saved(String)
        /// The note changed in another app while the editor was open, so the editor's text became a
        /// new note beside it.
        case savedAsCopy(String)
    }

    /// Saves the editor's text over the note when the file is still the one the editor read, and
    /// as a new note beside it otherwise. Nothing anyone wrote is lost. A byte order mark the note
    /// started with stays.
    func save(_ fileName: String, text: String, expected: FileVersion, byteOrderMark: Bool = false) async throws
        -> SaveResult
    {
        do throws(NoteFailure) {
            let name = try await store.replace(
                fileName, with: text, expected: expected, byteOrderMark: byteOrderMark, now: context.clock.now)
            await refreshIndex()
            await movePin(from: fileName, to: name)
            return .saved(name)
        } catch .disk(.changedElsewhere), .disk(.missing) {
            // Another app changed, renamed or deleted the note while the editor was open.
            return .savedAsCopy(try await create(text))
        } catch {
            await refreshIndex()
            throw error.actionFailure(folder: index.folder)
        }
    }

    /// Gives the note a new title, changing only its title line, and renames its file to follow.
    func rename(_ fileName: String, to title: String) async throws -> String {
        let note = try await readForChange(fileName)
        let text = await NoteWork.retitled(note.text, title: title)
        return try await replace(fileName, with: text, expected: note.version, byteOrderMark: note.byteOrderMark)
    }

    /// Adds text at the end of the note, before its tag line, and returns its file name. A change
    /// another app made in between is read and kept.
    func append(_ text: String, to fileName: String) async throws -> String {
        guard NoteText.isVisible(text[...]) else { throw Strings.nothingToAppend }
        for attempt in 0..<2 {
            let note = try await readForChange(fileName)
            do {
                return try await replace(
                    fileName, with: await NoteWork.appending(text, to: note.text), expected: note.version,
                    byteOrderMark: note.byteOrderMark)
            } catch let failure as ActionFailure where failure == Strings.changedElsewhere && attempt == 0 {
                continue
            }
        }
        throw Strings.changedElsewhere
    }

    /// Writes a copy of the note under a new name and returns it.
    func duplicate(_ fileName: String) async throws -> String {
        do throws(NoteFailure) {
            let name = try await store.duplicate(fileName, now: context.clock.now)
            await refreshIndex()
            return name
        } catch {
            await refreshIndex()
            throw error.actionFailure(folder: index.folder)
        }
    }

    /// Forgets a note that left through the Trash: its pin goes and the folder is read again.
    func didRemove(_ fileName: String) async {
        if pinned.contains(fileName) { try? await setPinned(false, fileName: fileName) }
        await rescan()
    }

    private func replace(_ fileName: String, with text: String, expected: FileVersion, byteOrderMark: Bool)
        async throws -> String
    {
        do throws(NoteFailure) {
            let name = try await store.replace(
                fileName, with: text, expected: expected, byteOrderMark: byteOrderMark, now: context.clock.now)
            await refreshIndex()
            await movePin(from: fileName, to: name)
            return name
        } catch {
            await refreshIndex()
            throw error.actionFailure(folder: index.folder)
        }
    }

    // MARK: Pins

    /// Pins or unpins a note in the current folder.
    func setPinned(_ isPinned: Bool, fileName: String) async throws {
        switch pinState {
        case .ready: break
        case .loading, .unreadable:
            throw ActionFailure(Strings.pinsUnreadableTitle, message: Strings.pinsUnreadableMessage)
        case .newerVersion: throw ActionFailure(Strings.pinsNewerTitle, message: Strings.pinsNewerMessage)
        }
        let key = index.folder.pinKey
        // Pins of notes that are gone go too, but only when the scan saw the whole folder.
        let sawEverything = index.problem == nil && index.stats.leftOut == 0 && !index.stats.entriesCut
        var names = (pinFile.folders[key] ?? []).filter {
            $0 != fileName && (!sawEverything || index.note(named: $0) != nil)
        }
        if isPinned { names.append(fileName) }
        var file = pinFile
        file.folders[key] = names.isEmpty ? nil : names
        do {
            try await pinStore.save(file)
        } catch {
            throw Strings.pinsFailed
        }
        pinFile = file
        refreshPinned()
        changes.send()
    }

    /// Keeps a pin when the app renames a pinned note.
    private func movePin(from fileName: String, to newName: String) async {
        guard fileName != newName, pinned.contains(fileName), pinState == .ready else { return }
        try? await setPinned(false, fileName: fileName)
        try? await setPinned(true, fileName: newName)
    }

    private func loadPins() async {
        do {
            let file = try await pinStore.load() ?? PinFile()
            pinFile = file
            pinState = file.version > PinFile.currentVersion ? .newerVersion : .ready
        } catch {
            context.log.error("Could not read the pins file: \(String(describing: error), privacy: .private)")
            pinState = .unreadable
        }
        refreshPinned()
        statusChanges.send()
    }

    private func refreshPinned() {
        pinned = Set(pinFile.folders[index.folder.pinKey] ?? [])
    }
}

/// The pins file: for each folder, the names of its pinned notes, in the order they were pinned.
nonisolated struct PinFile: Codable, Hashable, Sendable {
    static let currentVersion = 1
    var version = PinFile.currentVersion
    var folders: [String: [String]] = [:]
}
