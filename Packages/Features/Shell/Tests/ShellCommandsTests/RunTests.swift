import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Running a command", .timeLimit(.minutes(1)))
@MainActor
struct RunTests {
    @Test func theLoginShellRunsAsALoginShellWithTheCommandAsOneArgument() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("ok\n"))
        await bench.start()
        let command = #"for f in *; do echo "$f"; done; echo '$HOME' `whoami` $(date)"#
        try await bench.harness.run("run", arguments: ["command": command])
        let request = try #require(bench.fakes.processes.runs.first)
        #expect(request.executable.path(percentEncoded: false) == "/bin/zsh")
        #expect(request.arguments == ["-l", "-c", command], "one argument, never spliced")
        #expect(
            request.environment == ["USER": "example", "LOGNAME": "example", "SHELL": "/bin/zsh"],
            "only the account's names on top of Kit's clean environment")
        #expect(request.currentDirectory?.path(percentEncoded: false) == bench.home.path(percentEncoded: false))
        #expect(request.standardInput == nil, "standard input reads from /dev/null")
        #expect(request.timeout == nil, "a command runs until it ends or is stopped")
    }

    @Test func cshAndTcshRunWithoutTheLoginFlagTheyRefuseBesideAnother() async throws {
        let bench = Bench()
        for shell in ["/bin/tcsh", "/bin/csh"] {
            bench.fakes.processes.stub(shell, output: .stdout("ok\n"))
        }
        await bench.start()
        for shell in ["/bin/tcsh", "/bin/csh"] {
            bench.system.login = shell
            try await bench.harness.run("run", arguments: ["command": "echo $SHELL"])
            let request = try #require(bench.fakes.processes.runs.last)
            #expect(request.executable.path(percentEncoded: false) == shell)
            #expect(request.arguments == ["-c", "echo $SHELL"])
        }
        #expect(RunSetup.loginFlags(for: "/opt/homebrew/bin/fish") == ["-l"])
        #expect(RunSetup.loginFlags(for: "/usr/local/bin/tcsh-extra") == ["-l"])
    }

    @Test func outputFromBothStreamsArrivesInOrderWithColorsKept() async throws {
        let bench = Bench()
        bench.fakes.processes.stub(
            "/bin/zsh",
            output: FakeProcessOutput(events: [
                .stdout(Data("\(Color.red)compiling\(Color.reset)\n".utf8)),
                .stderr(Data("warning: slow\n".utf8)),
                .stdout(Data("done\n".utf8)),
            ]))
        await bench.start()
        let outcome = try await bench.harness.run("run", arguments: ["command": "make"])
        #expect(outcome.kind == .push)
        #expect(bench.pageTitle == "make")
        let detail = try #require(bench.harness.detail)
        #expect(detail.body == .text("\(Color.red)compiling\(Color.reset)\nwarning: slow\ndone\n", monospaced: true))
        let labels = detail.metadata.compactMap { item -> String? in
            if case .label(let label, let value, _) = item { return "\(label): \(value)" }
            return nil
        }
        #expect(
            labels == [
                "Command: make", "Shell: zsh", "Folder: ~", "Status: Exited with status 0", "Run time: 0.0 s",
                "Input: \(Strings.Page.inputNote)",
            ])
        #expect(detail.metadata.contains(.date("Started", bench.fakes.clock.now)))
        #expect(
            bench.harness.actions().map(\.id) == [
                "copy-output", "paste-output", "run-again", "copy-command", "open-in-terminal",
            ])
        #expect(bench.harness.huds.isEmpty && bench.harness.toasts.isEmpty, "the page shows how it ended")
        #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty)
    }

    @Test func aFailedCommandShowsItsExitStatus() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stderr("zsh: command not found: mkae\n", exitCode: 127))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "mkae"])
        #expect(bench.harness.detail?.metadata.contains(status: "Exited with status 127") == true)
    }

    @Test func aShellThatCannotStartSaysWhy() async throws {
        let bench = Bench()
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(bench.harness.detail?.metadata.contains(status: "Could not start: no fake for zsh") == true)
        let entry = try #require(try bench.storedHistory()?.entries.first)
        #expect(entry.exitStatus == nil && !entry.stopped)
    }

    @Test func theShellAndTheFolderFollowSettings() async throws {
        let bench = Bench()
        for shell in ["/bin/bash", "/bin/sh", "/bin/zsh", "/opt/homebrew/bin/fish"] {
            bench.fakes.processes.stub(shell, output: .stdout(""))
        }
        await bench.start()
        let settings = bench.feature.context.settings
        func lastRun() -> ProcessRequest? { bench.fakes.processes.runs.last }

        settings[ShellSettings.shell] = .bash
        settings[ShellSettings.workingFolder] = "~/projects/site"
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(lastRun()?.executable.path(percentEncoded: false) == "/bin/bash")
        #expect(lastRun()?.currentDirectory?.path(percentEncoded: false).hasSuffix("/home/projects/site/") == true)
        #expect(bench.harness.detail?.metadata.hasLabel("Folder", "~/projects/site") == true)

        settings[ShellSettings.shell] = .login
        bench.system.login = "/opt/homebrew/bin/fish"
        settings[ShellSettings.workingFolder] = "  /srv/app  "
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(lastRun()?.executable.path(percentEncoded: false) == "/opt/homebrew/bin/fish")
        #expect(lastRun()?.currentDirectory?.path(percentEncoded: false) == "/srv/app/")

        bench.system.login = nil
        settings[ShellSettings.workingFolder] = "~"
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(lastRun()?.executable.path(percentEncoded: false) == "/bin/zsh", "an unreadable login shell is zsh")

        settings[ShellSettings.shell] = .sh
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(lastRun()?.executable.path(percentEncoded: false) == "/bin/sh")
    }

    @Test func aMissingShellOrFolderSaysWhatToChange() async throws {
        let bench = Bench()
        await bench.start()
        let settings = bench.feature.context.settings
        bench.harness.throwsActionErrors = false

        settings[ShellSettings.shell] = .bash
        bench.system.removeProgram("/bin/bash")
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(bench.harness.toasts.last?.title == "Shell Not Found")

        settings[ShellSettings.shell] = .zsh
        settings[ShellSettings.workingFolder] = "projects"
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(bench.harness.toasts.last?.title == "Working Folder Not Usable")

        settings[ShellSettings.workingFolder] = "~guest"
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(bench.harness.toasts.last?.title == "Working Folder Not Usable")

        settings[ShellSettings.workingFolder] = "/gone"
        bench.system.removeFolder("/gone")
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(bench.harness.toasts.last?.title == "Working Folder Not Found")
        #expect(bench.harness.toasts.last?.message?.hasPrefix("/gone is not a folder.") == true)
        #expect(bench.fakes.processes.runs.isEmpty && bench.harness.pages.isEmpty)
    }

    @Test func runTimeComesFromTheClock() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let running = Task { try await bench.harness.run("run", arguments: ["command": "sleep 12"]) }
        await processes.waitForStart()
        bench.fakes.clock.advance(by: .milliseconds(12_500))
        processes.exit(0)
        _ = try await running.value
        #expect(bench.harness.detail?.metadata.hasLabel("Run time", "12.5 s") == true)
        #expect(try bench.storedHistory()?.entries.first?.duration == 12.5)
    }

    @Test func runAgainRunsTheSameCommandInThePage() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("tick\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "date"])
        bench.feature.context.settings[ShellSettings.shell] = .bash
        bench.fakes.processes.stub("/bin/bash", output: .stdout("tock\n"))
        try await bench.harness.perform("run-again")
        #expect(bench.fakes.processes.runs.map(\.arguments) == [["-l", "-c", "date"], ["-l", "-c", "date"]])
        #expect(bench.fakes.processes.runs.last?.executable.lastPathComponent == "bash", "settings are read again")
        #expect(bench.harness.detail?.body == .text("tock\n", monospaced: true))
        #expect(bench.harness.pages.count == 1)
    }

    @Test func copyAndPasteOutputLeaveTheColorsOut() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("\(Color.red)error\(Color.reset): 2 failed\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "npm test"])
        try await bench.harness.perform("copy-output")
        #expect(bench.fakes.pasteboard.copiedTexts == ["error: 2 failed\n"])
        #expect(bench.harness.huds.map(\.title) == ["Copied Output"])
        try await bench.harness.run("run", arguments: ["command": "npm test"])
        try await bench.harness.perform("paste-output")
        #expect(bench.fakes.pasteboard.pastedTexts == ["error: 2 failed\n"])
        try await bench.harness.run("run", arguments: ["command": "npm test"])
        try await bench.harness.perform("copy-command")
        #expect(bench.fakes.pasteboard.copiedTexts.last == "npm test")
    }

    @Test func pasteOutputNeedsAccessibility() async throws {
        let bench = Bench(fakes: FakeServices(permissions: .denied))
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("x\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "ls"])
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await bench.harness.perform("paste-output")
        }
        #expect(bench.fakes.pasteboard.pastedTexts.isEmpty)
    }

    @Test func withoutOutputReturnCopiesTheCommand() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: FakeProcessOutput(events: []))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "true"])
        #expect(bench.harness.actions().map(\.id) == ["copy-command", "run-again", "open-in-terminal"])
        #expect(bench.harness.detail?.body == .text("", monospaced: true))
    }
}

extension [MetadataItem] {
    /// True when the status label reads `value`.
    func contains(status value: String) -> Bool {
        hasLabel("Status", value)
    }

    /// True when a label item with this label and value is there, whatever its icon.
    func hasLabel(_ label: String, _ value: String) -> Bool {
        contains { item in
            if case .label(label, value, _) = item { return true }
            return false
        }
    }
}
