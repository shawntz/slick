import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Root search", .timeLimit(.minutes(1)))
@MainActor
struct RootSearchTests {
    @Test func aPrefixedQueryShowsOneRowWithTheCommandInFullAndRunsNothing() async throws {
        let bench = Bench()
        await bench.start()
        let sections = try await bench.harness.asyncSections(for: "> git log --oneline -n 5")
        #expect(sections.map(\.title) == ["Shell"])
        let row = try #require(sections.first?.rows.first)
        #expect(sections.first?.rows.count == 1)
        #expect(row.title == "git log --oneline -n 5")
        #expect(row.subtitle == Strings.Root.runs)
        #expect(row.memory == .never, "root search never keeps the command")
        #expect(row.id == ItemID(ShellFeature.namespace, "typed"))
        #expect(bench.fakes.processes.runs.isEmpty, "nothing runs on a keystroke")
        #expect(bench.system.lookups == 0)
        #expect(try bench.storedHistory() == nil)
        let provider = bench.feature.provider
        #expect(provider.takesOver("> ls") && provider.debounce(for: "> ls") == .zero)
        #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty)
    }

    @Test func withoutThePrefixTheFeatureShowsOnlyItsCommandsByName() async throws {
        let bench = Bench()
        await bench.start()
        #expect(try await bench.harness.asyncSections(for: "git log").isEmpty)
        #expect(try await bench.harness.asyncSections(for: ">").first?.rows.map(\.title) == [Strings.Root.hintTitle])
        #expect(!bench.feature.provider.takesOver("git log"))
        #expect(bench.feature.provider.minimumQueryLength == Int.max, "root never sends it other queries")
        #expect(bench.feature.catalogSources.isEmpty)
        let shown = bench.feature.commands.filter(\.showsInRoot).map(\.title)
        #expect(shown == ["Run Shell Command", "Shell History"])
        let run = try bench.harness.command("run")
        #expect(run.arguments.map(\.name) == ["command"] && run.arguments.first?.isOptional == false)
        await #expect(throws: HarnessError.self) { try await bench.harness.run("run") }
    }

    @Test func returnHandsTheTextToRunShellCommandWhichRunsIt() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("hello\n"))
        await bench.start()
        let row = try #require(try await bench.rootRow("> echo hello"))
        let actions = bench.harness.rootActions(for: row)
        #expect(actions.map(\.id) == ["run-in-shell", "copy-command", "open-in-terminal"])
        #expect(actions.secondary?.id == "open-in-terminal", "Command-Return opens it in Terminal")
        try await bench.runFromRoot("> echo hello")
        let handOff = try #require(bench.harness.commandRuns.first)
        #expect(handOff.id == ShellFeature.runCommandID)
        #expect(handOff.arguments["command"] == "echo hello")
        let request = try #require(bench.fakes.processes.runs.first)
        #expect(request.arguments == ["-l", "-c", "echo hello"])
        #expect(bench.harness.detail?.body == .text("hello\n", monospaced: true))
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func withRunShellCommandTurnedOffReturnOnlyCopies() async throws {
        let bench = Bench()
        await bench.start()
        bench.harness.unavailableCommands = [ShellFeature.runCommandID]
        let row = try #require(try await bench.rootRow("> rm -rf build"))
        let actions = bench.harness.rootActions(for: row)
        #expect(actions.primary?.id == "copy-command")
        #expect(actions.secondary?.id == "open-in-terminal")
        try await bench.harness.perform(try #require(actions.primary), row: row, launch: .root)
        #expect(bench.fakes.processes.runs.isEmpty && bench.fakes.workspace.openedWith.isEmpty)
    }

    @Test func copyCommandCopiesWhatWasTyped() async throws {
        let bench = Bench()
        await bench.start()
        let row = try #require(try await bench.rootRow(">  ls -la  "))
        #expect(row.subtitle == Strings.Root.runsHidden, "a space before it keeps it out of history")
        try await bench.harness.performRoot("copy-command", on: row)
        #expect(bench.fakes.pasteboard.copiedTexts == ["ls -la"])
        #expect(bench.harness.huds.map(\.title) == ["Copied Command"])
        #expect(bench.fakes.processes.runs.isEmpty)
    }

    @Test func aCommandThatCannotRunSaysWhyAndOffersNothing() async throws {
        let bench = Bench()
        await bench.start()
        let hidden = try #require(try await bench.rootRow("> cat notes\u{202E}hs.txt"))
        #expect(hidden.title == "cat notes\u{FFFD}hs.txt", "the override shows, never applies")
        #expect(hidden.subtitle == Strings.Failures.message(.directionControl) && hidden.subtitleColor == .red)
        #expect(bench.harness.rootActions(for: hidden).isEmpty)
        let hyphen = try #require(try await bench.rootRow("> -rf"))
        #expect(hyphen.subtitle == Strings.Failures.message(.startsWithHyphen))
        let pasted = try #require(try await bench.rootRow("> " + String(repeating: "x", count: 40_000)))
        #expect(pasted.subtitle == Strings.Failures.message(.tooLong))
        #expect(pasted.title.count == 200, "only the start of a pasted page shows")
        #expect(bench.harness.rootActions(for: pasted).isEmpty)
        #expect(bench.fakes.processes.runs.isEmpty)
    }

    /// The prefix alone, or with nothing visible after it, shows a hint that runs nothing, so
    /// Return never opens a web search for ">".
    @Test func thePrefixWithNoCommandShowsAHintThatRunsNothing() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        for query in [">", "> ", ">\t", ">" + String(repeating: " ", count: 2000), ">\u{00A0}", "> \u{200B}\u{2060}"] {
            #expect(bench.feature.provider.takesOver(query), "\(query.utf8.count) bytes")
            let row = try #require(try await bench.rootRow(query))
            #expect(row.title == Strings.Root.hintTitle)
            #expect(row.subtitle == Strings.Root.hint)
            #expect(row.memory == .never)
            #expect(bench.harness.rootActions(for: row).isEmpty, "Return runs nothing")
        }
        #expect(bench.fakes.processes.runs.isEmpty)
    }
}
