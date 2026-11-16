import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Shell History", .timeLimit(.minutes(1)))
@MainActor
struct HistoryTests {
    @Test func aCommandThatEndedIsSavedWithItsTimeStatusAndRunTime() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let started = bench.fakes.clock.now
        let running = Task { try await bench.harness.run("run", arguments: ["command": "swift test  "]) }
        await processes.waitForStart()
        bench.fakes.clock.advance(by: .seconds(95))
        processes.exit(1)
        _ = try await running.value
        let entry = try #require(try bench.storedHistory()?.entries.first)
        #expect(entry.command == "swift test" && entry.exitStatus == 1 && !entry.stopped)
        #expect(entry.duration == 95 && abs(entry.date.timeIntervalSince(started)) < 0.001)

        try await bench.harness.run("history")
        let row = try #require(bench.harness.rows.first)
        #expect(row.title == "swift test")
        #expect(row.accessories == [.tag("Exit 1", color: .red), .text("1 min 35 s"), .date(started)])
        #expect(bench.harness.sections.map(\.title) == ["Today"])
        #expect(row.memory == .never)
        #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty)
    }

    @Test func returnPutsTheCommandBackInRootSearchAndRunsNothing() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("built\n"))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "make build"])
        try await bench.harness.run("history")
        #expect(
            bench.harness.actions().map(\.id) == [
                "use-again", "show-output", "copy-command", "delete", "clear-history",
            ])
        let outcome = try await bench.harness.performPrimary()
        #expect(outcome.kind == .showRoot(query: "> make build"))
        #expect(bench.fakes.processes.runs.count == 1, "a history row never runs at once")
        try await bench.runFromRoot(try #require(bench.harness.rootQueries.last))
        #expect(bench.fakes.processes.runs.count == 2, "the second Return runs it")
    }

    @Test func showOutputWorksWhileTheRunIsStillInMemory() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("\(Color.red)fail\(Color.reset)\n", exitCode: 1))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "make lint"])
        try await bench.harness.run("history")
        try await bench.harness.perform("show-output")
        #expect(bench.harness.detail?.body == .text("\(Color.red)fail\(Color.reset)\n", monospaced: true))
        #expect(bench.harness.detail?.metadata.contains(status: "Exited with status 1") == true)
        for index in 0..<RunBoard.keptEndedRuns {
            try await bench.harness.run("run", arguments: ["command": "echo \(index)"])
        }
        try await bench.harness.run("history")
        try bench.harness.select(title: "make lint")
        #expect(!bench.harness.actions().map(\.id).contains("show-output"), "only the last few keep their output")
    }

    @Test func aCommandTypedWithASpaceBeforeItIsNotSaved() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        try await bench.runFromRoot(">  export API_TOKEN=x; deploy")
        #expect(bench.fakes.processes.runs.first?.arguments.last == " export API_TOKEN=x; deploy")
        #expect(try bench.storedHistory() == nil)
        try await bench.harness.run("run", arguments: ["command": "\tcurl -H 'Authorization: x' example.test"])
        #expect(try bench.storedHistory() == nil)
        try await bench.harness.run("history")
        #expect(bench.harness.rows.isEmpty)
        #expect(bench.harness.page?.emptyState?.title == "No Shell History")
    }

    @Test func turningHistoryOffSavesNothingAndKeepsWhatIsSaved() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "ls"])
        bench.feature.context.settings[ShellSettings.keepsHistory] = false
        try await bench.harness.run("run", arguments: ["command": "pwd"])
        #expect(try bench.storedHistory()?.entries.map(\.command) == ["ls"])
        try await bench.harness.run("history")
        #expect(bench.harness.rows.map(\.title) == ["ls"])
        try await bench.harness.perform("clear-history")
        #expect(bench.harness.rows.isEmpty)
        #expect(bench.harness.page?.emptyState?.title == "Shell History Is Off")
    }

    @Test func theHistoryKeepsAtMost200AndOneEntryPerCommand() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        for index in 0..<205 {
            try await bench.harness.run("run", arguments: ["command": "echo \(index)"])
            bench.fakes.clock.advance(by: .seconds(1))
        }
        try await bench.harness.run("run", arguments: ["command": "echo 10"])
        let entries = try #require(try bench.storedHistory()?.entries)
        #expect(entries.count == 200)
        #expect(entries.first?.command == "echo 10")
        #expect(entries.filter { $0.command == "echo 10" }.count == 1, "the same command moves to the top")
        #expect(!entries.contains { $0.command == "echo 4" }, "the oldest went")
        #expect(entries.contains { $0.command == "echo 5" })
    }

    @Test func deleteRemovesOneAndClearAsksFirst() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        for command in ["ls", "pwd", "whoami"] {
            try await bench.harness.run("run", arguments: ["command": command])
        }
        try await bench.harness.run("history")
        try bench.harness.select(title: "pwd")
        let delete = try #require(bench.harness.actions().first { $0.id == "delete" })
        #expect(delete.shortcut == .remove && delete.style == .destructive && delete.confirmation == nil)
        try await bench.harness.perform("delete")
        #expect(bench.harness.rows.map(\.title) == ["whoami", "ls"])
        #expect(bench.harness.toasts.last?.title == "Deleted from History")
        #expect(try bench.storedHistory()?.entries.map(\.command) == ["whoami", "ls"])

        bench.harness.confirmationAnswer = false
        try await bench.harness.perform("clear-history")
        #expect(bench.harness.confirmations.last?.title == "Clear Shell History?")
        #expect(bench.harness.rows.count == 2)
        bench.harness.confirmationAnswer = true
        try await bench.harness.perform("clear-history")
        #expect(bench.harness.rows.isEmpty)
        #expect(try bench.storedHistory()?.entries == [])
    }

    @Test func runningCommandsComeFirstWithShowOutputAndStop() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        let run = try await bench.feature.board.start(try ShellCommand.check("npm run dev").get(), reporter: nil)
        await processes.waitForStart()
        try await bench.harness.run("history")
        #expect(bench.harness.sections.map(\.title) == ["Running"])
        let row = try #require(bench.harness.rows.first)
        #expect(row.title == "npm run dev" && row.accessories.first == .tag("Running", color: .blue))
        #expect(bench.harness.actions().map(\.id) == ["show-output", "stop", "copy-command"])
        try await bench.harness.perform("stop")
        await processes.waitForEndRequests(1)
        await run.waitUntilEnded()
        try await bench.harness.settle()
        try await bench.harness.reloadPage()
        #expect(bench.harness.sections.map(\.title) == ["Today"])
        #expect(bench.harness.rows.first?.accessories.first == .tag("Stopped"))
    }

    @Test func aNewerHistoryFileIsShownButNeverOverwritten() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        let json = """
            {"version": 2, "entries": [{"id": "6F1E8C55-6C37-4F4B-9E43-0C0D7B0C1E21", "command": "make",
             "date": "2026-11-14T09:00:00.000Z", "duration": 3, "exitStatus": 0, "stopped": false,
             "cwd": "/somewhere"}], "pinned": []}
            """
        try bench.writeHistory(json)
        await bench.start()
        #expect(bench.feature.status?.title == "Shell History Is Read Only")
        try await bench.harness.run("history")
        #expect(bench.harness.rows.map(\.title) == ["make"])
        try await bench.harness.run("run", arguments: ["command": "ls"])
        let url = bench.fakes.storage.dataDirectory(for: "shell").appending(path: ShellHistory.fileName)
        #expect(try String(contentsOf: url, encoding: .utf8) == json, "the newer file is left as it is")
        #expect(bench.feature.history.entries.map(\.command) == ["ls", "make"], "new commands show for the session")
    }

    @Test func aNewerFileWhoseEntriesDoNotReadIsKeptWhereItIs() async throws {
        let bench = Bench()
        let json = #"{"version": 9, "entries": {"shape": "changed"}}"#
        try bench.writeHistory(json)
        await bench.start()
        #expect(bench.feature.history.isReadOnly && bench.feature.history.entries.isEmpty)
        let folder = bench.fakes.storage.dataDirectory(for: "shell")
        #expect(try String(contentsOf: folder.appending(path: ShellHistory.fileName), encoding: .utf8) == json)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "history-damaged-1.json").path))
    }

    @Test func aDamagedFileIsSetAsideAndANewHistoryStarts() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        try bench.writeHistory("{ not json")
        await bench.start()
        #expect(bench.feature.status == nil && bench.feature.history.entries.isEmpty)
        let folder = bench.fakes.storage.dataDirectory(for: "shell")
        let aside = folder.appending(path: "history-damaged-1.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(try bench.storedHistory()?.entries.map(\.command) == ["ls"])
    }

    @Test func handEditedEntriesAreCleanedBeforeTheyShow() async throws {
        let bench = Bench()
        try bench.writeHistory(
            """
            {"version": 1, "entries": [
             {"id": "00000000-0000-0000-0000-000000000001", "command": "echo a\\nrm -rf x", "date": "2026-11-14T09:00:00Z"},
             {"id": "00000000-0000-0000-0000-000000000002", "command": "cat a\\u202Eb", "date": "2026-11-14T09:01:00Z"},
             {"id": "00000000-0000-0000-0000-000000000007", "command": "  ls  ", "date": "2026-11-14T09:02:00Z",
              "duration": -5},
             {"id": "00000000-0000-0000-0000-000000000003", "command": "pwd", "date": "2026-11-14T09:03:00Z"},
             {"id": "00000000-0000-0000-0000-000000000003", "command": "date", "date": "2026-11-14T07:00:00Z"},
             {"id": "00000000-0000-0000-0000-000000000004", "command": "ls", "date": "2026-11-14T08:00:00Z"},
             {"id": "00000000-0000-0000-0000-000000000005", "command": "\\u200B", "date": "2026-11-14T09:04:00Z"},
             {"id": "00000000-0000-0000-0000-000000000006", "command": "-x", "date": "2026-11-14T09:05:00Z"}
            ]}
            """)
        await bench.start()
        let entries = bench.feature.history.entries
        #expect(entries.map(\.command) == ["pwd", "ls"])
        #expect(entries.last?.duration == 0 && entries.last?.stopped == false && entries.last?.exitStatus == nil)
        try await bench.harness.run("history")
        try bench.harness.select(title: "ls")
        #expect(bench.harness.selectedRow?.accessories.first == .tag("Not Started", color: .red))
    }

    @Test func dayTitlesComeFromTheClock() async throws {
        let bench = Bench()
        try bench.writeHistory(
            """
            {"version": 1, "entries": [
             {"id": "00000000-0000-0000-0000-000000000001", "command": "today", "date": "2026-11-14T08:00:00Z"},
             {"id": "00000000-0000-0000-0000-000000000002", "command": "yesterday", "date": "2026-11-13T08:00:00Z"}
            ]}
            """)
        await bench.start()
        try await bench.harness.run("history")
        #expect(bench.harness.sections.map(\.title) == ["Today", "Yesterday"])
        try await bench.harness.setQuery("yest")
        #expect(bench.harness.rows.map(\.title) == ["yesterday"])
    }
}
