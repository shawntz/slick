import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Each output mode against the fake process service. No script runs.
@Suite("Output modes", .timeLimit(.minutes(1)))
@MainActor
struct OutputModeTests {
    private let red = "\u{1B}[31m"
    private let reset = "\u{1B}[0m"

    // MARK: - Silent

    @Test func silentClosesFirstAndShowsTheLastLineAsAHUD() async throws {
        let bench = ScriptsBench(files: [
            "greet.sh": Fixture.script(
                "silent", extra: [#"argument1 { "type": "text", "placeholder": "name", "optional": true }"#])
        ])
        bench.fakes.processes.stubScripts { request in
            .stdout("working\n\(self.red)Hello \(Fixture.scriptArguments(request).first ?? "world")\(self.reset)\n\n")
        }
        await bench.start()
        let outcome = try await bench.harness.run(bench.id("greet.sh"), arguments: ["argument1": "Kit"])
        #expect(outcome.kind == .close(hud: .success("Hello Kit")))
        #expect(bench.harness.isClosed)
        #expect(bench.harness.huds == [.success("Hello Kit")])
        let request = try #require(bench.fakes.processes.runs.first)
        #expect(request.executable.path == "/bin/bash")
        #expect(request.arguments == [bench.folder.appending(path: "greet.sh").path, "Kit"])
        #expect(request.environment["PATH"] == ScriptsSettings.defaultSearchPath)
    }

    @Test func aSilentScriptThatFailsShowsItsErrorAsAHUD() async throws {
        let bench = ScriptsBench(files: ["mute.sh": Fixture.script("silent")])
        bench.fakes.processes.stubScripts([
            "mute.sh": FakeProcessOutput(
                events: [.stdout(Data("partial\n".utf8)), .stderr(Data("mute: no audio device\n".utf8))], exitCode: 2)
        ])
        await bench.start()
        try await bench.harness.run(bench.id("mute.sh"))
        #expect(bench.harness.huds == [.failure("mute: no audio device")])
    }

    // MARK: - Compact

    @Test func compactShowsTheLastLineAsAToast() async throws {
        let bench = ScriptsBench(files: ["disk.sh": Fixture.script(title: "Disk Space")])
        bench.fakes.processes.stubScripts(["disk.sh": .stdout("checking\n\(red)42 GB free\(reset)\n")])
        await bench.start()
        let outcome = try await bench.harness.run(bench.id("disk.sh"))
        #expect(outcome.kind == .keepOpen)
        #expect(bench.harness.toasts.map(\.title) == ["42 GB free"])
        #expect(bench.harness.toasts.map(\.style) == [.success])
    }

    @Test func aCompactScriptWithNoOutputSaysItFinished() async throws {
        let bench = ScriptsBench(files: ["quiet.sh": Fixture.script(title: "Quiet")])
        bench.fakes.processes.stubScripts(["quiet.sh": .stdout("")])
        await bench.start()
        try await bench.harness.run(bench.id("quiet.sh"))
        #expect(bench.harness.toasts.map(\.title) == [Strings.finished("Quiet")])
    }

    @Test func aCompactScriptThatFailsShowsItsErrorOutput() async throws {
        let bench = ScriptsBench(files: ["sync.sh": Fixture.script(title: "Sync")])
        bench.fakes.processes.stubScripts([
            "sync.sh": FakeProcessOutput(
                events: [.stdout(Data("syncing\n".utf8)), .stderr(Data("error: remote refused\nhint: retry\n".utf8))],
                exitCode: 3)
        ])
        await bench.start()
        try await bench.harness.run(bench.id("sync.sh"))
        let toast = try #require(bench.harness.visibleToast)
        #expect(toast.style == .failure)
        #expect(toast.title == "hint: retry")
        #expect(toast.message == Strings.failedWithCode(3))
        try await bench.harness.performToastAction()
        #expect(bench.harness.page?.page.isDetail == true)
        #expect(
            bench.harness.detail
                == Detail(
                    .text("syncing\nerror: remote refused\nhint: retry\n", monospaced: true),
                    metadata: [.label(Strings.exitCodeLabel, value: "3")]))
        #expect(bench.harness.actions().map(\.title) == [Strings.copyOutput])
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func aCompactScriptStartedByAHotkeyReportsWithAHUD() async throws {
        let bench = ScriptsBench(files: ["lock.sh": Fixture.script()])
        bench.fakes.processes.stubScripts(["lock.sh": .stdout("Locked\n")])
        await bench.start()
        try await bench.harness.run(bench.id("lock.sh"), launch: .hotkey)
        #expect(bench.harness.huds == [.success("Locked")])
        #expect(bench.harness.toasts.isEmpty)
    }

    @Test func aScriptThatCannotStartSaysWhy() async throws {
        let bench = ScriptsBench(files: ["ruby.rb": Fixture.script(title: "Gem", shebang: "#!/opt/none/ruby")])
        await bench.start()
        await #expect(throws: ActionFailure(Strings.couldNotStart("Gem"), message: "no fake for ruby")) {
            try await bench.harness.run(bench.id("ruby.rb"))
        }
    }

    @Test func aScriptThatAsksFirstRunsOnlyAfterTheConfirmation() async throws {
        let bench = ScriptsBench(files: [
            "empty-trash.sh": Fixture.script(title: "Empty Trash", extra: ["needsConfirmation true"])
        ])
        bench.fakes.processes.stubScripts(["empty-trash.sh": .stdout("Done\n")])
        await bench.start()
        bench.harness.confirmationAnswer = false
        try await bench.harness.run(bench.id("empty-trash.sh"))
        #expect(bench.harness.confirmations.map(\.title) == [Strings.confirmRun("Empty Trash")])
        #expect(bench.fakes.processes.runs.isEmpty)
        bench.harness.confirmationAnswer = true
        try await bench.harness.run(bench.id("empty-trash.sh"))
        #expect(bench.fakes.processes.runs.count == 1)
    }

    @Test func aFallbackPassesTheTypedTextAsTheFirstArgument() async throws {
        let bench = ScriptsBench(files: [
            "define.sh": Fixture.script(
                title: "Define", extra: [#"argument1 { "type": "text", "placeholder": "word" }"#])
        ])
        bench.fakes.processes.stubScripts { .stdout("\(Fixture.scriptArguments($0))\n") }
        await bench.start()
        let command = try bench.harness.command(bench.id("define.sh"))
        #expect(command.fallback?.title("serendipity") == Strings.runFallback("Define", text: "serendipity"))
        try await bench.harness.runFallback(bench.id("define.sh"), text: "serendipity")
        #expect(bench.harness.toasts.map(\.title) == [#"["serendipity"]"#])
    }

    @Test func scriptRowsOfferEditRevealAndCopyPath() async throws {
        let bench = ScriptsBench(files: ["a.sh": Fixture.script()])
        await bench.start()
        let actions = try bench.harness.rowActions(ofCommand: bench.id("a.sh"))
        #expect(actions.map(\.id) == ["edit-with", "reveal", "copy-path"])
        try await bench.harness.perform(actions[1], row: nil)
        #expect(bench.fakes.workspace.revealed.map(\.path) == [bench.folder.appending(path: "a.sh").path])
        #expect(bench.harness.issues.isEmpty)
    }

    // MARK: - Full output

    @Test func fullOutputStreamsIntoAPageWithColorsKept() async throws {
        let bench = ScriptsBench(files: ["build.sh": Fixture.script("fullOutput", title: "Build")])
        // "é" is split across two chunks, and the colors stay for the host to draw.
        let bytes = Array("\(red)step é\(reset)\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1
        bench.fakes.processes.stubScripts([
            "build.sh": FakeProcessOutput(events: [
                .stdout(Data(bytes[..<split])), .stdout(Data(bytes[split...])), .stderr(Data("warning: slow\n".utf8)),
            ])
        ])
        await bench.start()
        try await bench.harness.run(bench.id("build.sh"))
        let detail = try #require(bench.harness.detail)
        #expect(detail.body == .text("\(red)step é\(reset)\nwarning: slow\n", monospaced: true))
        #expect(
            detail.metadata
                == FullOutputSource.metadata(.exit(0), seconds: 0, locale: bench.fakes.clock.locale))
        #expect(bench.harness.actions().map(\.id) == ["copy-output", "run-again", "edit-with", "reveal"])

        try await bench.harness.perform("copy-output")
        #expect(bench.fakes.pasteboard.copiedTexts == ["step é\nwarning: slow\n"])
        try await bench.harness.run(bench.id("build.sh"))
        try await bench.harness.perform("run-again")
        #expect(bench.fakes.processes.runs.count == 3)
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func fullOutputShowsAFailedExit() async throws {
        let bench = ScriptsBench(files: ["test.sh": Fixture.script("fullOutput")])
        bench.fakes.processes.stubScripts(["test.sh": .stderr("1 test failed\n", exitCode: 1)])
        await bench.start()
        try await bench.harness.run(bench.id("test.sh"))
        #expect(
            bench.harness.detail?.metadata.first
                == FullOutputSource.metadata(.exit(1), seconds: 0, locale: .current).first)
    }

    private func fullOutputSource(_ processes: any ProcessService, limit: OutputLimit = .oneMegabyte) throws
        -> FullOutputSource
    {
        let folder = URL(filePath: "/scripts", directoryHint: .isDirectory)
        let url = folder.appending(path: "watch.sh")
        let script = try #require(
            ScriptCatalog.make(
                [
                    FolderListing(
                        folder: folder, exists: true,
                        files: [ScriptFile(url: url, header: Fixture.script("fullOutput"))])
                ], folders: [ScriptFolder(url: folder, isDefault: true, isEnabled: true)]
            ).entries.first?.script)
        let settings = RunSettings(
            timeout: nil, timeoutName: "", outputLimit: limit.bytes, outputLimitName: Strings.outputLimitName(limit),
            searchPath: ScriptsSettings.defaultSearchPath, home: folder)
        return FullOutputSource(
            script: script, request: script.request(arguments: [], settings: settings), processes: processes,
            clock: FakeClock(), settings: settings)
    }

    @Test func fullOutputUpdatesArriveOneByOneAndStopEndsTheScript() async throws {
        let processes = RecordingProcesses()
        processes.base.stub(
            "/bin/bash",
            output: FakeProcessOutput(
                events: [.stdout(Data("tick 1\n".utf8)), .stdout(Data("tick 2\n".utf8))], keepsRunning: true))
        let source = try fullOutputSource(processes)
        var updates = source.start().makeAsyncIterator()
        #expect(source.isRunning)
        #expect(
            try await updates.next()
                == .replace(
                    Detail(
                        .text("", monospaced: true),
                        metadata: [.label(Strings.statusLabel, value: Strings.statusRunning)])))
        #expect(try await updates.next() == .append("tick 1\n"))
        #expect(try await updates.next() == .append("tick 2\n"))
        #expect(
            source.actions(for: Detail(.text("tick 1\ntick 2\n"))).map(\.id) == [
                "copy-output", "stop", "edit-with", "reveal",
            ])

        source.stop()
        let last = try await updates.next()
        #expect(last == .metadata(FullOutputSource.metadata(.stopped, seconds: 0, locale: FakeClock().locale)))
        #expect(try await updates.next() == nil)
        await processes.waitForCancellations(1)
        #expect(!source.isRunning)
        #expect(
            source.actions(for: Detail(.text("tick 1\n"))).map(\.id) == [
                "copy-output", "run-again", "edit-with", "reveal",
            ])
    }

    @Test func leavingTheFullOutputPageEndsTheScript() async throws {
        let processes = RecordingProcesses()
        processes.base.stub(
            "/bin/bash", output: FakeProcessOutput(events: [.stdout(Data("serving\n".utf8))], keepsRunning: true))
        let source = try fullOutputSource(processes)

        // The page reads two updates and goes away, dropping the stream.
        let seen = try await Task {
            var seen: [DetailUpdate] = []
            for try await update in source.start() {
                seen.append(update)
                if seen.count == 2 { break }
            }
            return seen
        }.value
        #expect(seen.last == .append("serving\n"))
        await processes.waitForCancellations(1)

        // The host cancels the task that reads the page.
        let reader = Task {
            for try await _ in source.start() {}
        }
        reader.cancel()
        _ = await reader.result
        await processes.waitForCancellations(2)
        #expect(processes.cancelledCount == 2)
    }

    // MARK: - Inline

    @Test func inlineRunsOnlyWhenTheUserTurnedRefreshOn() async throws {
        let bench = ScriptsBench(files: [
            "battery.sh": Fixture.script("inline", title: "Battery", extra: ["refreshTime 1m"])
        ])
        bench.fakes.processes.stubScripts(["battery.sh": .stdout("\(red)12% left\(reset)\nmore detail\n")])
        await bench.start()
        let id = bench.id("battery.sh")
        let subtitle = try #require(try bench.harness.command(id).liveSubtitle)
        #expect(subtitle.interval == .seconds(60))
        #expect(subtitle.backgroundFetch != nil, "the fetch runs off the main thread")

        // Off by default: the subtitle shows nothing and runs nothing.
        #expect(await subtitle.value() == nil)
        #expect(bench.fakes.processes.runs.isEmpty)

        // Running it by hand shows the first line and keeps it as the subtitle.
        let changes = try #require(subtitle.changes)
        let before = changes.generation
        try await bench.harness.run(id)
        #expect(bench.harness.toasts.map(\.title) == ["12% left"])
        #expect(changes.generation == before + 1)
        #expect(await subtitle.value() == LiveSubtitle.Value("12% left", color: .red))
        #expect(bench.fakes.processes.runs.count == 1)

        // Turning refresh on from the row lets it run by itself.
        let toggle = try #require(try bench.harness.rowActions(ofCommand: id).first)
        #expect(toggle.title == Strings.turnOnRefresh)
        try await bench.harness.perform(toggle, row: nil)
        #expect(bench.harness.context.settings[ScriptsSettings.refreshingInline] == [id])
        #expect(await subtitle.value() == LiveSubtitle.Value("12% left", color: .red))
        #expect(bench.fakes.processes.runs.count == 2)
        #expect(try bench.harness.rowActions(ofCommand: id).first?.title == Strings.turnOffRefresh)
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func aFailingInlineScriptShowsItsErrorInRed() async throws {
        let bench = ScriptsBench(files: ["vpn.sh": Fixture.script("inline", title: "VPN", extra: ["refreshTime 30s"])])
        bench.fakes.processes.stubScripts(["vpn.sh": .stderr("not connected\n", exitCode: 1)])
        await bench.start()
        let id = bench.id("vpn.sh")
        bench.harness.context.settings[ScriptsSettings.refreshingInline] = [id]
        try await bench.harness.settle()
        let subtitle = try #require(try bench.harness.command(id).liveSubtitle)
        #expect(await subtitle.value() == LiveSubtitle.Value("not connected", color: .red))
    }

    @Test func anInlineScriptWithoutARefreshTimeRunsAsCompact() async throws {
        let bench = ScriptsBench(files: ["now.sh": Fixture.script("inline", title: "Now")])
        bench.fakes.processes.stubScripts(["now.sh": .stdout("first\nlast\n")])
        await bench.start()
        let command = try bench.harness.command(bench.id("now.sh"))
        #expect(command.liveSubtitle == nil)
        try await bench.harness.run(command.id)
        #expect(bench.harness.toasts.map(\.title) == ["last"])
    }
}

extension Page {
    var isDetail: Bool {
        if case .detail = self { return true }
        return false
    }
}
