import Foundation

/// What a script declares in the comments at its top.
///
/// The format is the one the public script command collections use, documented at
/// https://github.com/raycast/script-commands in README.md, documentation/ARGUMENTS.md and
/// documentation/OUTPUTMODES.md. Keys carry the `@raycast.` prefix there; this feature reads the
/// same keys under its own prefix too, `@` plus ``Kit/Brand/urlScheme`` plus `.`. The `list` mode
/// and the `filterAction` key are this feature's own.
nonisolated struct ScriptMetadata: Hashable, Sendable {
    var schemaVersion: Int
    var title: String
    /// The mode as written. ``effectiveMode`` is the one the script runs in.
    var mode: ScriptMode
    /// Shown as the command's subtitle. Nil uses the folder's name.
    var packageName: String?
    /// An emoji, a path relative to the script's folder or absolute, or an `https` URL.
    var icon: String?
    var iconDark: String?
    /// The working directory: relative to the script's folder, absolute, or starting with `~/`.
    var currentDirectoryPath: String?
    var needsConfirmation = false
    /// How often an inline script refreshes, at least ten seconds.
    var refreshTime: Duration?
    /// Up to three, passed as `$1` to `$3`.
    var arguments: [ScriptArgument] = []
    var description: String?
    var author: String?
    /// What Return does with a list row's argument.
    var filterAction = FilterAction.auto

    /// The mode the script runs in. An inline script without a refresh time runs as compact, as
    /// the format's documentation says.
    var effectiveMode: ScriptMode {
        mode == .inline && refreshTime == nil ? .compact : mode
    }
}

/// How a script's output reaches the user.
nonisolated enum ScriptMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// The whole output, streamed into a page as it arrives, with ANSI colors.
    case fullOutput
    /// The last line of output in a toast.
    case compact
    /// The panel closes at once, and the last line shows as a HUD when the script ends.
    case silent
    /// The first line of output is the command's subtitle, refreshed on the refresh time.
    case inline
    /// The script prints Script Filter JSON for each query, and the rows show in a list.
    case list
}

/// What Return does with the argument of a row a list script printed.
nonisolated enum FilterAction: String, Hashable, Sendable, Codable, CaseIterable {
    /// Opens a URL or a path, and copies anything else.
    case auto
    case open
    case copy
    /// Pastes into the frontmost app. Needs Accessibility.
    case paste
}

/// One `argumentN` declaration.
nonisolated struct ScriptArgument: Hashable, Sendable, Codable {
    nonisolated enum Kind: Hashable, Sendable, Codable {
        case text
        case password
        case dropdown([Choice])
    }

    nonisolated struct Choice: Hashable, Sendable, Codable {
        var title: String
        var value: String
    }

    var kind: Kind
    var placeholder: String
    var isOptional: Bool
    /// The value is percent-encoded before it reaches the script.
    var isPercentEncoded: Bool
}

/// Something wrong with a script, shown to the user in Manage Script Commands and in settings.
nonisolated struct ScriptProblem: Error, Hashable, Sendable, Codable {
    nonisolated enum Severity: String, Hashable, Sendable, Codable {
        /// The script cannot become a command until it is fixed.
        case error
        /// The script works, but part of its header was ignored or changed.
        case warning
    }

    var severity: Severity
    /// The line in the file, counting from 1, when the problem has one.
    var line: Int?
    var message: String

    static func error(_ message: String, line: Int? = nil) -> ScriptProblem {
        ScriptProblem(severity: .error, line: line, message: message)
    }

    static func warning(_ message: String, line: Int? = nil) -> ScriptProblem {
        ScriptProblem(severity: .warning, line: line, message: message)
    }
}
