import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

/// A command must not hide part of itself. The row is cut at its end and the one-line field shows
/// the end after a paste, so padding in the middle would hide a second command from both. Nothing
/// here starts a process: the bench's process service is a fake.
@Suite("Text a command could hide", .timeLimit(.minutes(1)))
@MainActor
struct HiddenTextTests {
    private func problem(_ text: String) -> ShellCommand.Problem? {
        if case .failure(let problem) = ShellCommand.check(text) { return problem }
        return nil
    }

    @Test func paddingInTheMiddleIsRefusedAndNothingRuns() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout("done\n"))
        await bench.start()
        let pad = String(repeating: " ", count: 300)
        let typed = "> brew install example-tool" + pad + "; echo hidden-part" + pad + "#"
        let row = try #require(try await bench.rootRow(typed))
        #expect(row.subtitle == Strings.Failures.message(.longSpace))
        #expect(bench.harness.rootActions(for: row).isEmpty, "a refused row offers nothing to run")
        #expect(bench.fakes.processes.runs.isEmpty)
        let refusal = ActionFailure(
            Strings.Failures.title(.longSpace), message: Strings.Failures.message(.longSpace))
        await #expect(throws: refusal, "the command refuses it too") {
            try await bench.harness.run(
                "run", arguments: bench.feature.handOff.arguments(for: String(typed.dropFirst(2))))
        }
        #expect(bench.fakes.processes.runs.isEmpty)
    }

    @Test func aRunOfMoreThanThreeSpacesOrTabsBetweenWordsIsRefused() {
        #expect(problem("ls    -la") == .longSpace)
        #expect(problem("ls\t\t\t\t-la") == .longSpace)
        #expect(problem("ls  \t\t -la") == .longSpace)
        #expect(problem("echo 'a    b'") == .longSpace, "inside quotes too: the row cannot tell")
    }

    @Test func shortRunsAndRunsAtEitherEndStay() throws {
        #expect(problem("ls   -la") == nil, "three spaces")
        #expect(problem("ls \t -la") == nil)
        let hidden = try ShellCommand.check("     export TOKEN=x").get()
        #expect(hidden.isHidden && hidden.trimmed == "export TOKEN=x", "a run before the command hides nothing")
        #expect(try ShellCommand.check("ls" + String(repeating: " ", count: 300)).get().trimmed == "ls")
    }

    @Test func charactersThatDrawAsBlanksOrAsNothingAreRefused() {
        let blanks: [Unicode.Scalar] = [
            "\u{2800}", "\u{3164}", "\u{115F}", "\u{1160}", "\u{FFA0}", "\u{200B}", "\u{2060}", "\u{00A0}",
            "\u{00AD}", "\u{FEFF}", "\u{2007}", "\u{202F}", "\u{3000}", "\u{180E}", "\u{E000}", "\u{E0020}",
        ]
        for blank in blanks {
            let text = "ls" + String(repeating: String(blank), count: 200) + "; echo hidden-part"
            #expect(problem(text) == .invisibleCharacter, "U+\(String(blank.value, radix: 16, uppercase: true))")
            #expect(problem("ls" + String(blank) + "x") == .invisibleCharacter)
        }
    }

    @Test func aCommandWithNothingVisibleIsStillEmpty() {
        #expect(problem("\u{00A0}") == .empty)
        #expect(problem("\u{200B}\u{FEFF}") == .empty)
        #expect(problem(" \u{2800} ") == .empty)
    }

    @Test func emojiSequencesStay() {
        #expect(problem("echo \u{2764}\u{FE0F}") == nil, "a heart with its emoji presentation selector")
        #expect(problem("echo \u{1F469}\u{200D}\u{1F4BB}") == nil, "a joined emoji")
        #expect(problem("echo \u{1F3F3}\u{FE0F}\u{200D}\u{1F308}") == nil)
        #expect(problem("echo 1\u{FE0F}\u{20E3}") == nil, "a keycap")
        #expect(problem("echo \u{200D}x") == .invisibleCharacter, "a joiner after a space joins nothing")
        #expect(problem("echo \u{2764}\u{FE0F}\u{FE0F}") == nil, "a selector after a selector draws nothing more")
        #expect(problem("echo a\u{FE0F}") == .invisibleCharacter, "a letter is not an emoji")
        #expect(problem("echo \u{FE0F}") == .invisibleCharacter)
    }

    @Test func historyDropsAnEntryThatHidesText() {
        func entry(_ command: String, _ second: Double) -> HistoryEntry {
            HistoryEntry(
                id: UUID(), command: command, date: Date(timeIntervalSince1970: 1_800_000_000 + second), duration: 1,
                exitStatus: 0, stopped: false)
        }
        let entries = [
            entry("ls" + String(repeating: " ", count: 40) + "; echo x", 3), entry("ls\u{2800}x", 2),
            entry("ls -la", 1),
        ]
        #expect(ShellHistory.cleaned(entries).map(\.command) == ["ls -la"])
    }

    @Test func eachNewProblemHasATitleAndASentence() {
        for problem in [ShellCommand.Problem.invisibleCharacter, .longSpace] {
            let title = Strings.Failures.title(problem)
            #expect(!title.isEmpty && !title.hasSuffix("."))
            #expect(Strings.Failures.message(problem).hasSuffix("."))
        }
        #expect(Strings.Failures.title(.invisibleCharacter) == "Command Has an Invisible Character")
        #expect(Strings.Failures.title(.longSpace) == "Command Has a Long Run of Spaces")
    }
}
