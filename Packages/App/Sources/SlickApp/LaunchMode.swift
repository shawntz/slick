import Foundation
import Kit

/// What the process was asked to do, parsed from its command-line arguments.
nonisolated enum LaunchMode: Equatable, Sendable {
    /// No mode flag: the launcher itself.
    case launcher
    /// `--selftest`: start every feature without UI, query root search and exit.
    case selftest
    /// `--bench [name]`: latency tables measured inside the app bundle.
    case bench(name: String?)
    /// `--scenario <file>`: a scripted UI run with captures and assertions.
    case scenario(path: String)
    /// `--version`: print the name, the version and the build number, and exit before the app makes
    /// any window, menu bar item or hotkey. dyld has loaded every linked framework by then, so a
    /// bundle whose framework is missing or wrongly signed fails at once.
    case version

    /// The run environment of the mode. Only the launcher touches the real Mac. `--version` ends
    /// before any environment is built, and counts as a run outside the live launcher.
    var environment: RunEnvironment {
        switch self {
        case .launcher: .live
        case .selftest, .version: .selftest
        case .bench: .bench
        case .scenario: .scenario
        }
    }

    /// The first word of the verdict line the mode prints last, such as "selftest PASS".
    var verdictName: String? {
        switch self {
        case .launcher, .version: nil
        case .selftest: "selftest"
        case .bench: "bench"
        case .scenario: "scenario"
        }
    }

    /// The usage text printed when the arguments cannot be parsed.
    static let usage = """
        usage: <app> [--selftest | --bench [name] | --scenario <file> [--output <folder>] | --version] [--data-dir <folder>]
          (no flag)           run the launcher
          --selftest          start every feature without UI, query root search, print a verdict and exit
          --bench [name]      print latency tables, measured inside the app bundle
          --scenario <file>   run a scripted UI scenario
          --output <folder>   where a scenario writes result.json and its captures
          --version           print the name, the version and the build number, and exit
          --data-dir <folder> use this data folder instead of the default
        """
}

/// The mode plus the options that go with it.
nonisolated struct LaunchOptions: Equatable, Sendable {
    var mode: LaunchMode
    /// `--data-dir`, or the data folder variable, as given. Nil uses the default.
    var dataDirectory: String?
    /// `--output`, for a scenario.
    var output: String?

    /// The environment variable that overrides the data folder, such as `SLICK_DATA_DIR`.
    static var dataDirectoryVariable: String {
        let name = Brand.name.uppercased().unicodeScalars.map { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) ? Character(scalar) : "_"
        }
        return String(name) + "_DATA_DIR"
    }

    init(mode: LaunchMode, dataDirectory: String? = nil, output: String? = nil) {
        self.mode = mode
        self.dataDirectory = dataDirectory
        self.output = output
    }

    /// Parses the arguments that follow the executable path, and the process environment.
    ///
    /// A single-dash argument such as `-NSDocumentRevisionsDebugMode YES` is a user-default
    /// override that Xcode or AppKit may add. It is skipped together with the value after it.
    /// `--data-dir` wins over the environment variable.
    init(arguments: [String], environment: [String: String] = [:]) throws(UsageError) {
        var flags: [String] = []
        var dataDirectory: String?
        var output: String?
        var index = arguments.startIndex
        func value(after flag: String) throws(UsageError) -> String {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].isEmpty, !arguments[next].hasPrefix("-") else {
                throw UsageError("\(flag) needs a value")
            }
            index = arguments.index(after: next)
            return arguments[next]
        }
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument.hasPrefix("-") && !argument.hasPrefix("--") {
                let next = arguments.index(after: index)
                let hasValue = next < arguments.endIndex && !arguments[next].hasPrefix("-")
                index = hasValue ? arguments.index(after: next) : next
                continue
            }
            switch argument {
            case "--data-dir":
                guard dataDirectory == nil else { throw UsageError("--data-dir given twice") }
                dataDirectory = try value(after: argument)
            case "--output":
                guard output == nil else { throw UsageError("--output given twice") }
                output = try value(after: argument)
            default:
                flags.append(argument)
                index = arguments.index(after: index)
            }
        }
        let mode = try Self.mode(from: flags)
        if output != nil {
            guard case .scenario = mode else { throw UsageError("--output goes with --scenario") }
        }
        let variable = environment[Self.dataDirectoryVariable].flatMap { $0.isEmpty ? nil : $0 }
        self.init(mode: mode, dataDirectory: dataDirectory ?? variable, output: output)
    }

    private static func mode(from flags: [String]) throws(UsageError) -> LaunchMode {
        guard let first = flags.first else { return .launcher }
        let rest = flags.dropFirst()
        switch first {
        case "--selftest":
            guard rest.isEmpty else { throw UsageError("--selftest takes no arguments") }
            return .selftest
        case "--bench":
            guard rest.count <= 1 else { throw UsageError("--bench takes at most one name") }
            if let name = rest.first, name.hasPrefix("--") { throw UsageError("unknown argument \(name)") }
            return .bench(name: rest.first)
        case "--scenario":
            guard rest.count == 1, let path = rest.first, !path.hasPrefix("--") else {
                throw UsageError("--scenario needs exactly one file")
            }
            return .scenario(path: path)
        case "--version":
            guard rest.isEmpty else { throw UsageError("--version takes no arguments") }
            return .version
        default:
            throw UsageError("unknown argument \(first)")
        }
    }

    /// A path from the command line as an absolute file URL. A relative path is taken from
    /// `currentDirectory`; a leading tilde means the home folder.
    static func fileURL(_ path: String, currentDirectory: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(filePath: expanded).standardizedFileURL }
        return URL(filePath: currentDirectory).appending(path: expanded).standardizedFileURL
    }
}

/// Arguments the app could not make sense of.
nonisolated struct UsageError: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
