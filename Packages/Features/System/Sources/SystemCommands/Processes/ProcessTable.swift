import Foundation
import Kit

/// One process at one moment, with running totals. CPU use comes from comparing two samples.
nonisolated struct ProcessSample: Hashable, Sendable {
    var pid: Int32
    /// When the process started, in microseconds since 1970. With the PID it names one process,
    /// since macOS reuses PIDs.
    var startTime: UInt64
    /// The app's name for an app, else the executable's.
    var name: String
    /// The executable's path, when the system tells it.
    var path: String?
    /// For an app: its bundle ID, when it has one.
    var bundleID: String?
    /// For an app: the bundle's path.
    var bundlePath: String?
    /// True for an app, which quits through its own Quit command. Other processes get a signal.
    var isApplication: Bool
    /// True for an app with a Dock icon.
    var isRegularApp: Bool
    /// CPU time used since the process started, in nanoseconds.
    var cpuTime: UInt64
    /// Memory in use, in bytes, as Activity Monitor counts it.
    var memory: UInt64

    /// The name as the list shows it: on one line, and never empty.
    var displayName: String {
        let line = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Strings.Processes.unnamed(pid: pid) : trimmed
    }

    /// Who the process is, as actions need it.
    var identity: ProcessIdentity {
        ProcessIdentity(
            pid: pid, startTime: startTime, name: displayName, bundleID: bundleID, path: path,
            bundlePath: bundlePath, isApplication: isApplication)
    }
}

/// Every process of the user at one moment.
nonisolated struct ProcessSnapshot: Hashable, Sendable {
    /// When the sample was taken, in nanoseconds of uptime. Only differences matter.
    var uptime: UInt64
    /// This app's own PID, which the list never offers to quit.
    var ownPID: Int32
    var processes: [ProcessSample]
}

/// What an action needs to quit one process, and the row's payload.
nonisolated struct ProcessIdentity: Codable, Hashable, Sendable {
    var pid: Int32
    var startTime: UInt64
    var name: String
    var bundleID: String?
    var path: String?
    /// For an app: the bundle, which Show in Finder reveals instead of the executable inside it.
    var bundlePath: String? = nil
    var isApplication: Bool
}

/// The user's processes, and quitting them.
///
/// The live implementation reads real processes and can end them. Tests, scenarios, self-tests and
/// benchmarks get ``SimulatedProcessTable``.
nonisolated protocol ProcessTable: Sendable {
    /// The processes that belong to the user who is logged in, with CPU time and memory.
    @concurrent func snapshot() async throws -> ProcessSnapshot

    /// Asks the process to quit: Quit for an app, which may ask to save; a polite signal otherwise.
    /// Throws ``SystemFailure/notFound`` when the process has already quit, or when its PID now
    /// belongs to another process.
    @concurrent func quit(_ process: ProcessIdentity) async throws

    /// Ends the process at once. Unsaved work is lost.
    @concurrent func forceQuit(_ process: ProcessIdentity) async throws
}

/// The process table for each kind of run.
nonisolated enum ProcessTableKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ProcessTable {
        LiveProcessTable()
    }

    static func isolated(_ context: FeatureContext) -> any ProcessTable {
        SimulatedProcessTable.example()
    }
}
