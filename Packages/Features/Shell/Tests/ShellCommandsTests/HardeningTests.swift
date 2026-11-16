import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import ShellCommands

/// Shell lookups that hold the first login shell lookup until the test lets it go, to play a run
/// whose setup is still going when the feature is turned off.
nonisolated final class GatedShellSystem: ShellSystem {
    private struct State {
        var gate: CheckedContinuation<Void, Never>?
        var isOpen = false
        var askedWaiters: [CheckedContinuation<Void, Never>] = []
        var asked = false
    }

    private let state = Mutex(State())

    /// Returns once a run asked for the login shell.
    func waitUntilAsked() async {
        await withCheckedContinuation { continuation in
            let asked = state.withLock { state in
                guard !state.asked else { return true }
                state.askedWaiters.append(continuation)
                return false
            }
            if asked { continuation.resume() }
        }
    }

    /// Lets the held lookup answer.
    func open() {
        let gate = state.withLock { state in
            state.isOpen = true
            defer { state.gate = nil }
            return state.gate
        }
        gate?.resume()
    }

    @concurrent func loginShell() async -> String? {
        await withCheckedContinuation { continuation in
            let (waiters, isOpen) = state.withLock { state in
                state.asked = true
                defer { state.askedWaiters = [] }
                if !state.isOpen { state.gate = continuation }
                return (state.askedWaiters, state.isOpen)
            }
            for waiter in waiters { waiter.resume() }
            if isOpen { continuation.resume() }
        }
        return "/bin/zsh"
    }

    @concurrent func isFolder(_ path: String) async -> Bool { true }
    @concurrent func isProgram(_ path: String) async -> Bool { true }
    @concurrent func environment() async -> [String: String] { [:] }
}

@Suite("Hardening", .timeLimit(.minutes(1)))
@MainActor
struct HardeningTests {
    // MARK: Text the page hides

    @Test func copyOutputLeavesOutEveryStringThePageHides() {
        // The host hides DCS, APC, PM and OSC strings up to BEL or ESC "\", and an OSC string goes on
        // past an ESC that is not followed by "\".
        let hidden = [
            "\u{1B}Pdevice control\u{1B}\\",
            "\u{1B}_application\u{07}",
            "\u{1B}^privacy message\u{1B}\\",
            "\u{1B}]0;title\u{1B}Xstill the title\u{07}",
        ]
        for sequence in hidden {
            #expect(ANSI.strip("before " + sequence + "after\n") == "before after\n", "\(sequence.debugDescription)")
        }
        #expect(ANSI.strip("\(Color.red)red\(Color.reset) \u{1B}[2Kplain\u{1B}7") == "red plain")
        #expect(ANSI.strip("cut \u{1B}]8;;https://example.com") == "cut ", "an open string shows nothing")
        #expect(ANSI.strip("cut \u{1B}") == "cut ")
        #expect(ANSI.strip("no escapes at all") == "no escapes at all")
    }

    @Test func pasteOutputNeverPastesALineThePageHides() async throws {
        let bench = Bench(fakes: FakeServices(permissions: .granted))
        bench.fakes.processes.stub(
            "/bin/zsh", output: .stdout("listing\n\u{1B}P\nrm -rf ~/work\n\u{1B}\\done\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "ls"])
        try await bench.harness.perform("paste-output")
        try await bench.harness.perform("copy-output")
        #expect(bench.fakes.pasteboard.pastedTexts == ["listing\ndone\n"])
        let copied = bench.fakes.pasteboard.copiedTexts
        #expect(!copied.isEmpty && copied.allSatisfy { $0 == "listing\ndone\n" })
    }

    // MARK: Output that never ends

    @Test func endlessOutputNeverPilesUpForAPageThatDrawsSlowly() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let run = try await bench.feature.board.start(try ShellCommand.check("yes").get(), reporter: nil)
        let page = RunPage(run: run, board: bench.feature.board, handOff: bench.feature.handOff)
        var updates = page.start().makeAsyncIterator()
        await processes.waitForStart()
        var shown = Detail()
        shown.apply(try #require(try await updates.next()))

        // The page reads nothing while the command prints 20,000 chunks and ends.
        for _ in 0..<20_000 {
            processes.stdout("y\n")
        }
        processes.exit(0)
        await run.waitUntilEnded()
        var count = 0
        while let update = try await updates.next() {
            shown.apply(update)
            count += 1
        }
        #expect(count <= 3, "what the page missed comes as one update, then the metadata")
        #expect(shown.body == run.output.detail.body)
        #expect(shown.metadata.contains(status: "Exited with status 0"))
    }

    @Test func aPageThatLeavesStopsHoldingTheRunsOutput() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let run = try await bench.feature.board.start(try ShellCommand.check("top").get(), reporter: nil)
        let page = RunPage(run: run, board: bench.feature.board, handOff: bench.feature.handOff)
        do {
            var updates = page.start().makeAsyncIterator()
            _ = try await updates.next()
            #expect(run.output.watcherCount == 1)
        }
        #expect(run.output.watcherCount == 0, "a stream the host dropped holds nothing")
        processes.exit(0)
        await run.waitUntilEnded()
    }

    // MARK: Turning the feature off while a run starts

    @Test func aRunWhoseHandlerIsCancelledDuringItsSetupStartsNoProcess() async throws {
        let processes = ScriptedProcesses()
        let system = GatedShellSystem()
        let fakes = FakeServices()
        fakes.override(ShellProcessesKey.self, with: processes)
        fakes.override(ShellSystemKey.self, with: system)
        let harness = FeatureHarness<ShellFeature>(fakes: fakes)
        await harness.activate()
        let board = harness.feature.board
        let command = try ShellCommand.check("sleep 600").get()
        let starting = Task { try await board.start(command, reporter: nil) }
        await system.waitUntilAsked()
        // The host cancels a feature's handlers when the user turns it off, then deactivates it.
        starting.cancel()
        await harness.deactivate()
        system.open()
        let result = await starting.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(processes.requests.isEmpty, "no process starts after the feature was turned off")
        #expect(board.running.isEmpty)
    }

    @Test func aRunStillInItsSetupWhenTheFeatureIsTurnedOffStartsNoProcess() async throws {
        let processes = ScriptedProcesses()
        let system = GatedShellSystem()
        let fakes = FakeServices()
        fakes.override(ShellProcessesKey.self, with: processes)
        fakes.override(ShellSystemKey.self, with: system)
        let harness = FeatureHarness<ShellFeature>(fakes: fakes)
        await harness.activate()
        let board = harness.feature.board
        let command = try ShellCommand.check("sleep 600").get()
        let starting = Task { try await board.start(command, reporter: nil) }
        await system.waitUntilAsked()
        await harness.deactivate()
        system.open()
        let result = await starting.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(processes.requests.isEmpty)
        #expect(board.running.isEmpty)

        // On again, a run starts as usual.
        await harness.activate()
        let again = try await board.start(command, reporter: nil)
        await processes.waitForStart()
        #expect(processes.requests.count == 1)
        again.stop()
        await again.waitUntilEnded()
    }

    // MARK: Open in Terminal

    @Test func aTerminalScriptDeletesItselfWhenTerminalStartsIt() async throws {
        let bench = Bench()
        await bench.start()
        let row = try #require(try await bench.rootRow(">  export TOKEN=secret; deploy"))
        _ = try await bench.harness.performRoot("open-in-terminal", on: row)
        let script = try #require(bench.fakes.workspace.openedWith.first?.urls.first)
        let lines = try String(contentsOf: script, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines.first == "#!/bin/zsh -l")
        #expect(lines.dropFirst().first == "/bin/rm -f -- " + TerminalScript.quoted(script.path(percentEncoded: false)))
        #expect(lines.last == " export TOKEN=secret; deploy", "the command as typed, after the script is gone")
    }

    @Test func aScriptPathWithAQuoteIsQuotedOnTheLineThatDeletesIt() throws {
        let command = try ShellCommand.check("ls").get()
        let script = URL(filePath: "/tmp/it's/run-1.command")
        let text = try TerminalScript.text(
            command: command, shell: "/bin/zsh", folder: URL(filePath: "/tmp/", directoryHint: .isDirectory),
            script: script)
        #expect(text == "#!/bin/zsh -l\n/bin/rm -f -- '/tmp/it'\\''s/run-1.command'\ncd '/tmp/' || exit 1\nls\n")
    }

    // MARK: Secrets

    /// Every file under a folder, as text.
    private func everyFile(under folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { item in
            guard let url = item as? URL else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func aHiddenCommandLeavesNoTraceInTheFeaturesFilesEvenAfterRunAgain() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("deployed\n"))
        await bench.start()
        try await bench.runFromRoot(">  TOKEN=s3cr3t-value deploy")
        try await bench.harness.perform("run-again")
        try await bench.runFromRoot("> make")
        #expect(try bench.storedHistory()?.entries.map(\.command) == ["make"])
        let data = bench.fakes.storage.dataDirectory(for: ShellFeature.featureID)
        let cache = bench.fakes.storage.cacheDirectory(for: ShellFeature.featureID)
        for text in everyFile(under: data) + everyFile(under: cache) {
            #expect(!text.contains("s3cr3t"))
        }
        #expect(bench.fakes.processes.runs.count == 3)
    }

    // MARK: Every action

    @Test func everyActionOnEveryKindOfRowRunsAndLeavesNoIssue() async throws {
        func fresh() async -> Bench {
            let bench = Bench()
            bench.fakes.processes.stub("/bin/zsh", output: .stdout("\(Color.red)ok\(Color.reset)\n"))
            return bench
        }

        // The ">" row in root search.
        let probe = await fresh()
        await probe.start()
        let row = try #require(try await probe.rootRow("> make"))
        #expect(probe.harness.rootActions(for: row).map(\.id) == ["run-in-shell", "copy-command", "open-in-terminal"])
        for id in probe.harness.rootActions(for: row).map(\.id) {
            let bench = await fresh()
            await bench.start()
            _ = try await bench.harness.performRoot(id, on: row)
            #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty, "root: \(id)")
        }

        // The page of a run that ended.
        let pageIDs = ["copy-output", "paste-output", "run-again", "copy-command", "open-in-terminal"]
        for id in pageIDs {
            let bench = await fresh()
            await bench.start()
            try await bench.harness.run("run", arguments: ["command": "make"])
            #expect(bench.harness.actions().map(\.id) == pageIDs)
            try await bench.harness.perform(id)
            #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty, "page: \(id)")
        }

        // A past command in Shell History.
        let historyIDs = ["use-again", "show-output", "copy-command", "delete", "clear-history"]
        for id in historyIDs {
            let bench = await fresh()
            await bench.start()
            try await bench.harness.run("run", arguments: ["command": "make"])
            try await bench.harness.run("history")
            try bench.harness.select(title: "make")
            #expect(bench.harness.actions().map(\.id) == historyIDs)
            try await bench.harness.perform(id)
            #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty, "history: \(id)")
        }

        // A command still running, in Shell History.
        for id in ["show-output", "stop", "copy-command"] {
            let processes = ScriptedProcesses()
            let bench = Bench(processes: processes)
            await bench.start()
            let run = try await bench.feature.board.start(try ShellCommand.check("sleep 9").get(), reporter: nil)
            await processes.waitForStart()
            try await bench.harness.run("history")
            try bench.harness.select(title: "sleep 9")
            #expect(bench.harness.actions().map(\.id) == ["show-output", "stop", "copy-command"])
            if id == "show-output" {
                // The page streams until the run ends, so end it once the page holds the run.
                let showing = Task { try await bench.harness.perform(id) }
                await run.output.waitUntilWatched()
                processes.exit(0)
                _ = try await showing.value
            } else {
                try await bench.harness.perform(id)
                run.stop()
            }
            await run.waitUntilEnded()
            #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty, "running: \(id)")
        }
    }

    // MARK: Options

    @Test func aCommandThatStartsWithAPlusIsRefusedAsAnOption() async throws {
        #expect(ShellCommand.check("+x").failure == .startsWithPlus)
        #expect(ShellCommand.check("  +o errexit").failure == .startsWithPlus)
        #expect(ShellCommand.check("echo +1").failure == nil)
        let bench = Bench()
        await bench.start()
        let row = try #require(try await bench.rootRow("> +x"))
        #expect(row.subtitle == "A shell would read it as an option.")
        #expect(bench.harness.rootActions(for: row).isEmpty)
        await #expect(
            throws: ActionFailure("Command Starts with a Plus Sign", message: "A shell would read it as an option.")
        ) {
            try await bench.harness.run("run", arguments: ["command": "+x"])
        }
        #expect(bench.fakes.processes.runs.isEmpty)
    }
}

extension Result {
    /// The failure, or nil on success.
    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
