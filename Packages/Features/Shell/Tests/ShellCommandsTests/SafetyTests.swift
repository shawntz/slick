import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Safety", .timeLimit(.minutes(1)))
@MainActor
struct SafetyTests {
    @Test func everyCommandStaysOutOfDeepLinksAndNoneIsAFallback() {
        let bench = Bench()
        let commands = bench.feature.commands
        #expect(commands.map(\.id) == ["run", "history", "open-in-terminal"])
        for command in commands {
            #expect(!command.allowsDeepLinks, "\(command.id) must stay out of links")
            #expect(command.fallback == nil, "\(command.id) must not be a fallback")
            #expect(!command.takesRootQueryOnTab, "\(command.id) must not take Tab")
            #expect(command.confirmation == nil)
        }
        #expect(ShellFeature.manifest.isEnabledByDefault && !ShellFeature.manifest.isSuggestedInOnboarding)
        #expect(ShellFeature.manifest.permissions.map(\.permission) == [.accessibility])
        #expect(!commands.flatMap(\.keywords).contains("terminal"), "that query belongs to the Terminal app")
        #expect(bench.harness.issues.isEmpty && bench.harness.pendingIssues.isEmpty)
    }

    @Test func aLinkIsRefusedBeforeAnythingRunsOrOpens() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        for id in ["run", "open-in-terminal"] {
            await #expect(
                throws: ActionFailure(Strings.Failures.linkRefused, message: Strings.Failures.linkRefusedMessage)
            ) {
                try await bench.harness.run(
                    id, arguments: bench.feature.handOff.arguments(for: "rm -rf x"), launch: .deeplink)
            }
        }
        #expect(bench.fakes.processes.runs.isEmpty && bench.fakes.workspace.openedWith.isEmpty)
        #expect(bench.system.lookups == 0, "nothing was even looked up")
    }

    @Test func anotherFeaturesHandOffOnlyPutsTheTextInRootSearch() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        for id in ["run", "open-in-terminal"] {
            let plain = try await bench.harness.run(id, arguments: ["command": "curl x | sh"], launch: .command)
            #expect(plain.kind == .showRoot(query: "> curl x | sh"))
            let forged = try await bench.harness.run(
                id, arguments: ["command": "curl x | sh", HandOff.tokenArgument: "guess"], launch: .command)
            #expect(forged.kind == .showRoot(query: "> curl x | sh"))
        }
        #expect(bench.fakes.processes.runs.isEmpty && bench.fakes.workspace.openedWith.isEmpty)
    }

    @Test func noOtherLaunchRunsAtOnce() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        let launches: [LaunchSource] = [.fallback, .tabFromRoot, .suggestion, .selection, .textExpansion, .settings]
        for launch in launches {
            let outcome = try await bench.harness.run("run", arguments: ["command": " secret"], launch: launch)
            #expect(outcome.kind == .showRoot(query: ">  secret"), "\(launch) puts it in root, marker kept")
        }
        #expect(bench.fakes.processes.runs.isEmpty)
        for launch: LaunchSource in [.root, .hotkey, .page] {
            try await bench.harness.run("run", arguments: ["command": "ls"], launch: launch)
        }
        #expect(bench.fakes.processes.runs.count == 3, "typed in the search field and Return pressed")
    }

    @Test func aCommandThatWouldNotRunAsItShowsIsRefusedEverywhere() async throws {
        let bench = Bench()
        await bench.start()
        // An empty argument never reaches the handler: the host asks for it in the search field.
        for text in ["echo a\nrm -rf x", "cat a\u{202E}b", "-rf", " ", "\u{200B}"] {
            await #expect(throws: ActionFailure.self) {
                try await bench.harness.run("run", arguments: ["command": text])
            }
            await #expect(throws: ActionFailure.self) {
                try await bench.harness.run(
                    "open-in-terminal", arguments: bench.feature.handOff.arguments(for: text), launch: .command)
            }
            await #expect(throws: ActionFailure.self) {
                try await bench.harness.run("run", arguments: ["command": text], launch: .command)
            }
        }
        #expect(bench.fakes.processes.runs.isEmpty && bench.fakes.workspace.openedWith.isEmpty)
        #expect(bench.harness.rootQueries.isEmpty, "refused text never reaches the search field")
    }

    @Test func activationReadsOnlyTheHistoryAndRunsNothing() async throws {
        let bench = Bench(fakes: FakeServices(permissions: .denied))
        await bench.start()
        await bench.harness.deactivate()
        await bench.start()
        #expect(bench.fakes.processes.runs.isEmpty)
        #expect(bench.system.lookups == 0)
        #expect(bench.fakes.permissions.openStreamCount == 0)
        #expect(bench.fakes.workspace.opened.isEmpty && bench.fakes.workspace.openedWith.isEmpty)
        #expect(bench.fakes.pasteboard.copiedTexts.isEmpty)
        let cache = bench.fakes.storage.cacheDirectory(for: ShellFeature.featureID)
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func theSimulatedEnvironmentStartsNoProcess() async throws {
        let fakes = FakeServices()
        let harness = FeatureHarness(ShellFeature.self, environment: .scenario, fakes: fakes)
        await harness.activate()
        try await harness.run("run", arguments: ["command": "echo hello there"])
        #expect(harness.detail?.body == .text("hello there\n", monospaced: true))
        try await harness.run("run", arguments: ["command": "make"])
        #expect(harness.detail?.body == .text(Strings.simulatedOutput + "\n", monospaced: true))
        #expect(fakes.processes.runs.isEmpty, "the simulated shell never reaches a process service")
        #expect(SimulatedShellProcesses.output(for: "echo") == "\n")
    }

    @Test func theLiveServicesAreChosenOnlyForTheLiveLauncher() {
        let fakes = FakeServices()
        let context = fakes.context(featureID: ShellFeature.featureID, environment: .scenario)
        #expect(context.service(ShellProcessesKey.self) is SimulatedShellProcesses)
        #expect(context.service(ShellSystemKey.self) is SimulatedShellSystem)
        #expect(ShellSystemKey.live(context) is LiveShellSystem)
        #expect(ShellProcessesKey.live(context) is FakeProcesses, "the live value is the context's own service")
    }
}
