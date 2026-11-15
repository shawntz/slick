import Foundation
import Kit
import KitTemplates
import KitTesting
import Synchronization
import Testing

@Suite("Test seams", .timeLimit(.minutes(1)))
struct TestSeamTests {
    @Test func aFeatureEnvironmentCanPinTheUUID() async {
        let fakes = FakeServices()
        let pinned = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
        let environment = TemplateEnvironment(context: fakes.context(featureID: "seams"), makeUUID: { pinned })
        let rendered = await Template("{uuid}").render(in: environment)
        #expect(rendered.text == pinned.uuidString)
    }

    @Test func aFeatureEnvironmentStillTakesItsSnippetsByTrailingClosure() async {
        let fakes = FakeServices()
        let environment = TemplateEnvironment(context: fakes.context(featureID: "seams")) { name in "<\(name)>" }
        #expect(await Template(#"{snippet name="sig"}"#).render(in: environment).text == "<sig>")
    }

    @Test func aTestCanWriteTheExpectedPaste() async throws {
        let pasteboard = FakePasteboard()
        try await pasteboard.paste(.text("Hello"), charactersAfterCursor: 2)
        #expect(pasteboard.pastes == [FakePasteboard.Paste(content: .text("Hello"), charactersAfterCursor: 2)])
        #expect(FakePasteboard.Paste(content: .text("Hi")).charactersAfterCursor == 0)
    }

    /// Counts requests and forwards them to the plain fake.
    nonisolated final class CountingProcesses: ProcessService {
        let base = FakeProcesses()
        private let count = Mutex(0)
        var requests: Int { count.withLock { $0 } }

        func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
            count.withLock { $0 += 1 }
            return base.stream(request)
        }
    }

    /// Runs a tool through its own context, as a feature that keeps services from `init` does, and
    /// through the action's context.
    final class Runner: Feature {
        static let manifest = FeatureManifest(id: "runner", name: "Runner", icon: .symbol("terminal"))
        nonisolated static let tool = URL(filePath: "/usr/bin/true")
        private let processes: any ProcessService

        init(context: FeatureContext) {
            processes = context.processes
        }

        var commands: [Command] {
            [
                Command(id: "own", title: "Run Own") { _ in
                    _ = try await self.processes.run(ProcessRequest(executable: Self.tool))
                    return .keepOpen
                },
                Command(id: "action", title: "Run Action") { context in
                    _ = try await context.processes.run(ProcessRequest(executable: Self.tool))
                    return .keepOpen
                },
            ]
        }
    }

    @Test func aTestCanSwapTheProcessServiceForTheFeatureAndItsActions() async throws {
        let fakes = FakeServices()
        let counting = CountingProcesses()
        counting.base.stub("true", output: .stdout(""))
        fakes.replaceProcesses(with: counting)
        let harness = FeatureHarness(Runner.self, fakes: fakes)
        try await harness.run("own")
        try await harness.run("action")
        #expect(counting.requests == 2)
        #expect(counting.base.runs.count == 2)
        #expect(fakes.processes.runs.isEmpty)
    }
}
