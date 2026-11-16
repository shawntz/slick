import Darwin
import Foundation
import Kit

/// Open in Terminal, for a command that needs a terminal, such as one that asks for input.
///
/// The command is written to a script in the feature's cache folder that only the user can read and
/// run, and the workspace opens that file with Terminal, which runs it in a new window. The script's
/// first line names the shell from settings as a login shell. The second deletes the script, so the
/// command is on disk only until Terminal starts it; the shell has the file open by then and reads
/// on. The third goes to the working folder, and the fourth is the command as typed. A script
/// Terminal never started is deleted when the next one is written, once it is ten minutes old.
nonisolated enum TerminalScript {
    /// Terminal's bundle ID.
    static let terminalBundleID = "com.apple.Terminal"
    /// The folder in the cache folder that holds the scripts.
    static let folderName = "Terminal"
    /// How old a script must be before the next write deletes it.
    static let keptFor: TimeInterval = 600
    static let filePrefix = "run-"
    static let fileSuffix = ".command"

    /// Why the script cannot be written.
    enum Problem: Error, Hashable, Sendable {
        /// The shell's path cannot go on a script's first line: it is not absolute or holds white
        /// space or a control character.
        case shellPath
        /// The folder or the file could not be made.
        case write(String)
    }

    /// The text of the script at `script`. Its second line deletes the script itself through
    /// `/bin/rm`, so no alias or function of that name can change what it does, with a path every
    /// common shell reads the same way in single quotes.
    static func text(command: ShellCommand, shell: String, folder: URL, script: URL) throws(Problem) -> String {
        guard shell.hasPrefix("/"),
            !shell.unicodeScalars.contains(where: {
                $0.properties.isWhitespace || $0.properties.generalCategory == .control
            })
        else { throw .shellPath }
        let flags = RunSetup.loginFlags(for: shell).map { " " + $0 }.joined()
        return "#!\(shell)\(flags)\n/bin/rm -f -- \(quoted(script.path(percentEncoded: false)))\n"
            + "cd \(quoted(folder.path(percentEncoded: false))) || exit 1\n\(command.text)\n"
    }

    /// A new script's file in `folder`, under a name no other script has.
    static func newFile(in folder: URL) -> URL {
        folder.appending(path: filePrefix + UUID().uuidString.lowercased() + fileSuffix, directoryHint: .notDirectory)
    }

    /// A path in single quotes, with each single quote inside written as `'\''`, which every common
    /// shell reads as one quote.
    static func quoted(_ path: String) -> String {
        "'" + path.replacing("'", with: "'\\''") + "'"
    }

    /// Writes a script to `url`, a file ``newFile(in:)`` named. Its folder is made for the user
    /// alone, the file is made new, never through a link, and set so that only the user can read,
    /// write and run it. Older scripts are deleted after.
    @concurrent static func write(_ text: String, to url: URL) async throws(Problem) {
        let folder = url.deletingLastPathComponent()
        try makeFolder(folder)
        try writeFile(Array(text.utf8), to: url.path(percentEncoded: false))
        sweep(folder, keeping: url)
    }

    /// Writes a script into `folder` under a new name and returns its file.
    static func write(_ text: String, in folder: URL) async throws(Problem) -> URL {
        let url = newFile(in: folder)
        try await write(text, to: url)
        return url
    }

    /// Makes the folder if needed and sets it to 0700. A link in its place is refused. The path loses
    /// its trailing slash first: with one, `lstat` and `chmod` would follow a link.
    private static func makeFolder(_ folder: URL) throws(Problem) {
        let path = withoutTrailingSlash(folder.path(percentEncoded: false))
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .write(error.localizedDescription)
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw .write(Strings.Failures.terminalFolderNotAFolder)
        }
        guard chmod(path, 0o700) == 0 else { throw .write(String(cString: strerror(errno))) }
    }

    /// A path without the trailing slash a folder URL carries, except for the root folder.
    static func withoutTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Creates the file, refusing one that exists or a link, writes it, and sets it to 0700.
    private static func writeFile(_ bytes: [UInt8], to path: String) throws(Problem) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard descriptor >= 0 else { throw .write(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o700) == 0 else { throw .write(String(cString: strerror(errno))) }
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base + written, bytes.count - written)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw .write(String(cString: strerror(errno)))
            }
            guard result > 0 else { throw .write(String(cString: strerror(EIO))) }
            written += result
        }
    }

    /// Deletes this feature's scripts that are older than ``keptFor`` next to the new one. Ages are
    /// compared with the new file's own time, so the clock in settings plays no part. Links and
    /// other files are left alone.
    static func sweep(_ folder: URL, keeping kept: URL) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard
            let newest = try? kept.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            let files = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return }
        for file in files where file.lastPathComponent != kept.lastPathComponent {
            let name = file.lastPathComponent
            guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix),
                let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                values.isSymbolicLink != true, let modified = values.contentModificationDate,
                newest.timeIntervalSince(modified) > keptFor
            else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
