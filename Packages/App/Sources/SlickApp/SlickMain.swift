import AppKit
import Foundation
import Kit

/// The process entry point, shared by the SwiftPM executable and the optional Xcode app target.
public enum SlickMain {
    /// Exit status for arguments that cannot be parsed (EX_USAGE in sysexits.h).
    nonisolated static let usageStatus: Int32 = 64
    /// Exit status when a mode did not finish in time.
    nonisolated static let timeoutStatus: Int32 = 3

    /// Runs the mode that `arguments` ask for. `arguments` starts with the executable path, like
    /// `CommandLine.arguments`. Returns the exit status for arguments that cannot be parsed;
    /// every mode that parses runs an application and ends the process itself.
    public static func run(arguments: [String]) -> Int32 {
        let options: LaunchOptions
        do {
            options = try LaunchOptions(
                arguments: Array(arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
        } catch {
            printError("\(Brand.name): \(error.message)\n\(LaunchMode.usage)")
            return usageStatus
        }
        let folders = RunFolders.resolve(options, currentDirectory: FileManager.default.currentDirectoryPath)
        switch options.mode {
        case .launcher:
            LauncherApp.run(folders: folders)
        case .selftest:
            ModeHost.run(name: "selftest", limit: .seconds(60)) {
                await SelfTest.run(folders: folders)
            }
        case .bench(let name):
            ModeHost.run(name: "bench", limit: .seconds(600)) {
                await BenchMode.run(only: name, folders: folders)
            }
        case .scenario(let path):
            let current = FileManager.default.currentDirectoryPath
            let file = LaunchOptions.fileURL(path, currentDirectory: current)
            let output = options.output.map { LaunchOptions.fileURL($0, currentDirectory: current) }
            ModeHost.run(name: "scenario", limit: .seconds(Int(ScenarioMode.processLimit))) {
                await ScenarioMode.run(file: file, output: output, folders: folders)
            }
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Runs one non-interactive mode inside a running application, so AppKit, the window server and
/// LaunchServices behave as they do for the launcher, then ends the process with the mode's exit
/// status. A watchdog ends a mode that runs past its limit with a FAIL line.
@MainActor final class ModeHost: NSObject, NSApplicationDelegate {
    private let name: String
    private let limit: Duration
    private let body: @MainActor () async -> Int32

    private init(name: String, limit: Duration, body: @escaping @MainActor () async -> Int32) {
        self.name = name
        self.limit = limit
        self.body = body
    }

    static func run(name: String, limit: Duration, body: @escaping @MainActor () async -> Int32) -> Never {
        let app = NSApplication.shared
        // An accessory app: no Dock icon, no menu bar, never activated by starting.
        app.setActivationPolicy(.accessory)
        let host = ModeHost(name: name, limit: limit, body: body)
        app.delegate = host
        app.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = name
        let limit = limit
        Task.detached {
            try? await Task.sleep(for: limit)
            print("\(name) FAIL: did not finish within \(limit)")
            fflush(stdout)
            exit(SlickMain.timeoutStatus)
        }
        Task {
            let status = await body()
            fflush(stdout)
            fflush(stderr)
            exit(status)
        }
    }
}
