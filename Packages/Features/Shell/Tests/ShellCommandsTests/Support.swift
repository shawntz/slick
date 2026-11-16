import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import ShellCommands

/// A process service the test drives one event at a time, for slow output, Stop and a process that
/// ignores the request to end. It starts nothing.
///
/// Each run's stream stays open until the test sends an exit or a launch failure, or until the
/// consumer stops listening, which Kit's live service takes as the request to end. The double
/// records that request. A test plays a process that ignores it by sending more output and no exit.
nonisolated final class ScriptedProcesses: ProcessService {
    private struct Run {
        var request: ProcessRequest
        var continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
        var endRequested = false
    }

    private struct State {
        var runs: [Run] = []
        var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var endWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    /// Every request, in order.
    var requests: [ProcessRequest] { state.withLock { $0.runs.map(\.request) } }

    /// How many runs were asked to end, by their consumer going away.
    var endRequests: Int { state.withLock { $0.runs.filter(\.endRequested).count } }

    func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ProcessEvent.self)
        let (index, ready) = state.withLock { state in
            state.runs.append(Run(request: request, continuation: continuation))
            return (state.runs.count - 1, Self.take(&state.startWaiters, upTo: state.runs.count))
        }
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            self?.endRequested(index)
        }
        for waiter in ready { waiter.resume() }
        return stream
    }

    /// Writes to the run's standard output.
    func stdout(_ text: String, run: Int = 0) {
        continuation(run)?.yield(.stdout(Data(text.utf8)))
    }

    /// Writes raw bytes to the run's standard output.
    func stdout(bytes: [UInt8], run: Int = 0) {
        continuation(run)?.yield(.stdout(Data(bytes)))
    }

    /// Writes to the run's standard error.
    func stderr(_ text: String, run: Int = 0) {
        continuation(run)?.yield(.stderr(Data(text.utf8)))
    }

    /// Ends the run with an exit status.
    func exit(_ code: Int32, run: Int = 0) {
        let continuation = continuation(run)
        continuation?.yield(.exit(code))
        continuation?.finish()
    }

    /// Ends the run as a shell that could not start.
    func failToLaunch(_ reason: String, run: Int = 0) {
        continuation(run)?.finish(throwing: ProcessError.launchFailed(reason))
    }

    /// Returns once `count` runs have started.
    func waitForStart(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard state.runs.count < count else { return true }
                state.startWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Returns once `count` runs were asked to end.
    func waitForEndRequests(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard state.runs.filter(\.endRequested).count < count else { return true }
                state.endWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func continuation(_ run: Int) -> AsyncThrowingStream<ProcessEvent, any Error>.Continuation? {
        state.withLock { $0.runs.indices.contains(run) ? $0.runs[run].continuation : nil }
    }

    private func endRequested(_ index: Int) {
        let ready = state.withLock { state in
            state.runs[index].endRequested = true
            return Self.take(&state.endWaiters, upTo: state.runs.filter(\.endRequested).count)
        }
        for waiter in ready { waiter.resume() }
    }

    private static func take(
        _ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)], upTo count: Int
    ) -> [CheckedContinuation<Void, Never>] {
        let ready = waiters.filter { $0.count <= count }.map(\.continuation)
        waiters.removeAll { $0.count <= count }
        return ready
    }
}

/// Shell lookups the test sets.
nonisolated final class TestShellSystem: ShellSystem {
    private struct State {
        var loginShell: String? = "/bin/zsh"
        var accountName: String? = "example"
        var accountShell: String? = "/bin/zsh"
        var appEnvironment: [String: String] = [:]
        var missingFolders: Set<String> = []
        var missingPrograms: Set<String> = []
        var lookups = 0
    }

    private let state = Mutex(State())

    var login: String? {
        get { state.withLock { $0.loginShell } }
        set { state.withLock { $0.loginShell = newValue } }
    }

    /// The app's own environment, which a command may take `SSH_AUTH_SOCK` from.
    var appEnvironment: [String: String] {
        get { state.withLock { $0.appEnvironment } }
        set { state.withLock { $0.appEnvironment = newValue } }
    }

    /// The account record's name and login shell.
    func setAccount(name: String?, shell: String?) {
        state.withLock { state in
            state.accountName = name
            state.accountShell = shell
        }
    }

    /// How many times anything was looked up.
    var lookups: Int { state.withLock { $0.lookups } }

    func removeFolder(_ path: String) {
        state.withLock { _ = $0.missingFolders.insert(path) }
    }

    func removeProgram(_ path: String) {
        state.withLock { _ = $0.missingPrograms.insert(path) }
    }

    @concurrent func loginShell() async -> String? {
        state.withLock { state in
            state.lookups += 1
            return state.loginShell
        }
    }

    @concurrent func isFolder(_ path: String) async -> Bool {
        state.withLock { state in
            state.lookups += 1
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            return !state.missingFolders.contains(trimmed)
        }
    }

    @concurrent func isProgram(_ path: String) async -> Bool {
        state.withLock { state in
            state.lookups += 1
            return !state.missingPrograms.contains(path)
        }
    }

    /// The live rule over the account and the environment the test set.
    @concurrent func environment() async -> [String: String] {
        state.withLock { state in
            state.lookups += 1
            return ShellEnvironment.entries(
                accountName: state.accountName, accountShell: state.accountShell,
                appEnvironment: state.appEnvironment)
        }
    }
}

/// The feature over fakes, with its process service and shell lookups replaced by test doubles.
@MainActor
struct Bench {
    let fakes: FakeServices
    let system: TestShellSystem
    let harness: FeatureHarness<ShellFeature>

    /// - Parameter processes: The process service commands run through. Defaults to the fakes' own
    ///   ``FakeProcesses``.
    init(processes: (any ProcessService)? = nil, fakes: FakeServices = FakeServices()) {
        self.fakes = fakes
        system = TestShellSystem()
        fakes.override(ShellProcessesKey.self, with: processes ?? fakes.processes)
        fakes.override(ShellSystemKey.self, with: system)
        harness = FeatureHarness(fakes: fakes)
    }

    var feature: ShellFeature { harness.feature }

    /// The title of the top page when it is a detail page.
    var pageTitle: String? {
        guard case .detail(let page) = harness.page?.page else { return nil }
        return page.title
    }
    var home: URL { fakes.storage.homeDirectory }

    /// Activates the feature and waits for the history.
    func start() async {
        await harness.activate()
        await feature.waitUntilReady()
    }

    /// The row root search shows for a query, if the provider takes it over.
    func rootRow(_ query: String) async throws -> Row? {
        try await harness.asyncSections(for: query).first?.rows.first
    }

    /// Presses Return on the row root search shows for a query.
    @discardableResult
    func runFromRoot(_ query: String) async throws -> ActionOutcome {
        let row = try #require(try await rootRow(query))
        let primary = try #require(harness.rootActions(for: row).primary)
        return try await harness.perform(primary, row: row, query: query, launch: .root)
    }

    /// The history file's contents.
    func storedHistory() throws -> HistoryFile? {
        let url = fakes.storage.dataDirectory(for: ShellFeature.featureID).appending(path: ShellHistory.fileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractions
        return try decoder.decode(HistoryFile.self, from: Data(contentsOf: url))
    }

    /// Writes a history file as another version or a person might.
    func writeHistory(_ json: String) throws {
        let folder = fakes.storage.dataDirectory(for: ShellFeature.featureID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: ShellHistory.fileName))
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// ISO 8601 dates with or without fractional seconds, as `JSONFileStore` writes them.
    nonisolated static var iso8601WithFractions: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            return try Date(text, strategy: .iso8601)
        }
    }
}

/// ANSI sequences for tests.
nonisolated enum Color {
    static let red = "\u{1B}[31m"
    static let reset = "\u{1B}[0m"
}
