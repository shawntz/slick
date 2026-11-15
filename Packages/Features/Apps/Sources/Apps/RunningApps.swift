import Foundation
import Kit

/// One running application, as plain data.
nonisolated struct RunningApp: Hashable, Sendable {
    var pid: Int32
    var bundleID: String?
    var name: String
    /// The bundle's path, when the app has one.
    var path: String?
    var isHidden: Bool
}

/// Which apps are running, and quitting, hiding and force-quitting them. Only this feature needs it,
/// so it lives here behind ``RunningAppsKey`` rather than in Kit. Opening an app goes through Kit's
/// `WorkspaceService`.
///
/// The live implementation acts on real processes. Scenarios, self-tests and tests get
/// ``SimulatedRunningApps``, so nothing they do can quit an app on the Mac.
nonisolated protocol RunningAppsService: Sendable {
    /// The apps with a Dock icon that run now, by name. Menu bar apps and agents are left out.
    @concurrent func apps() async -> [RunningApp]

    /// Yields after every launch, quit, hide and unhide. Each call returns its own stream; it ends
    /// when the consuming task is cancelled.
    func changes() -> AsyncStream<Void>

    /// Asks the app to quit, as Quit in its menu would. It may ask the user to save first. Returns
    /// false when the request could not be sent.
    @concurrent func quit(_ app: RunningApp) async -> Bool

    /// Ends the app at once. Unsaved work is lost.
    @concurrent func forceQuit(_ app: RunningApp) async -> Bool

    @concurrent func hide(_ app: RunningApp) async -> Bool

    /// Waits until the app has quit, for at most `timeout`. Returns false when it is still running.
    @concurrent func waitUntilQuit(_ app: RunningApp, timeout: Duration) async -> Bool
}

/// The running apps for each kind of run.
nonisolated enum RunningAppsKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any RunningAppsService {
        WorkspaceRunningApps()
    }

    static func isolated(_ context: FeatureContext) -> any RunningAppsService {
        SimulatedRunningApps(
            SyntheticApps.runningInScenarios.enumerated().map { index, bundleID in
                RunningApp(
                    pid: Int32(1_000 + index), bundleID: bundleID,
                    name: bundleID.split(separator: ".").last.map { $0.capitalized } ?? bundleID, path: nil,
                    isHidden: false)
            })
    }
}
