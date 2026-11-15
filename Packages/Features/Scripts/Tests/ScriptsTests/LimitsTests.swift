import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// The time limit and the output limit from settings, in every mode.
@Suite("Limits", .timeLimit(.minutes(1)))
@MainActor
struct LimitsTests {
    @Test(arguments: [
        (ScriptTimeout.tenSeconds, Duration?.some(.seconds(10))), (.oneMinute, .seconds(60)),
        (.fifteenMinutes, .seconds(900)),
        (.never, nil),
    ])
    func everyRunCarriesTheTimeLimit(timeout: ScriptTimeout, expected: Duration?) async throws {
        let bench = ScriptsBench(files: [
            "a.sh": Fixture.script(), "b.sh": Fixture.script("fullOutput"), "c.sh": Fixture.script("list"),
            "d.sh": Fixture.script("silent"),
        ])
        bench.fakes.processes.stubScripts { _ in .stdout(#"{"items": []}"#) }
        bench.harness.context.settings[ScriptsSettings.timeout] = timeout
        await bench.start()
        for name in ["a.sh", "b.sh", "c.sh", "d.sh"] { try await bench.harness.run(bench.id(name)) }
        #expect(bench.fakes.processes.runs.map(\.timeout) == [expected, expected, expected, expected])
    }

    @Test func theDefaultsAreSafe() {
        let settings = FakeServices().context(featureID: "scripts").settings
        #expect(settings[ScriptsSettings.timeout] == .oneMinute)
        #expect(settings[ScriptsSettings.outputLimit] == .oneMegabyte)
        #expect(settings[ScriptsSettings.folders].isEmpty)
        #expect(settings[ScriptsSettings.enabledFolders].isEmpty)
        #expect(settings[ScriptsSettings.refreshingInline].isEmpty)
        #expect(
            settings[ScriptsSettings.searchPath] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func theSearchPathComesFromSettings() async throws {
        let bench = ScriptsBench(files: ["a.sh": Fixture.script()])
        bench.fakes.processes.stubScripts(["a.sh": .stdout("ok\n")])
        bench.harness.context.settings[ScriptsSettings.searchPath] = " /custom/bin:/usr/bin "
        await bench.start()
        try await bench.harness.run(bench.id("a.sh"))
        bench.harness.context.settings[ScriptsSettings.searchPath] = ""
        try await bench.harness.run(bench.id("a.sh"))
        #expect(
            bench.fakes.processes.runs.map { $0.environment["PATH"] } == [
                "/custom/bin:/usr/bin", ScriptsSettings.defaultSearchPath,
            ])
    }

    // MARK: - Timeouts

    private func timingOut(_ files: [String: String]) async -> (ScriptsBench, RecordingProcesses) {
        let processes = RecordingProcesses()
        processes.base.stubScripts { _ in .stdout("partial output\n") }
        for name in files.keys { processes.end(name, with: .timedOut) }
        let bench = ScriptsBench(files: files, processes: processes)
        await bench.start()
        return (bench, processes)
    }

    @Test func aCompactScriptPastTheTimeLimitSaysSo() async throws {
        let (bench, _) = await timingOut(["slow.sh": Fixture.script(title: "Slow")])
        await #expect(
            throws: ActionFailure(Strings.timedOut("Slow", after: "1 minute"), message: Strings.timedOutMessage)
        ) {
            try await bench.harness.run(bench.id("slow.sh"))
        }
    }

    @Test func aSilentScriptPastTheTimeLimitSaysSoInAHUD() async throws {
        let (bench, _) = await timingOut(["slow.sh": Fixture.script("silent", title: "Slow")])
        try await bench.harness.run(bench.id("slow.sh"))
        #expect(bench.harness.huds == [.failure(Strings.timedOut("Slow", after: "1 minute"))])
    }

    @Test func aListScriptPastTheTimeLimitShowsItOnThePage() async throws {
        let (bench, _) = await timingOut(["slow.sh": Fixture.script("list", title: "Slow")])
        try await bench.harness.run(bench.id("slow.sh"))
        #expect(bench.harness.page?.emptyState?.title == Strings.timedOut("Slow", after: "1 minute"))
    }

    @Test func aFullOutputScriptPastTheTimeLimitKeepsItsOutput() async throws {
        let (bench, _) = await timingOut(["slow.sh": Fixture.script("fullOutput", title: "Slow")])
        try await bench.harness.run(bench.id("slow.sh"))
        #expect(bench.harness.detail?.body == .text("partial output\n", monospaced: true))
        #expect(bench.harness.detail?.metadata.first == .label(Strings.statusLabel, value: Strings.statusTimedOut))
    }

    @Test func anInlineScriptPastTheTimeLimitShowsItInRed() async throws {
        let (bench, _) = await timingOut(["slow.sh": Fixture.script("inline", title: "Slow", extra: ["refreshTime 1m"])]
        )
        let id = bench.id("slow.sh")
        bench.harness.context.settings[ScriptsSettings.refreshingInline] = [id]
        let subtitle = try #require(try bench.harness.command(id).liveSubtitle)
        #expect(await subtitle.value() == LiveSubtitle.Value(Strings.timedOut("Slow", after: "1 minute"), color: .red))
    }

    // MARK: - Output limit

    private func flooding(_ files: [String: String]) async -> (ScriptsBench, RecordingProcesses) {
        let processes = RecordingProcesses()
        let chunk = Data(repeating: UInt8(ascii: "y"), count: 200 * 1024)
        processes.base.stubScripts { _ in
            FakeProcessOutput(events: [.stdout(chunk), .stdout(chunk), .stdout(chunk)], keepsRunning: true)
        }
        let bench = ScriptsBench(files: files, processes: processes)
        bench.harness.context.settings[ScriptsSettings.outputLimit] = .quarterMegabyte
        await bench.start()
        return (bench, processes)
    }

    @Test func aCompactScriptPastTheOutputLimitIsStopped() async throws {
        let (bench, processes) = await flooding(["yes.sh": Fixture.script(title: "Flood")])
        await #expect(
            throws: ActionFailure(Strings.overLimit("Flood", limit: "256 KB"), message: Strings.overLimitMessage)
        ) {
            try await bench.harness.run(bench.id("yes.sh"))
        }
        await processes.waitForCancellations(1)
        #expect(processes.cancelledCount == 1)
    }

    @Test func aListScriptPastTheOutputLimitIsStopped() async throws {
        let (bench, processes) = await flooding(["yes.sh": Fixture.script("list", title: "Flood")])
        try await bench.harness.run(bench.id("yes.sh"))
        #expect(bench.harness.page?.emptyState?.title == Strings.overLimit("Flood", limit: "256 KB"))
        await processes.waitForCancellations(1)
    }

    @Test func aFullOutputScriptPastTheOutputLimitShowsWhatFitAndStops() async throws {
        let (bench, processes) = await flooding(["yes.sh": Fixture.script("fullOutput", title: "Flood")])
        try await bench.harness.run(bench.id("yes.sh"))
        guard case .text(let text, _) = bench.harness.detail?.body else {
            Issue.record("expected text")
            return
        }
        let limit = OutputLimit.quarterMegabyte.bytes
        #expect(text.hasPrefix(String(repeating: "y", count: limit)))
        #expect(text.hasSuffix(Strings.outputCut(limit: "256 KB")))
        #expect(text.utf8.count == limit + Strings.outputCut(limit: "256 KB").utf8.count)
        #expect(bench.harness.detail?.metadata.first == .label(Strings.statusLabel, value: Strings.statusOverLimit))
        await processes.waitForCancellations(1)
    }

    @Test func captureStopsAtTheLimitAndEndsTheProcess() async throws {
        let processes = RecordingProcesses()
        processes.base.stub(
            "/bin/sh",
            output: FakeProcessOutput(
                events: [.stdout(Data("12345".utf8)), .stderr(Data("678".utf8)), .stdout(Data("9".utf8))],
                keepsRunning: true))
        let request = ProcessRequest(executable: URL(filePath: "/bin/sh"))
        await #expect(throws: ScriptRunError.outputLimit) {
            try await ScriptExecution.capture(processes, request, limit: 8)
        }
        await processes.waitForCancellations(1)

        let fitting = FakeProcesses()
        fitting.stub(
            "/bin/sh",
            output: FakeProcessOutput(events: [.stdout(Data("1234".utf8)), .stderr(Data("5678".utf8))], exitCode: 4))
        let output = try await ScriptExecution.capture(fitting, request, limit: 8)
        #expect(output == CapturedOutput(exitCode: 4, stdout: Data("1234".utf8), stderr: Data("5678".utf8)))
    }

    @Test func captureEndsTheProcessWhenItsTaskIsCancelled() async throws {
        let processes = RecordingProcesses()
        processes.base.stub("/bin/sh", output: FakeProcessOutput(events: [], keepsRunning: true))
        let request = ProcessRequest(executable: URL(filePath: "/bin/sh"))
        let task = Task { try await ScriptExecution.capture(processes, request, limit: 1024) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await processes.waitForCancellations(1)
    }
}
