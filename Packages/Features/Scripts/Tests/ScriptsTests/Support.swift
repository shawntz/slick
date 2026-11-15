import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Scripts

/// Synthetic scripts. None of them ever runs: every process in these tests is a fake.
nonisolated enum Fixture {
    static let own = HeaderParser.ownPrefix
    static let raycast = HeaderParser.publicPrefix

    /// A script with a first line, a header and a body.
    static func script(
        _ mode: String = "compact", title: String = "Say Hello", prefix: String = raycast,
        shebang: String = "#!/bin/bash", extra: [String] = [], body: String = "echo hello"
    ) -> String {
        ([shebang, "# \(prefix)schemaVersion 1", "# \(prefix)title \(title)", "# \(prefix)mode \(mode)"]
            + extra.map { "# \(prefix)\($0)" } + ["", body]).joined(separator: "\n")
    }

    /// The script file a request runs: the first absolute path among its arguments.
    static func scriptName(_ request: ProcessRequest) -> String {
        request.arguments.first { $0.hasPrefix("/") }.map { URL(filePath: $0).lastPathComponent } ?? ""
    }

    /// The arguments after the script's path: `$1`, `$2` and `$3`.
    static func scriptArguments(_ request: ProcessRequest) -> [String] {
        guard let index = request.arguments.firstIndex(where: { $0.hasPrefix("/") }) else { return [] }
        return Array(request.arguments[(index + 1)...])
    }
}

extension FakeProcesses {
    /// Stubs `/bin/bash` so each script answers by its file name.
    nonisolated func stubScripts(_ outputs: [String: FakeProcessOutput]) {
        stub("/bin/bash") { request in
            outputs[Fixture.scriptName(request)]
                ?? .stderr("no fake for \(Fixture.scriptName(request))\n", exitCode: 127)
        }
    }

    /// Stubs `/bin/bash` with a handler that sees each request.
    nonisolated func stubScripts(_ handler: @escaping @Sendable (ProcessRequest) -> FakeProcessOutput) {
        stub("/bin/bash", handler: handler)
    }
}

/// A process service over ``FakeProcesses`` that can end a run with a ``ProcessError``, as the
/// live service does for a timeout, and that records each stream the consumer dropped, which is
/// when the live service ends the process.
nonisolated final class RecordingProcesses: ProcessService {
    private struct State {
        var endings: [String: ProcessError] = [:]
        var cancelled = 0
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    let base = FakeProcesses()
    private let state = Mutex(State())

    /// Ends every run of the script with this error after its output, instead of an exit.
    func end(_ scriptName: String, with error: ProcessError) {
        state.withLock { $0.endings[scriptName] = error }
    }

    /// How many streams the consumer dropped before they ended.
    var cancelledCount: Int { state.withLock { $0.cancelled } }

    /// Returns once consumers have dropped `count` streams in all.
    func waitForCancellations(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard state.cancelled < count else { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func recordCancellation() {
        let ready = state.withLock { state in
            state.cancelled += 1
            let ready = state.waiters.filter { $0.count <= state.cancelled }
            state.waiters.removeAll { $0.count <= state.cancelled }
            return ready.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let inner = base.stream(request)
        let ending = state.withLock { $0.endings[Fixture.scriptName(request)] }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ProcessEvent.self)
        let task = Task {
            do {
                for try await event in inner {
                    if case .exit = event, ending != nil { continue }
                    continuation.yield(event)
                }
                if let ending { throw ending }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            task.cancel()
            self?.recordCancellation()
        }
        return stream
    }
}

/// A feature over an in-memory script library and fake processes.
@MainActor
struct ScriptsBench {
    let fakes: FakeServices
    let library: any ScriptLibrary
    let harness: FeatureHarness<ScriptsFeature>
    let folder: URL

    /// - Parameters:
    ///   - files: Script text by file name, in the default folder.
    ///   - library: A library to use instead of an in-memory one with `files`.
    ///   - processes: A process service to use instead of the fakes' own.
    init(
        files: [String: String] = [:], library: (any ScriptLibrary)? = nil, processes: (any ProcessService)? = nil,
        fakes: FakeServices = FakeServices()
    ) {
        self.fakes = fakes
        let folder = ScriptsFeature.defaultFolder(FeatureStorage(featureID: "scripts", service: fakes.storage))
        self.folder = folder
        let library =
            library
            ?? MemoryScriptLibrary(
                files: Dictionary(uniqueKeysWithValues: files.map { (folder.appending(path: $0.key), $0.value) }))
        self.library = library
        fakes.override(ScriptLibraryKey.self, with: library)
        harness = FeatureHarness(fakes: fakes) { context in
            guard let processes else { return ScriptsFeature(context: context) }
            var services = fakes.services
            services.processes = processes
            return ScriptsFeature(
                context: FeatureContext(
                    featureID: context.featureID, environment: context.environment, services: services))
        }
    }

    var feature: ScriptsFeature { harness.feature }

    /// Activates the feature and waits for the first scan.
    func start() async {
        await harness.activate()
        await feature.scanned()
    }

    /// The command ID of a script in the default folder.
    func id(_ name: String) -> String {
        ScriptCatalog.commandID(for: folder.appending(path: name))
    }

    /// The script commands, without the four fixed ones.
    var scriptCommands: [Command] {
        feature.commands.filter { $0.id.hasPrefix("script.") }
    }
}
