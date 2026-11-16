import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

/// What a command gets on top of Kit's clean environment, which holds `PATH`, `HOME`, `LANG` and
/// `TMPDIR`: `USER`, `LOGNAME` and `SHELL` from the account record, and `SSH_AUTH_SOCK` from the
/// app's own environment when it is set. Nothing else.
@Suite("Environment", .timeLimit(.minutes(1)))
@MainActor
struct EnvironmentTests {
    /// An app environment with names that load code, choose where to connect or change a shell.
    static let crowdedAppEnvironment: [String: String] = [
        "SSH_AUTH_SOCK": "/private/tmp/example-agent/listener",
        "TERM": "xterm-256color",
        "BASH_ENV": "/tmp/example.sh",
        "ENV": "/tmp/example.sh",
        "ZDOTDIR": "/tmp/example",
        "DYLD_INSERT_LIBRARIES": "/tmp/example.dylib",
        "GIT_SSH_COMMAND": "example",
        "SSH_ASKPASS": "/tmp/example",
        "PATH": "/tmp/example/bin",
        "HOME": "/tmp/example",
        "USER": "someone-else",
        "SHELL": "/tmp/example-shell",
        "XPC_SERVICE_NAME": "example",
        "__CFBundleIdentifier": "com.example.app",
    ]

    @Test func aCommandGetsTheAccountsNamesAndTheAgentSocketAndNothingElse() async throws {
        let bench = Bench()
        bench.system.appEnvironment = Self.crowdedAppEnvironment
        bench.system.setAccount(name: "example", shell: "/bin/zsh")
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("ok\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "git fetch"])
        let request = try #require(bench.fakes.processes.runs.first)
        #expect(Set(request.environment.keys) == ["USER", "LOGNAME", "SHELL", "SSH_AUTH_SOCK"])
        #expect(Set(request.environment.keys) == ShellEnvironment.names)
        #expect(
            request.environment == [
                "USER": "example", "LOGNAME": "example", "SHELL": "/bin/zsh",
                "SSH_AUTH_SOCK": "/private/tmp/example-agent/listener",
            ])
    }

    @Test func withoutAnAgentTheSocketIsLeftOut() async throws {
        let bench = Bench()
        bench.system.appEnvironment = ["TERM": "xterm-256color", "SSH_AUTH_SOCK": ""]
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("ok\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "true"])
        let request = try #require(bench.fakes.processes.runs.first)
        #expect(Set(request.environment.keys) == ["USER", "LOGNAME", "SHELL"])
    }

    @Test func theAccountsShellIsSetEvenWhenSettingsPickAnotherShell() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/bash", output: .stdout("ok\n"))
        await bench.start()
        bench.feature.context.settings[ShellSettings.shell] = .bash
        try await bench.harness.run("run", arguments: ["command": "true"])
        let request = try #require(bench.fakes.processes.runs.first)
        #expect(request.executable.path(percentEncoded: false) == "/bin/bash")
        #expect(request.environment["SHELL"] == "/bin/zsh", "as login sets it, from the account record")
    }

    @Test func valuesThatCannotBeTrustedAreLeftOut() {
        #expect(ShellEnvironment.entries(accountName: nil, accountShell: nil, appEnvironment: [:]).isEmpty)
        #expect(
            ShellEnvironment.entries(accountName: "", accountShell: "zsh", appEnvironment: ["SSH_AUTH_SOCK": ""])
                .isEmpty, "empty values and a shell that is not an absolute path")
        #expect(
            ShellEnvironment.entries(
                accountName: "exa\nmple", accountShell: "/bin/zsh\u{0}",
                appEnvironment: ["SSH_AUTH_SOCK": "/tmp/a\u{1B}b"]
            ).isEmpty, "control characters")
        #expect(
            ShellEnvironment.entries(accountName: "example", accountShell: nil, appEnvironment: [:])
                == ["USER": "example", "LOGNAME": "example"])
    }

    @Test func theSimulatedSystemAddsNothing() async {
        #expect(await SimulatedShellSystem().environment().isEmpty)
    }

    @Test func theSettingsSayWhatACommandGets() {
        let footer = Strings.Settings.runFooter
        #expect(!footer.contains("Nothing is added to the environment"))
        for name in ShellEnvironment.names {
            #expect(footer.contains(name))
        }
        #expect(footer.contains("Nothing else is added."))
        #expect(footer.contains("Stop ends the command and every process it started."))
    }
}
