import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Output limit", .timeLimit(.minutes(1)))
@MainActor
struct OutputLimitTests {
    @Test func outputUnderTheLimitAppends() {
        var buffer = OutputBuffer(limit: 100)
        #expect(buffer.append("one\n") == .appended)
        #expect(buffer.append("two\n") == .appended)
        #expect(buffer.text == "one\ntwo\n" && buffer.count == 8 && buffer.dropped == 0)
    }

    @Test func pastTheLimitTheStartIsDroppedAfterALineBreak() {
        var buffer = OutputBuffer(limit: 100)
        for line in 0..<30 {
            _ = buffer.append("line \(line)\n")
        }
        #expect(buffer.count <= 100 && buffer.count >= 50)
        #expect(buffer.text.hasSuffix("line 29\n"))
        #expect(buffer.text.hasPrefix("line "), "the kept text starts on a line of its own")
        #expect(buffer.count == buffer.text.utf8.count)
        #expect(buffer.dropped + buffer.count == (0..<30).map { "line \($0)\n".utf8.count }.reduce(0, +))
    }

    @Test func withoutLineBreaksTheCutKeepsCharactersWhole() {
        var buffer = OutputBuffer(limit: 64)
        let text = String(repeating: "é日👍", count: 40)
        #expect(buffer.append(text) == .trimmed)
        #expect(buffer.count <= 64)
        #expect(buffer.count == buffer.text.utf8.count)
        #expect(!buffer.text.unicodeScalars.contains("\u{FFFD}"), "no character was cut in half")
        #expect(text.hasSuffix(buffer.text))
    }

    @Test func manyAppendsNeverHoldMoreThanTheLimit() {
        var buffer = OutputBuffer(limit: 1000)
        var trims = 0
        for index in 0..<5000 {
            if buffer.append("\(index) \(String(repeating: "x", count: index % 40))\n") == .trimmed { trims += 1 }
            #expect(buffer.count <= 1000)
        }
        #expect(trims > 0 && trims < 5000 / 4, "the page is replaced once per quarter of the limit, not per chunk")
    }

    @Test func aPagePastTheLimitKeepsTheNewestOutputAndSaysItDroppedTheStart() async throws {
        let processes = ScriptedProcesses()
        let bench = Bench(processes: processes)
        await bench.start()
        bench.feature.context.settings[ShellSettings.outputLimit] = .halfMegabyte
        let run = try await bench.feature.board.start(try ShellCommand.check("yes").get(), reporter: nil)
        let page = RunPage(run: run, board: bench.feature.board, handOff: bench.feature.handOff)
        var updates = page.start().makeAsyncIterator()
        await processes.waitForStart()
        var shown = Detail()
        shown.apply(try #require(try await updates.next()))

        let line = String(repeating: "y", count: 99) + "\n"
        let lines = 6000
        for _ in 0..<lines {
            processes.stdout(line)
        }
        processes.stdout("the end\n")
        processes.exit(0)
        while let update = try await updates.next() {
            shown.apply(update)
        }
        guard case .text(let text, true) = shown.body else {
            Issue.record("expected monospaced text")
            return
        }
        let limit = OutputLimit.halfMegabyte.bytes
        #expect(text.utf8.count <= limit && text.utf8.count >= limit / 2)
        #expect(text.hasSuffix(line + "the end\n"))
        #expect(text.hasPrefix(line), "the kept text starts at a line")
        #expect(shown.metadata.hasLabel("Output", "The start was dropped. This page keeps the last 512 KB."))
        #expect(run.output.droppedBytes + text.utf8.count == lines * 100 + 8)

        let copy = try #require(page.actions(for: shown).first { $0.id == "copy-output" })
        try await bench.harness.perform(copy, row: nil)
        #expect(bench.fakes.pasteboard.copiedTexts == [text], "Copy Output copies what the page keeps")
    }

    @Test func eachLimitHasATitle() {
        #expect(
            OutputLimit.allCases.map(Strings.Settings.outputLimitOption) == ["512 KB", "1 MB", "2 MB", "8 MB", "32 MB"])
        #expect(ShellSettings.outputLimit.defaultValue == .twoMegabytes && OutputLimit.twoMegabytes.bytes == 2_097_152)
    }
}
