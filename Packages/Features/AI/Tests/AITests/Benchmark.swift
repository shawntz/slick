import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

/// Main-thread costs that run inside an interaction. Opt in with `AI_BENCHMARK=1`, in a release
/// build: `scripts/swiftpm.sh Packages/Features/AI test -c release -Xswiftc -enable-testing`.
@Suite(
    "Benchmarks", .timeLimit(.minutes(1)),
    .enabled(if: ProcessInfo.processInfo.environment["AI_BENCHMARK"] == "1"))
@MainActor
struct Benchmark {
    private static func report(_ name: String, _ samples: [Duration]) {
        let sorted = samples.sorted()
        func micros(_ duration: Duration) -> Double {
            Double(duration.components.attoseconds) / 1e12 + Double(duration.components.seconds) * 1e6
        }
        let p50 = micros(sorted[sorted.count / 2])
        let p99 = micros(sorted[min(sorted.count - 1, sorted.count * 99 / 100)])
        var load = [0.0, 0, 0]
        _ = getloadavg(&load, 3)
        print(
            "BENCH \(name): n=\(sorted.count) p50=\(String(format: "%.1f", p50))µs p99=\(String(format: "%.1f", p99))µs "
                + "load=\(String(format: "%.1f", load[0]))")
    }

    private static func measure(_ count: Int, _ body: () -> Void) -> [Duration] {
        let clock = ContinuousClock()
        return (0..<count).map { _ in clock.measure(body) }
    }

    @Test func actionsForALongAnswer() async throws {
        let ai = try await AIHarness()
        let paragraph = String(repeating: "word ", count: 40) + "\n\n```swift\nlet value = 1\n```\n\n"
        let answer = String(repeating: paragraph, count: 600)
        var conversation = ai.feature.services.newConversation()
        conversation.messages = [
            ChatMessage(role: .user, text: "q", date: ai.fakes.clock.now),
            ChatMessage(role: .assistant, text: answer, date: ai.fakes.clock.now),
        ]
        for mode in [AnswerMode.ask, .text(TextOutput(pasteTitle: "Replace Selection", pastesFirst: true))] {
            let session = AnswerSession(
                conversation: conversation, mode: mode, title: "Bench", services: ai.feature.services)
            let detail = Detail.markdown(answer)
            let samples = Self.measure(1_000) { _ = session.actions(for: detail) }
            Self.report("actions(for:) \(mode == .ask ? "ask" : "text") \(answer.utf8.count / 1024) KB", samples)
        }
        let samples = Self.measure(200) { _ = Transcript.lastCodeBlock(in: answer) }
        Self.report("lastCodeBlock \(answer.utf8.count / 1024) KB, off the main thread after Stop", samples)
    }

    /// What the main thread does with many of the user's own commands: the declarations the host
    /// reads after a change, and the universal actions it asks for each time the action panel
    /// opens on text.
    @Test func manyCustomCommands() async throws {
        for count in [500, 50_000] {
            let ai = try await AIHarness(activate: false)
            let commands = (0..<count).map { index in
                CustomCommand(
                    id: "custom.c-\(index)", title: "Command \(index)",
                    prompt: index.isMultiple(of: 2)
                        ? "Rewrite {selection} in a {argument name=\"style\"} way, number \(index)"
                        : "Tell me about {argument name=\"topic\"} on {date}, number \(index)",
                    replacesSelection: true)
            }
            let url = ai.harness.context.storage.dataFile(AIFeature.commandsFileName)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(CustomCommandFile(commands: commands)).write(to: url)
            await ai.harness.activate()
            await ai.feature.waitUntilLoaded()
            let runs = count > 1_000 ? 20 : 200
            Self.report("commands, \(count) custom", Self.measure(runs) { _ = ai.feature.commands })
            Self.report(
                "universal actions for text, \(count) custom",
                Self.measure(runs) {
                    _ = ai.feature.universalActions.flatMap { $0.actions(.text("hello")) }
                })
        }
    }

    @Test func anthropicEventsDecode() {
        let events = AnthropicSSE.answer(Array(repeating: "token ", count: 2_000)).map { chunk -> ServerSentEvent in
            var parser = ServerSentEventParser()
            var result: ServerSentEvent?
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                if let event = parser.feed(String(line)) { result = event }
            }
            return result ?? ServerSentEvent(data: "")
        }
        let samples = Self.measure(20) {
            var decoder = AnthropicStreamDecoder(modelName: "m")
            for event in events { _ = try? decoder.feed(event) }
        }
        Self.report("decode \(events.count) Anthropic events, off the main thread", samples)
    }
}
