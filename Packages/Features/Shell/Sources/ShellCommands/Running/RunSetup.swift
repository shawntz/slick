import Foundation
import Kit

/// Where and how a command runs, read from settings when it starts.
nonisolated struct RunSetup: Hashable, Sendable {
    /// The shell's absolute path.
    var shell: String
    /// The folder the command starts in.
    var folder: URL
    /// The home folder, for showing paths under it as "~".
    var home: URL
    var outputLimit: OutputLimit
    /// What the command gets on top of Kit's clean environment; see ``ShellEnvironment``.
    var environment: [String: String] = [:]

    /// The shell's name, such as "zsh".
    var shellName: String {
        DisplayText.oneLine(URL(filePath: shell).lastPathComponent)
    }

    /// The working folder for a page, with the home folder as "~".
    var folderForDisplay: String {
        Self.forDisplay(folder, home: home)
    }

    /// How the shell is started: as a login shell, so it reads the user's profile and sets the user's
    /// own `PATH`, with the command as the one argument after `-c`. The environment is Kit's clean
    /// one with ``environment`` on top. Standard input is not given, so it reads from `/dev/null`.
    /// No time limit: the command runs until it ends or the user stops it, which stops its whole
    /// process group.
    func request(for command: ShellCommand) -> ProcessRequest {
        ProcessRequest(
            executable: URL(filePath: shell), arguments: Self.loginFlags(for: shell) + ["-c", command.text],
            environment: environment,
            currentDirectory: folder, standardInput: nil, timeout: nil)
    }

    /// The flag that makes the shell a login shell: `-l`, except for csh and tcsh, which take `-l`
    /// only as their one flag. They read `.cshrc` or `.tcshrc` for every run, which is where their
    /// users set `PATH`, so they run without it.
    static func loginFlags(for shell: String) -> [String] {
        ["csh", "tcsh"].contains(URL(filePath: shell).lastPathComponent) ? [] : ["-l"]
    }

    // MARK: Reading settings

    /// The setup the settings ask for now. Throws an ``ActionFailure`` that says what to change when
    /// the shell or the folder is not there.
    static func resolve(settings: FeatureSettings, home: URL, system: any ShellSystem) async throws -> RunSetup {
        let choice = settings[ShellSettings.shell]
        let shell: String
        if let path = choice.path {
            guard await system.isProgram(path) else {
                throw ActionFailure(
                    Strings.Failures.shellNotFound, message: Strings.Failures.shellNotFoundMessage(path))
            }
            shell = path
        } else {
            shell = await system.loginShell() ?? ShellChoice.fallbackPath
        }
        let folder: URL
        switch Self.folder(from: settings[ShellSettings.workingFolder], home: home) {
        case .success(let url):
            folder = url
        case .failure:
            throw ActionFailure(Strings.Failures.folderNotUsable, message: Strings.Failures.folderNotUsableMessage)
        }
        guard await system.isFolder(folder.path(percentEncoded: false)) else {
            throw ActionFailure(
                Strings.Failures.folderNotFound,
                message: Strings.Failures.folderNotFoundMessage(forDisplay(folder, home: home)))
        }
        return RunSetup(
            shell: shell, folder: folder, home: home, outputLimit: settings[ShellSettings.outputLimit],
            environment: await system.environment())
    }

    /// Why a working folder setting cannot be used.
    enum FolderProblem: Error, Hashable, Sendable {
        /// It does not start with "/" or "~", or names another user's home, such as "~guest".
        case notAbsolute
        /// It holds a line break or another control character.
        case controlCharacter
    }

    /// The folder a setting names. Empty or "~" is the home folder, "~/x" is inside it, and an
    /// absolute path is itself. White space at either end is ignored.
    static func folder(from setting: String, home: URL) -> Result<URL, FolderProblem> {
        let path = setting.trimmingCharacters(in: .whitespaces)
        if path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.controlCharacter)
        }
        if path.isEmpty || path == "~" { return .success(home) }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return .success(rest.isEmpty ? home : home.appending(path: rest, directoryHint: .isDirectory))
        }
        guard path.hasPrefix("/") else { return .failure(.notAbsolute) }
        return .success(URL(filePath: path, directoryHint: .isDirectory))
    }

    /// What the setting stores for a folder the user chose: "~/x" inside the home folder, else the
    /// path.
    static func settingValue(for folder: URL, home: URL) -> String {
        let path = Self.path(folder)
        let homePath = Self.path(home)
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~/" + path.dropFirst(homePath.count + 1) }
        return path
    }

    /// A folder for a title or a message, with the home folder as "~", on one line.
    static func forDisplay(_ folder: URL, home: URL) -> String {
        DisplayText.oneLine(settingValue(for: folder, home: home))
    }

    /// A folder's path without a trailing slash, except for the root folder.
    private static func path(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
