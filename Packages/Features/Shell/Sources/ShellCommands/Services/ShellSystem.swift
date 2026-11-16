import Darwin
import Foundation
import Kit

/// What the feature reads from the Mac before a command runs: the account's login shell, the
/// variables a command gets, and whether the shell and the working folder are there.
///
/// Each call runs off the main thread and only after the user ran a command. None of them prompts.
nonisolated protocol ShellSystem: Sendable {
    /// The account's login shell as an absolute path, or nil when it cannot be read, is not listed
    /// in `/etc/shells`, or cannot run.
    @concurrent func loginShell() async -> String?

    /// True when a folder is at the path.
    @concurrent func isFolder(_ path: String) async -> Bool

    /// True when a program that may run is at the path.
    @concurrent func isProgram(_ path: String) async -> Bool

    /// What a command gets on top of Kit's clean environment; see ``ShellEnvironment``.
    @concurrent func environment() async -> [String: String]
}

/// The variables a command gets on top of Kit's clean environment, which holds `PATH`, `HOME`,
/// `LANG` and `TMPDIR`. Nothing else is added, so a variable that loads code or chooses where to
/// connect never reaches a command from the app.
///
/// - `USER`, `LOGNAME` and `SHELL` come from the account record, as `login` sets them.
/// - `SSH_AUTH_SOCK` comes from the app's own environment when it is set there, so `git` over SSH
///   reaches the user's agent.
/// - `TERM` stays unset: the output is a pipe, not a terminal.
nonisolated enum ShellEnvironment {
    /// The only names a command gets on top of the clean environment.
    static let names: Set<String> = ["USER", "LOGNAME", "SHELL", "SSH_AUTH_SOCK"]

    /// The entries for an account and the app's own environment. A value that is empty, or holds
    /// a control character, is left out. `SHELL` must be an absolute path.
    static func entries(accountName: String?, accountShell: String?, appEnvironment: [String: String])
        -> [String: String]
    {
        var entries: [String: String] = [:]
        if let name = accountName, isUsable(name) {
            entries["USER"] = name
            entries["LOGNAME"] = name
        }
        if let shell = accountShell, shell.hasPrefix("/"), isUsable(shell) {
            entries["SHELL"] = shell
        }
        if let socket = appEnvironment["SSH_AUTH_SOCK"], isUsable(socket) {
            entries["SSH_AUTH_SOCK"] = socket
        }
        return entries
    }

    private static func isUsable(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

/// The shell lookups for each kind of run.
nonisolated enum ShellSystemKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ShellSystem {
        LiveShellSystem()
    }

    static func isolated(_ context: FeatureContext) -> any ShellSystem {
        SimulatedShellSystem()
    }
}

/// The Mac's own answers, from the account database, `/etc/shells`, the file system and the app's
/// own environment.
///
/// Live code: it runs only in the launcher a person uses, never in tests or scenarios.
nonisolated final class LiveShellSystem: ShellSystem {
    @concurrent func loginShell() async -> String? {
        guard let path = Self.accountRecord()?.shell, path.hasPrefix("/"), Self.listedShells().contains(path),
            Self.isRunnable(path)
        else { return nil }
        return path
    }

    @concurrent func environment() async -> [String: String] {
        let record = Self.accountRecord()
        return ShellEnvironment.entries(
            accountName: record?.name, accountShell: record?.shell,
            appEnvironment: ProcessInfo.processInfo.environment)
    }

    @concurrent func isFolder(_ path: String) async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    @concurrent func isProgram(_ path: String) async -> Bool {
        Self.isRunnable(path)
    }

    /// A regular file the user may run.
    private static func isRunnable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// The name and the login shell the account database holds for this user, through
    /// `getpwuid_r`. The record's strings live in the buffer, so they are copied out before the
    /// buffer goes away. A buffer that is too small is doubled, up to 1 MB. An empty string reads
    /// as nil.
    private static func accountRecord() -> (name: String?, shell: String?)? {
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var size = suggested > 0 ? Int(suggested) : 4096
        while size <= 1 << 20 {
            var buffer = [CChar](repeating: 0, count: size)
            var record = passwd()
            var found: UnsafeMutablePointer<passwd>?
            var read: (name: String?, shell: String?)?
            let status = buffer.withUnsafeMutableBufferPointer { storage -> Int32 in
                guard let base = storage.baseAddress else { return ERANGE }
                let status = getpwuid_r(getuid(), &record, base, storage.count, &found)
                if status == 0, found != nil {
                    read = (
                        record.pw_name.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                        record.pw_shell.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
                    )
                }
                return status
            }
            if status == ERANGE {
                size *= 2
                continue
            }
            return read
        }
        return nil
    }

    /// The shells `/etc/shells` lists, one absolute path per line, without comments.
    private static func listedShells() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else { return [] }
        var shells = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("/") { shells.insert(entry) }
        }
        return shells
    }
}

/// Answers for scenarios, self-tests and benchmarks. It reads nothing: the login shell is zsh,
/// every folder and program is there, and a command gets nothing on top of the clean environment.
nonisolated final class SimulatedShellSystem: ShellSystem {
    @concurrent func loginShell() async -> String? {
        ShellChoice.fallbackPath
    }

    @concurrent func isFolder(_ path: String) async -> Bool {
        true
    }

    @concurrent func isProgram(_ path: String) async -> Bool {
        true
    }

    @concurrent func environment() async -> [String: String] {
        [:]
    }
}
