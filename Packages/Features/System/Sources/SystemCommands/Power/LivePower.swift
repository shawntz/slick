import AppKit
import Darwin
import IOKit.pwr_mgt
import Kit

/// The real power and session requests. Used only when the app runs for a person.
///
/// Each request uses the most documented route macOS offers:
/// - Sleep: `IOPMSleepSystem` from IOKit, which the console user may call. It is what `pmset
///   sleepnow` calls.
/// - Sleep Displays: `/usr/bin/pmset displaysleepnow`, through Kit's process service. IOKit has no
///   public call for display sleep.
/// - Lock Screen: `SACLockScreenImmediate` from the private login framework, looked up at run time.
///   macOS has no public call to lock the screen. When the symbol is missing the command says so.
/// - Start Screen Saver: opens `ScreenSaverEngine.app` with `NSWorkspace`.
/// - Log Out, Restart and Shut Down: the Apple Events that loginwindow documents for this, sent
///   without its own dialog, since the command has already asked. Apps still get to save their work
///   and may cancel.
nonisolated final class LivePower: PowerService {
    static let pmset = URL(filePath: "/usr/bin/pmset")
    static let screenSaver = URL(
        filePath: "/System/Library/CoreServices/ScreenSaverEngine.app", directoryHint: .isDirectory)
    static let loginFramework = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    static let loginWindowID = "com.apple.loginwindow"

    private let processes: any ProcessService

    init(processes: any ProcessService) {
        self.processes = processes
    }

    @concurrent func perform(_ request: PowerRequest) async throws {
        switch request {
        case .sleep: try Self.sleep()
        case .sleepDisplays: try await sleepDisplays()
        case .lockScreen: try Self.lockScreen()
        case .startScreenSaver: try await Self.startScreenSaver()
        case .logOut: try Self.sendToLoginWindow(AEEventID(kAEReallyLogOut))
        case .restart: try Self.sendToLoginWindow(AEEventID(kAERestart))
        case .shutDown: try Self.sendToLoginWindow(AEEventID(kAEShutDown))
        }
    }

    /// Asks the power manager to sleep now.
    private static func sleep() throws {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else { throw SystemFailure.unavailable }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else { throw SystemFailure.failed(code: result) }
    }

    /// Runs `pmset displaysleepnow`, which turns the displays off and leaves the Mac awake.
    private func sleepDisplays() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.pmset.path) else { throw SystemFailure.unavailable }
        let result = try await processes.run(
            ProcessRequest(executable: Self.pmset, arguments: ["displaysleepnow"], timeout: .seconds(10)))
        guard result.exitCode == 0 else { throw SystemFailure.failed(code: result.exitCode) }
    }

    /// Locks the screen at once, as Lock Screen in the Apple menu does. The function's return value
    /// is not documented, so it is not read: a wrong guess would report a failure after the screen
    /// had locked.
    private static func lockScreen() throws {
        typealias LockScreen = @convention(c) () -> Void
        guard let framework = dlopen(loginFramework, RTLD_LAZY),
            let symbol = dlsym(framework, "SACLockScreenImmediate")
        else {
            throw SystemFailure.unavailable
        }
        let lock = unsafeBitCast(symbol, to: LockScreen.self)
        lock()
    }

    /// Opens the screen saver engine, which starts the user's chosen screen saver.
    private static func startScreenSaver() async throws {
        guard FileManager.default.fileExists(atPath: screenSaver.path) else { throw SystemFailure.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: screenSaver, configuration: configuration)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Sends one of loginwindow's session events: log out, restart or shut down.
    private static func sendToLoginWindow(_ eventID: AEEventID) throws {
        let target = AppleEvents.target(bundleID: loginWindowID)
        try AppleEvents.checkPermission(for: target, bundleID: loginWindowID)
        let event = AppleEvents.event(AEEventClass(kCoreEventClass), eventID, to: target)
        try AppleEvents.sendWithoutReply(event, bundleID: loginWindowID)
    }
}
