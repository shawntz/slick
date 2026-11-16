import Foundation
import Kit
import Testing

@testable import SlickApp

@Suite("Launch options")
struct LaunchModeTests {
    @Test(arguments: [
        ([String](), LaunchMode.launcher),
        (["--selftest"], .selftest),
        (["--bench"], .bench(name: nil)),
        (["--bench", "typing"], .bench(name: "typing")),
        (["--scenario", "/tmp/s.json"], .scenario(path: "/tmp/s.json")),
        (["-NSDocumentRevisionsDebugMode", "YES", "--selftest"], .selftest),
        (["-psn_0_12345"], .launcher),
        (["--data-dir", "/tmp/d", "--selftest"], .selftest),
        (["--scenario", "a.json", "--output", "/tmp/out"], .scenario(path: "a.json")),
        (["--version"], .version),
    ])
    func parsesTheMode(arguments: [String], expected: LaunchMode) throws {
        #expect(try LaunchOptions(arguments: arguments).mode == expected)
    }

    @Test(arguments: [
        ["--unknown"],
        ["--selftest", "extra"],
        ["--bench", "a", "b"],
        ["--bench", "--selftest"],
        ["--scenario"],
        ["--scenario", "a.json", "b.json"],
        ["stray"],
        ["--data-dir"],
        ["--data-dir", "--selftest"],
        ["--data-dir", "/a", "--data-dir", "/b"],
        ["--selftest", "--output", "/tmp/out"],
        ["--scenario", "a.json", "--output"],
        ["--selftest", "--scenario", "a.json"],
        ["--version", "extra"],
        ["--version", "--selftest"],
        ["--version", "--output", "/tmp/out"],
    ])
    func rejects(arguments: [String]) {
        #expect(throws: UsageError.self) { try LaunchOptions(arguments: arguments) }
    }

    @Test func dataFolderComesFromTheFlagThenTheVariable() throws {
        let variable = LaunchOptions.dataDirectoryVariable
        #expect(variable == Brand.name.uppercased() + "_DATA_DIR")
        let fromVariable = try LaunchOptions(arguments: ["--selftest"], environment: [variable: "/tmp/v"])
        #expect(fromVariable.dataDirectory == "/tmp/v")
        let fromFlag = try LaunchOptions(
            arguments: ["--data-dir", "/tmp/f", "--selftest"], environment: [variable: "/tmp/v"])
        #expect(fromFlag.dataDirectory == "/tmp/f")
        let empty = try LaunchOptions(arguments: [], environment: [variable: ""])
        #expect(empty.dataDirectory == nil)
    }

    @Test func outputGoesWithAScenario() throws {
        let options = try LaunchOptions(arguments: ["--output", "/tmp/out", "--scenario", "s.json"])
        #expect(options.output == "/tmp/out")
        #expect(options.mode == .scenario(path: "s.json"))
    }

    @Test func eachModeHasItsEnvironment() {
        #expect(LaunchMode.launcher.environment == .live)
        #expect(LaunchMode.selftest.environment == .selftest)
        #expect(LaunchMode.bench(name: nil).environment == .bench)
        #expect(LaunchMode.scenario(path: "x").environment == .scenario)
        #expect(LaunchMode.launcher.verdictName == nil)
        #expect(LaunchMode.scenario(path: "x").verdictName == "scenario")
        #expect(LaunchMode.version.environment != .live, "--version is never the live launcher")
        #expect(LaunchMode.version.verdictName == nil)
    }

    /// `--version` returns its status instead of running an application, so it ends before any
    /// window, menu bar item or hotkey exists. Running it here prints one line and shows nothing.
    @Test func versionReturnsBeforeTheAppStarts() {
        #expect(SlickMain.run(arguments: ["app", "--version"]) == 0)
        #expect(LaunchMode.usage.contains("--version"))
    }

    @Test func theVersionLineNamesTheVersionAndTheBuild() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412"]
        #expect(VersionLine.text(info: info) == "\(Brand.name) 0.1.0 (412)")
        #expect(VersionLine.text(info: ["CFBundleShortVersionString": "0.1.0"]) == "\(Brand.name) 0.1.0")
        #expect(VersionLine.text(info: [:]) == "\(Brand.name) Development")
    }

    @Test func pathsResolveAgainstTheCurrentFolder() {
        #expect(LaunchOptions.fileURL("/a/b.json", currentDirectory: "/c").path == "/a/b.json")
        #expect(LaunchOptions.fileURL("b.json", currentDirectory: "/c").path == "/c/b.json")
        #expect(LaunchOptions.fileURL("../b.json", currentDirectory: "/c/d").path == "/c/b.json")
        #expect(LaunchOptions.fileURL("~/b.json", currentDirectory: "/c").path.hasSuffix("/b.json"))
    }

    @Test func isolatedRunsGetATemporaryFolderAndTheLauncherDoesNot() throws {
        let selftest = RunFolders.resolve(try LaunchOptions(arguments: ["--selftest"]), currentDirectory: "/")
        #expect(selftest.isTemporary)
        #expect(selftest.dataRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let given = RunFolders.resolve(
            try LaunchOptions(arguments: ["--selftest", "--data-dir", "/tmp/given"]), currentDirectory: "/")
        #expect(!given.isTemporary)
        #expect(given.dataRoot.path == "/tmp/given")
        let live = RunFolders.resolve(try LaunchOptions(arguments: ["--data-dir", "/tmp/live"]), currentDirectory: "/")
        #expect(!live.isTemporary)
        #expect(live.dataRoot.path == "/tmp/live")
    }

    @Test func badArgumentsAreAUsageError() {
        #expect(SlickMain.run(arguments: ["app", "--nope"]) == SlickMain.usageStatus)
        #expect(SlickMain.run(arguments: ["app", "--bench", "a", "b"]) == SlickMain.usageStatus)
    }
}
