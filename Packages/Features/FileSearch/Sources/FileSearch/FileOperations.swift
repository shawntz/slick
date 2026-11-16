import Darwin
import Foundation
import Kit
import Synchronization

/// Every change the file actions make on disk: rename, duplicate, compress, move, copy and move to
/// the Trash. Each requirement blocks while it reads or writes, so each is `@concurrent`.
///
/// A name collision never replaces an item. Rename, Move To, and Copy To into another folder fail
/// with ``FileOperationError/nameTaken(_:)``. Duplicate, Compress, and Copy To into the item's own
/// folder pick the next free name, as Finder does. A symbolic link is renamed, moved, copied and
/// trashed as a link; nothing follows it to its target.
nonisolated protocol FileOperations: Sendable {
    /// Gives the item a new name in its folder and returns where it is now.
    @concurrent func rename(_ item: URL, to name: String) async throws -> URL

    /// Copies the item beside itself as "name copy", then "name copy 2", and returns the copy.
    @concurrent func duplicate(_ item: URL) async throws -> URL

    /// Makes a zip archive beside the item as "name.zip", then "name 2.zip", and returns it.
    @concurrent func compress(_ item: URL) async throws -> URL

    /// Moves the item into a folder and returns where it is now.
    @concurrent func move(_ item: URL, into folder: URL) async throws -> URL

    /// Copies the item into a folder and returns the copy. Into its own folder, the copy takes the
    /// next free name, as Duplicate does.
    @concurrent func copy(_ item: URL, into folder: URL) async throws -> URL

    /// Moves the item to the Trash and returns where it went.
    @concurrent func trash(_ item: URL) async throws -> URL

    /// True when another item in the item's folder already has `name`. A name that differs from the
    /// item's own only in case, on a volume that ignores case, is not taken.
    @concurrent func isTaken(_ name: String, besides item: URL) async -> Bool
}

/// Why a change to a file did not happen. The feature turns each into a sentence.
nonisolated enum FileOperationError: Error, Hashable, Sendable {
    /// The item is no longer where its row says.
    case missing
    /// The target folder already holds an item with this name.
    case nameTaken(String)
    /// The name breaks a rule, as ``FileNames/problem(with:)`` says.
    case invalidName(FileNames.Problem)
    /// The chosen destination is not a folder, or is gone.
    case notAFolder
    /// The item is in that folder already.
    case alreadyThere
    /// A folder cannot go into itself or into a folder inside it.
    case intoItself
    /// macOS refused: no permission, or a read-only volume.
    case notAllowed
    /// The volume is full.
    case noSpace
    /// The implementation for tests and scenarios changes nothing outside its own folder.
    case outsideTree
    /// Anything else, with the system's error number or the tool's exit status.
    case failed(Int32)
}

/// The operations each kind of run gets. The app changes the user's files. Scenarios, self-tests
/// and benchmarks change files only inside the run's synthetic home folder, which is inside the
/// run's temporary folder. Tests pass a ``TreeFileOperations`` over their own temporary tree.
nonisolated enum FileOperationsKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any FileOperations { LiveFileOperations() }

    static func isolated(_ context: FeatureContext) -> any FileOperations {
        TreeFileOperations(root: context.storage.homeDirectory.path(percentEncoded: false))
    }
}

/// The live operations, on the user's files. Never run in tests: tests run the same steps through
/// ``TreeFileOperations`` inside a temporary tree.
///
/// A move to another volume goes through `FileManager`, which copies, then removes the original,
/// and stops when the target exists. Move to Trash uses `FileManager.trashItem`, as Finder's Trash
/// does.
nonisolated struct LiveFileOperations: FileOperations {
    private let scope = FileScope.anywhere

    @concurrent func rename(_ item: URL, to name: String) async throws -> URL {
        try FileSteps.rename(item, to: name, scope: scope)
    }

    @concurrent func duplicate(_ item: URL) async throws -> URL {
        try FileSteps.duplicate(item, scope: scope)
    }

    @concurrent func compress(_ item: URL) async throws -> URL {
        try await FileSteps.compress(item, scope: scope)
    }

    @concurrent func move(_ item: URL, into folder: URL) async throws -> URL {
        try FileSteps.move(item, into: folder, scope: scope)
    }

    @concurrent func copy(_ item: URL, into folder: URL) async throws -> URL {
        try FileSteps.copy(item, into: folder, scope: scope)
    }

    @concurrent func trash(_ item: URL) async throws -> URL {
        let checked = try scope.item(item)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: checked.url, resultingItemURL: &resulting)
        } catch {
            throw FileSteps.mapped(error, name: checked.name)
        }
        return (resulting as URL?) ?? checked.url
    }

    @concurrent func isTaken(_ name: String, besides item: URL) async -> Bool {
        FileSteps.isTaken(name, besides: item, scope: scope)
    }
}

/// The operations for tests and scenarios: the same steps as the live ones, refused for any item
/// or folder that does not resolve inside `root`. The Trash is a `.Trash` folder in `root`.
///
/// A root that is "/" or holds the user's real home folder is refused outright, so a mistaken root
/// can never reach the user's files.
nonisolated struct TreeFileOperations: FileOperations {
    let root: String

    private var scope: FileScope { FileScope(tree: root) }

    @concurrent func rename(_ item: URL, to name: String) async throws -> URL {
        try FileSteps.rename(item, to: name, scope: scope)
    }

    @concurrent func duplicate(_ item: URL) async throws -> URL {
        try FileSteps.duplicate(item, scope: scope)
    }

    @concurrent func compress(_ item: URL) async throws -> URL {
        try await FileSteps.compress(item, scope: scope)
    }

    @concurrent func move(_ item: URL, into folder: URL) async throws -> URL {
        try FileSteps.move(item, into: folder, scope: scope)
    }

    @concurrent func copy(_ item: URL, into folder: URL) async throws -> URL {
        try FileSteps.copy(item, into: folder, scope: scope)
    }

    @concurrent func trash(_ item: URL) async throws -> URL {
        let checked = try scope.item(item)
        let realRoot = try scope.realTree()
        let trash = realRoot + "/.Trash"
        if mkdir(trash, 0o700) != 0, errno != EEXIST { throw FileSteps.posix(errno, name: checked.name) }
        let placed = try FileSteps.placeAtNextFreeName(checked, in: trash) { number in
            number == 1 ? checked.name : FileNames.numbered(checked.name, number)
        }
        return placed
    }

    @concurrent func isTaken(_ name: String, besides item: URL) async -> Bool {
        FileSteps.isTaken(name, besides: item, scope: scope)
    }
}

/// Where operations may act: anywhere, or only inside one folder.
nonisolated struct FileScope: Sendable {
    /// The folder everything must lie inside, or nil for anywhere.
    let tree: String?

    static let anywhere = FileScope(tree: nil)

    /// One item, checked to exist. Its folder is resolved; the item itself is not, so a symbolic
    /// link is acted on as a link.
    struct Item: Sendable {
        /// The real path of the item's folder, with the item's own name.
        var path: String
        var parent: String
        var name: String
        /// A real folder, not a link to one. Packages count.
        var isFolder: Bool
        var device: Int32
        var inode: UInt64

        var url: URL { URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory) }
    }

    /// The tree's real path. Throws when there is no tree, or when it is "/" or holds the user's
    /// real home folder. The home folder is compared as text first, so the check never touches it.
    func realTree() throws -> String {
        let home = Paths.normalized(NSHomeDirectory(), home: nil) ?? "/"
        guard let tree, let given = Paths.normalized(tree, home: nil), given != "/", !Paths.isInside(home, given),
            let real = FileSteps.realPath(given), real != "/", !Paths.isInside(home, real)
        else { throw FileOperationError.outsideTree }
        return real
    }

    /// True when a path, as given, lies in the tree under its own spelling or its real one. Checked
    /// before anything is resolved, so nothing outside the tree is even looked at.
    private func mayLookAt(_ path: String) throws -> Bool {
        guard let tree else { return true }
        let real = try realTree()
        return Paths.isInside(path, real) || Paths.normalized(tree, home: nil).map { Paths.isInside(path, $0) } == true
    }

    func item(_ url: URL) throws -> Item {
        guard let path = Paths.normalized(url.path(percentEncoded: false), home: nil), path != "/" else {
            throw FileOperationError.missing
        }
        guard try mayLookAt(path) else { throw FileOperationError.outsideTree }
        let name = Paths.name(of: path)
        guard let parent = FileSteps.realPath(Paths.parent(of: path)) else { throw FileOperationError.missing }
        let real = parent == "/" ? "/" + name : parent + "/" + name
        if tree != nil {
            // Checked again once resolved, so a link inside the tree cannot lead out of it.
            let root = try realTree()
            guard Paths.isInside(parent, root), real != root else { throw FileOperationError.outsideTree }
        }
        var info = stat()
        guard lstat(real, &info) == 0 else { throw FileSteps.posix(errno, name: name) }
        return Item(
            path: real, parent: parent, name: name, isFolder: info.st_mode & S_IFMT == S_IFDIR, device: info.st_dev,
            inode: info.st_ino)
    }

    /// A destination folder's real path. A link to a folder counts as that folder.
    func folder(_ url: URL) throws -> String {
        guard let path = Paths.normalized(url.path(percentEncoded: false), home: nil) else {
            throw FileOperationError.notAFolder
        }
        guard try mayLookAt(path) else { throw FileOperationError.outsideTree }
        guard let real = FileSteps.realPath(path) else { throw FileOperationError.notAFolder }
        if tree != nil {
            guard Paths.isInside(real, try realTree()) else { throw FileOperationError.outsideTree }
        }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw FileOperationError.notAFolder }
        return real
    }
}

/// The steps both implementations share, in POSIX and Foundation calls.
nonisolated enum FileSteps {
    static func rename(_ url: URL, to typed: String, scope: FileScope) throws -> URL {
        if let problem = FileNames.problem(with: typed) { throw FileOperationError.invalidName(problem) }
        let item = try scope.item(url)
        guard typed != item.name else { return item.url }
        let target = join(item.parent, typed)
        try placeExclusively(item, at: target)
        return URL(filePath: target, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
    }

    static func duplicate(_ url: URL, scope: FileScope) throws -> URL {
        let item = try scope.item(url)
        return try copyToNextFreeName(item, in: item.parent)
    }

    static func move(_ url: URL, into folderURL: URL, scope: FileScope) throws -> URL {
        let item = try scope.item(url)
        let folder = try scope.folder(folderURL)
        if isSame(folder, item.parent) { throw FileOperationError.alreadyThere }
        if item.isFolder, isSameOrInside(folder, item) { throw FileOperationError.intoItself }
        let target = join(folder, item.name)
        do {
            try placeExclusively(item, at: target)
        } catch FileOperationError.failed(EXDEV) {
            // Another volume. A tree never spans two, and only the live operations get here.
            guard scope.tree == nil else { throw FileOperationError.outsideTree }
            do {
                try FileManager.default.moveItem(atPath: item.path, toPath: target)
            } catch {
                throw mapped(error, name: item.name)
            }
        }
        return URL(filePath: target, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
    }

    static func copy(_ url: URL, into folderURL: URL, scope: FileScope) throws -> URL {
        let item = try scope.item(url)
        let folder = try scope.folder(folderURL)
        if item.isFolder, isSameOrInside(folder, item) { throw FileOperationError.intoItself }
        if isSame(folder, item.parent) { return try copyToNextFreeName(item, in: item.parent) }
        let target = join(folder, item.name)
        guard !exists(target) else { throw FileOperationError.nameTaken(item.name) }
        try copyItem(item, to: target)
        return URL(filePath: target, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
    }

    /// Zips the item with `ditto`, as Archive Utility does. The archive's name is taken first with
    /// an empty file that only this call can create, so nothing else can claim it while `ditto`
    /// writes. A failed or cancelled run removes that file.
    static func compress(_ url: URL, scope: FileScope) async throws -> URL {
        let item = try scope.item(url)
        let target = try reserveFile(in: item.parent) { FileNames.archiveName(of: item.name, number: $0) }
        do {
            // A folder keeps its own name inside the archive; a file sits at the archive's top.
            let arguments =
                ["-c", "-k", "--sequesterRsrc"] + (item.isFolder ? ["--keepParent"] : []) + [item.path, target]
            let status = try await Ditto.run(arguments)
            guard status == 0 else { throw FileOperationError.failed(status) }
        } catch {
            unlink(target)
            if error is CancellationError { throw error }
            throw mapped(error, name: item.name)
        }
        return URL(filePath: target, directoryHint: .notDirectory)
    }

    static func isTaken(_ name: String, besides url: URL, scope: FileScope) -> Bool {
        guard FileNames.problem(with: name) == nil, let item = try? scope.item(url) else { return false }
        var info = stat()
        guard lstat(join(item.parent, name), &info) == 0 else { return false }
        return !(info.st_dev == item.device && info.st_ino == item.inode)
    }

    // MARK: - Placing

    /// Renames or moves the item to `target` on the same volume, never over an existing item. A
    /// change of case alone, on a volume that ignores case, finds the item itself at `target` and
    /// goes ahead. A volume that cannot refuse by itself, as some network volumes cannot, is
    /// checked first.
    static func placeExclusively(_ item: FileScope.Item, at target: String) throws {
        if renamex_np(item.path, target, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        switch code {
        case EEXIST:
            var info = stat()
            guard lstat(target, &info) == 0, info.st_dev == item.device, info.st_ino == item.inode else {
                throw FileOperationError.nameTaken(Paths.name(of: target))
            }
            guard Darwin.rename(item.path, target) == 0 else { throw posix(errno, name: item.name) }
        case ENOTSUP:
            guard !exists(target) else { throw FileOperationError.nameTaken(Paths.name(of: target)) }
            guard Darwin.rename(item.path, target) == 0 else { throw posix(errno, name: item.name) }
        case EXDEV:
            throw FileOperationError.failed(EXDEV)
        default:
            throw posix(code, name: item.name)
        }
    }

    /// Moves the item into `folder` under the first free name `name(n)` gives, from n = 1.
    static func placeAtNextFreeName(
        _ item: FileScope.Item, in folder: String, name: (Int) -> String
    ) throws -> URL {
        for number in 1...maximumTries {
            let target = join(folder, name(number))
            guard !exists(target) else { continue }
            do {
                try placeExclusively(item, at: target)
                return URL(filePath: target, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
            } catch FileOperationError.nameTaken {
                continue
            }
        }
        throw FileOperationError.nameTaken(name(maximumTries))
    }

    /// Copies the item into `folder` under the first free copy name.
    static func copyToNextFreeName(_ item: FileScope.Item, in folder: String) throws -> URL {
        for number in 1...maximumTries {
            let name = FileNames.copyName(of: item.name, number: number)
            guard FileNames.fits(name) else { throw FileOperationError.invalidName(.tooLong) }
            let target = join(folder, name)
            guard !exists(target) else { continue }
            do {
                try copyItem(item, to: target)
                return URL(filePath: target, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
            } catch FileOperationError.nameTaken {
                continue
            }
        }
        throw FileOperationError.nameTaken(FileNames.copyName(of: item.name, number: maximumTries))
    }

    /// Creates an empty file under the first free name `name(n)` gives, from n = 1, that no other
    /// call can create at the same time.
    static func reserveFile(in folder: String, name: (Int) -> String) throws -> String {
        for number in 1...maximumTries {
            let candidate = name(number)
            guard FileNames.fits(candidate) else { throw FileOperationError.invalidName(.tooLong) }
            let target = join(folder, candidate)
            let descriptor = open(target, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if descriptor >= 0 {
                close(descriptor)
                return target
            }
            if errno == EEXIST { continue }
            throw posix(errno, name: candidate)
        }
        throw FileOperationError.nameTaken(name(maximumTries))
    }

    /// Copies with `FileManager`, which copies a link as a link, keeps metadata, clones on APFS and
    /// stops when the target exists.
    static func copyItem(_ item: FileScope.Item, to target: String) throws {
        do {
            try FileManager.default.copyItem(atPath: item.path, toPath: target)
        } catch {
            throw mapped(error, name: Paths.name(of: target))
        }
    }

    /// How many names Duplicate, Compress and the Trash try before they give up.
    static let maximumTries = 10_000

    // MARK: - Paths

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    /// The path with every link resolved, or nil when a part is missing.
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when both paths name the same folder, whatever the spelling.
    static func isSame(_ first: String, _ second: String) -> Bool {
        var a = stat()
        var b = stat()
        guard stat(first, &a) == 0, stat(second, &b) == 0 else { return first == second }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// True when `folder` is the item or lies inside it, found by walking up from `folder` and
    /// comparing each folder's device and inode with the item's.
    static func isSameOrInside(_ folder: String, _ item: FileScope.Item) -> Bool {
        var current = folder
        var info = stat()
        while true {
            if stat(current, &info) == 0, info.st_dev == item.device, info.st_ino == item.inode { return true }
            let parent = Paths.parent(of: current)
            if parent == current { return false }
            current = parent
        }
    }

    // MARK: - Errors

    static func posix(_ code: Int32, name: String) -> FileOperationError {
        switch code {
        case ENOENT: .missing
        case EEXIST, ENOTEMPTY: .nameTaken(name)
        case EACCES, EPERM, EROFS: .notAllowed
        case ENOSPC, EDQUOT: .noSpace
        case ENAMETOOLONG: .invalidName(.tooLong)
        default: .failed(code)
        }
    }

    static func mapped(_ error: any Error, name: String) -> FileOperationError {
        if let error = error as? FileOperationError { return error }
        if let error = error as? POSIXError { return posix(error.code.rawValue, name: name) }
        if let error = error as? CocoaError {
            switch error.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missing
            case .fileWriteFileExists: return .nameTaken(name)
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly: return .notAllowed
            case .fileWriteOutOfSpace: return .noSpace
            case .fileWriteInvalidFileName: return .invalidName(.slash)
            default: break
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                underlying.domain == NSPOSIXErrorDomain
            {
                return posix(Int32(underlying.code), name: name)
            }
            return .failed(Int32(error.code.rawValue))
        }
        return .failed(0)
    }
}

/// Runs `/usr/bin/ditto` and waits for it without holding a thread. Cancelling the calling task
/// stops it.
nonisolated enum Ditto {
    static func run(_ arguments: [String]) async throws -> Int32 {
        let run = Run(arguments)
        let status = try await withTaskCancellationHandler {
            try await run.start()
        } onCancel: {
            run.stop()
        }
        if run.wasStopped { throw CancellationError() }
        return status
    }

    /// One run. The process is touched only under the lock, so a stop that comes before the start
    /// waits for it, and one that comes after the exit does nothing.
    private final class Run: @unchecked Sendable {
        private struct State {
            var started = false
            var stopped = false
        }

        private let process = Process()
        private let state = Mutex(State())

        init(_ arguments: [String]) {
            process.executableURL = URL(filePath: "/usr/bin/ditto")
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        var wasStopped: Bool { state.withLock(\.stopped) }

        func start() async throws -> Int32 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                let failure = state.withLock { state -> (any Error)? in
                    if state.stopped { return CancellationError() }
                    do {
                        try process.run()
                        state.started = true
                        return nil
                    } catch {
                        return error
                    }
                }
                if let failure {
                    process.terminationHandler = nil
                    continuation.resume(throwing: failure)
                }
            }
        }

        func stop() {
            state.withLock { state in
                state.stopped = true
                if state.started, process.isRunning { process.terminate() }
            }
        }
    }
}

/// The rules for a name the user types, and the names Finder gives to copies and archives.
nonisolated enum FileNames {
    /// Why a name cannot be used.
    enum Problem: Hashable, Sendable {
        case empty
        case dots
        case slash
        case colon
        case control
        case leadingDot
        case tooLong
    }

    /// The first rule `name` breaks, or nil when it can be used. Finder shows a colon as a slash,
    /// and a name that starts with a dot hides the item, so both are refused here too.
    static func problem(with name: String) -> Problem? {
        if name.isEmpty { return .empty }
        if name == "." || name == ".." { return .dots }
        if name.contains("/") { return .slash }
        if name.contains(":") { return .colon }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return .control }
        if name.hasPrefix(".") { return .leadingDot }
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }

    /// True when a name made from another, such as a copy's, is short enough to store. Such a name
    /// keeps whatever its original allows, such as a leading dot.
    static func fits(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255
    }

    /// The name as typed, without spaces or line breaks at either end.
    static func cleaned(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name before its extension, and the extension. An extension is up to 10 characters after
    /// the last dot, with no space, and a name that starts with its only dot has none.
    static func split(_ name: String) -> (base: String, extension: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let suffix = name[name.index(after: dot)...]
        guard !suffix.isEmpty, suffix.count <= 10, !suffix.contains(" ") else { return (name, nil) }
        return (String(name[..<dot]), String(suffix))
    }

    /// Finder's name for a copy: "name copy.ext", then "name copy 2.ext". A name that already ends
    /// in "copy" or "copy 2" counts from its stem, so a copy of "notes copy.txt" is
    /// "notes copy 2.txt".
    static func copyName(of name: String, number: Int) -> String {
        let (base, suffix) = split(name)
        let stem = stem(of: base)
        let copy = number <= 1 ? stem + " copy" : stem + " copy \(number)"
        return suffix.map { copy + "." + $0 } ?? copy
    }

    /// Archive Utility's name for an archive: "name.zip", then "name 2.zip".
    static func archiveName(of name: String, number: Int) -> String {
        number <= 1 ? name + ".zip" : name + " \(number).zip"
    }

    /// A name with a number before its extension, as the Trash names a second item: "name 2.ext".
    static func numbered(_ name: String, _ number: Int) -> String {
        let (base, suffix) = split(name)
        return suffix.map { base + " \(number)." + $0 } ?? base + " \(number)"
    }

    private static func stem(of base: String) -> String {
        if base.hasSuffix(" copy") { return String(base.dropLast(" copy".count)) }
        guard let space = base.lastIndex(of: " ") else { return base }
        let number = base[base.index(after: space)...]
        let before = base[..<space]
        guard !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber), before.hasSuffix(" copy")
        else { return base }
        return String(before.dropLast(" copy".count))
    }
}
