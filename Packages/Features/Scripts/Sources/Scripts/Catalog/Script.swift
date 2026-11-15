import Foundation
import Kit

/// A script that can run: its file, its header and its interpreter.
nonisolated struct Script: Hashable, Sendable {
    var url: URL
    var folder: URL
    var commandID: String
    var metadata: ScriptMetadata
    var interpreter: Interpreter

    var title: String { metadata.title }
    var mode: ScriptMode { metadata.effectiveMode }

    /// The package name, or the folder's name as the format says.
    var subtitle: String {
        metadata.packageName ?? folder.lastPathComponent
    }

    /// The header's icon, a dark variant when it has one, or a symbol for the mode. An icon given as
    /// a web address counts only when `allowsRemote`; see ``ScriptsSettings/remoteIcons``.
    func icon(home: URL, allowsRemote: Bool) -> Icon {
        let fallback: Icon =
            switch mode {
            case .list: .symbol("list.bullet.rectangle")
            case .inline: .symbol("text.line.first.and.arrowtriangle.forward")
            default: .symbol("terminal")
            }
        let light = ScriptIcon.icon(metadata.icon, folder: folder, home: home, allowsRemote: allowsRemote) ?? fallback
        guard let dark = ScriptIcon.icon(metadata.iconDark, folder: folder, home: home, allowsRemote: allowsRemote)
        else { return light }
        return .adaptive(light: light, dark: dark)
    }

    /// The name of the command argument for the declaration at `index`, counting from 0.
    static func argumentName(_ index: Int) -> String {
        "argument\(index + 1)"
    }

    /// The inline fields in the search bar.
    var commandArguments: [CommandArgument] {
        metadata.arguments.enumerated().map { index, argument in
            let kind: CommandArgument.Kind =
                switch argument.kind {
                case .text: .text
                case .password: .password
                case .dropdown(let choices):
                    .dropdown(choices.map { CommandArgument.Option($0.title, value: $0.value) })
                }
            return CommandArgument(
                Self.argumentName(index), placeholder: argument.placeholder, kind: kind,
                isOptional: argument.isOptional)
        }
    }

    /// True for an inline script with a refresh time that does not ask before it runs. Only these
    /// may run by themselves, and only after the user turns that on.
    var canRefreshByItself: Bool {
        mode == .inline && metadata.refreshTime != nil && !metadata.needsConfirmation
    }

    /// True when the script can take root search's typed text as a fallback: a list script, or a
    /// script whose first argument is text and whose others are optional.
    var acceptsTypedText: Bool {
        if mode == .list { return true }
        guard let first = metadata.arguments.first, first.kind == .text else { return false }
        return metadata.arguments.dropFirst().allSatisfy(\.isOptional)
    }

    /// `$1` to `$3` from what the user entered. A skipped argument before a filled one is passed as
    /// empty text, so later ones keep their place; skipped arguments at the end are left out.
    func processArguments(from values: CommandArguments) -> [String] {
        var result = metadata.arguments.enumerated().map { index, argument in
            let value = values[Self.argumentName(index)] ?? ""
            return argument.isPercentEncoded ? Self.percentEncode(value) : value
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    /// How the script runs: through its interpreter, in its folder or its current directory, with
    /// the clean environment Kit gives every process plus the PATH from settings and any variables a
    /// list script returned.
    ///
    /// A process argument or environment value cannot hold a zero character, so typed text loses
    /// any it has and a variable that has one is left out.
    func request(arguments: [String], variables: [String: String] = [:], settings: RunSettings) -> ProcessRequest {
        var environment = variables.filter { !$0.value.contains("\0") }
        environment["PATH"] = settings.searchPath
        let arguments = arguments.map { $0.contains("\0") ? $0.replacingOccurrences(of: "\0", with: "") : $0 }
        let directory = metadata.currentDirectoryPath.map {
            ScriptPath.resolve($0, folder: folder, home: settings.home)
        }
        return ProcessRequest(
            executable: interpreter.executable,
            arguments: interpreter.arguments + [url.path(percentEncoded: false)] + arguments,
            environment: environment,
            currentDirectory: directory ?? folder,
            timeout: settings.timeout)
    }

    /// Encodes everything but letters, digits and `-._~`, as a URL query value needs.
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The settings that shape one run, read when it starts.
nonisolated struct RunSettings: Hashable, Sendable {
    var timeout: Duration?
    var timeoutName: String
    var outputLimit: Int
    var outputLimitName: String
    var searchPath: String
    /// The home folder for `~/` in paths.
    var home: URL

    static func read(_ settings: FeatureSettings, home: URL) -> RunSettings {
        let timeout = settings[ScriptsSettings.timeout]
        let limit = settings[ScriptsSettings.outputLimit]
        let path = settings[ScriptsSettings.searchPath].trimmed
        return RunSettings(
            timeout: timeout.duration, timeoutName: Strings.timeoutName(timeout), outputLimit: limit.bytes,
            outputLimitName: Strings.outputLimitName(limit),
            searchPath: path.isEmpty ? ScriptsSettings.defaultSearchPath : path, home: home)
    }
}
