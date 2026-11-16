import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

/// The page's stream one update at a time, as the host reads it, against a process the test drives.
@Suite("Streaming and stopping", .timeLimit(.minutes(1)))
@MainActor
struct StreamingTests {
    /// A run started as Run Shell Command starts it, with a page on it, and the page's updates.
    private struct Watched {
        let bench: Bench
        let processes: ScriptedProcesses
        let run: ShellRun
        let page: RunPage
        /// The page's stream, attached when the run started. Read it with a local iterator.
        let stream: AsyncThrowingStream<DetailUpdate, any Error>

        static func start(_ command: String = "make") async throws -> Watched {
            let processes = ScriptedProcesses()
            let bench = Bench(processes: processes)
            await bench.start()
            let reporter = ActionContext(feature: bench.harness.context, host: bench.harness, launch: .root)
            let run = try await bench.feature.board.start(try ShellCommand.check(command).get(), reporter: reporter)
            let page = RunPage(run: run, board: bench.feature.board, handOff: bench.feature.handOff)
            let stream = page.start()
            await processes.waitForStart()
            return Watched(bench: bench, processes: processes, run: run, page: page, stream: stream)
        }
    }

    @Test func slowOutputArrivesAsItComesInArrivalOrder() async throws {
        let watched = try await Watched.start()
        var updates = watched.stream.makeAsyncIterator()
        let first = try #require(try await updates.next())
        guard case .replace(let detail) = first else {
            Issue.record("expected the detail first")
            return
        }
        #expect(detail.body == .text("", monospaced: true))
        #expect(detail.metadata.contains(status: "Running"))
        #expect(!detail.metadata.contains { if case .label("Run time", _, _) = $0 { true } else { false } })

        watched.processes.stdout("step 1\n")
        #expect(try await updates.next() == .append("step 1\n"))
        watched.processes.stderr("warning\n")
        #expect(try await updates.next() == .append("warning\n"))
        // "é" split across two chunks arrives whole.
        watched.processes.stdout(bytes: [0x63, 0x61, 0x66, 0xC3])
        #expect(try await updates.next() == .append("caf"))
        watched.processes.stdout(bytes: [0xA9, 0x0A])
        #expect(try await updates.next() == .append("é\n"))
        #expect(watched.page.actions(for: Detail()).map(\.id).contains("stop"))

        watched.bench.fakes.clock.advance(by: .seconds(3))
        watched.processes.exit(0)
        let ending = try #require(try await updates.next())
        guard case .metadata(let metadata) = ending else {
            Issue.record("expected the final metadata")
            return
        }
        #expect(metadata.contains(status: "Exited with status 0") && metadata.hasLabel("Run time", "3.0 s"))
        #expect(try await updates.next() == nil)
        #expect(watched.run.output.text == "step 1\nwarning\ncafé\n")
        #expect(watched.page.actions(for: Detail()).map(\.id).contains("run-again"))
    }

    @Test func stopAsksTheProcessToEndAndThePageSaysStopped() async throws {
        let watched = try await Watched.start("tail -f server.log")
        var updates = watched.stream.makeAsyncIterator()
        _ = try await updates.next()
        watched.processes.stdout("listening\n")
        _ = try await updates.next()
        let stop = try #require(watched.page.actions(for: Detail()).first { $0.id == "stop" })
        #expect(stop.shortcut == KeyCombo(.c, .control))
        guard case .run(let handler) = stop.kind else {
            Issue.record("Stop is not a handler")
            return
        }
        let context = ActionContext(feature: watched.bench.harness.context, host: watched.bench.harness, launch: .page)
        #expect(try await handler(context).kind == .keepOpen)

        await watched.processes.waitForEndRequests(1)
        #expect(watched.processes.endRequests == 1, "the reader stopped listening: SIGTERM to the group, then SIGKILL")
        let ending = try #require(try await updates.next())
        guard case .metadata(let metadata) = ending else {
            Issue.record("expected the final metadata")
            return
        }
        #expect(metadata.contains(status: "Stopped"))
        #expect(try await updates.next() == nil)
        await watched.run.waitUntilEnded()
        #expect(watched.run.ending == .stopped)
        #expect(watched.page.actions(for: Detail()).map(\.id).contains("run-again"))
        #expect(watched.bench.harness.huds.isEmpty && watched.bench.harness.toasts.isEmpty, "a stop is not reported")
        let entry = try #require(try watched.bench.storedHistory()?.entries.first)
        #expect(entry.stopped && entry.exitStatus == nil && entry.command == "tail -f server.log")
    }

    @Test func aProcessThatIgnoresTheRequestToEndCannotHoldThePage() async throws {
        let watched = try await Watched.start("trap '' TERM; while true; do date; sleep 1; done")
        var updates = watched.stream.makeAsyncIterator()
        _ = try await updates.next()
        watched.run.stop()
        await watched.processes.waitForEndRequests(1)
        // The process ignores SIGTERM and keeps printing; it never exits by itself.
        watched.processes.stdout("still here\n")
        watched.processes.stdout("and here\n")
        let ending = try #require(try await updates.next())
        #expect(ending != .append("still here\n"))
        #expect(try await updates.next() == nil, "the page ends without waiting for the process")
        await watched.run.waitUntilEnded()
        #expect(watched.run.ending == .stopped)
        #expect(!watched.run.output.text.contains("still here"))
        #expect(watched.bench.feature.board.running.isEmpty)
    }

    @Test func leavingThePageLeavesTheRunGoingAndAPageCanComeBack() async throws {
        let watched = try await Watched.start("npm run build")
        let output = watched.run.output
        // The host drops the page's stream when the user leaves the page.
        let reader = Task { [page = watched.page] in
            for try await _ in page.start() {}
        }
        // Two streams were attached: the one the test holds and the reader's.
        reader.cancel()
        _ = await reader.result
        #expect(output.watcherCount == 1, "the left page let go; the run is still read")
        watched.processes.stdout("bundling\n")
        watched.processes.stdout("done\n")
        #expect(watched.processes.endRequests == 0, "leaving a page never stops the run")

        let again = RunPage(
            run: watched.run, board: watched.bench.feature.board, handOff: watched.bench.feature.handOff)
        var updates = again.start().makeAsyncIterator()
        // A page that comes back first shows everything so far, then what follows.
        var shown = Detail()
        while !(shown.body == .text("bundling\ndone\n", monospaced: true)) {
            guard let update = try await updates.next() else { break }
            shown.apply(update)
        }
        #expect(shown.body == .text("bundling\ndone\n", monospaced: true))
        watched.processes.exit(0)
        while let update = try await updates.next() { shown.apply(update) }
        #expect(shown.metadata.contains(status: "Exited with status 0"))
    }

    @Test func closingThePanelLeavesTheRunGoingAndAHUDSaysHowItEnded() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let running = Task { try await bench.harness.run("run", arguments: ["command": "make test"]) }
        await processes.waitForStart()
        let run = try #require(bench.feature.board.running.first)
        await run.output.waitUntilWatched()
        processes.stdout("ok 1\n")
        bench.harness.closePanel()
        #expect(processes.endRequests == 0, "closing the panel never stops the run")
        processes.stdout("not ok 2\n")
        processes.exit(2)
        _ = try await running.value
        #expect(bench.harness.huds == [.failure("Shell Command Exited with Status 2")])
        #expect(bench.harness.detail?.body == .text("ok 1\nnot ok 2\n", monospaced: true))
    }

    @Test func aRunThatEndsInFrontOfTheUserReportsNothing() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let running = Task { try await bench.harness.run("run", arguments: ["command": "make"]) }
        await processes.waitForStart()
        await (try #require(bench.feature.board.running.first)).output.waitUntilWatched()
        processes.exit(0)
        _ = try await running.value
        #expect(bench.harness.huds.isEmpty && bench.harness.toasts.isEmpty)
    }

    @Test func aRunWhosePageWasLeftReportsWithAToastThatShowsTheOutput() async throws {
        let watched = try await Watched.start("brew upgrade")
        let reader = Task { [page = watched.page] in
            for try await _ in page.start() {}
        }
        reader.cancel()
        _ = await reader.result
        // The page the test holds counts as left too: the panel closed and opened on another page.
        watched.page.panelDidClose()
        watched.processes.stdout("upgraded 3 packages\n")
        watched.processes.exit(0)
        await watched.run.waitUntilEnded()
        let toast = try #require(watched.bench.harness.visibleToast)
        #expect(toast.title == "Shell Command Finished" && toast.style == .success)
        #expect(toast.action?.title == "Show Output")
        let outcome = try await watched.bench.harness.performToastAction()
        #expect(outcome.kind == .push)
        #expect(watched.bench.harness.detail?.body == .text("upgraded 3 packages\n", monospaced: true))
        #expect(watched.bench.harness.detail?.metadata.contains(status: "Exited with status 0") == true)
    }

    @Test func aShellThatCannotStartIsReportedWhenNobodyWatches() async throws {
        let watched = try await Watched.start()
        watched.page.panelDidClose()
        watched.bench.harness.closePanel()
        watched.processes.failToLaunch("zsh: no such file")
        await watched.run.waitUntilEnded()
        #expect(watched.bench.harness.huds == [.failure("Shell Command Could Not Start")])
        #expect(watched.run.ending == .couldNotStart("zsh: no such file"))
    }

    @Test func turningTheFeatureOffStopsEveryRun() async throws {
        let watched = try await Watched.start("sleep 600")
        await watched.bench.harness.deactivate()
        await watched.processes.waitForEndRequests(1)
        await watched.run.waitUntilEnded()
        #expect(watched.run.ending == .stopped)
        #expect(watched.bench.feature.board.running.isEmpty)
    }

    @Test func twoRunsGoOnSideBySide() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let board = bench.feature.board
        let first = try await board.start(try ShellCommand.check("sleep 5").get(), reporter: nil)
        let second = try await board.start(try ShellCommand.check("sleep 9").get(), reporter: nil)
        await processes.waitForStart(2)
        #expect(board.running.map(\.command.trimmed) == ["sleep 9", "sleep 5"])
        processes.exit(0, run: 1)
        await second.waitUntilEnded()
        #expect(board.running.map(\.id) == [first.id])
        processes.exit(0, run: 0)
        await first.waitUntilEnded()
        #expect(board.running.isEmpty && board.recent.map(\.id) == [first.id, second.id])
    }
}
