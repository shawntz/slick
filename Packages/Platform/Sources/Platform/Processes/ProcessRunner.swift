import Foundation
import Kit
import Synchronization

/// The live process service.
///
/// Each run starts on a background queue, never on the caller's thread, with `posix_spawn(2)` in a
/// process group of its own; see ``Spawn``. Output streams in chunks as it arrives. The stream ends
/// with ``ProcessEvent/exit(_:)`` once the process has exited and both output pipes are drained. A
/// process killed by a signal reports 128 plus the signal number, as a shell does.
///
/// Cancelling the consumer, or reaching the timeout, stops the whole group: SIGTERM, then SIGKILL
/// once the leader has exited or ``killGrace`` has passed. So stopping `a | b` or `a && b` ends `a`
/// and `b` too. A process that ends by itself gets no signal, and a child it left in the
/// background keeps running; once the process exited the stream waits at most ``drainGrace`` for
/// such a child to close the output pipes. Every signal goes through ``ProcessGroups``, which only
/// lets one reach a group whose leader this runner has not reaped.
nonisolated public final class ProcessRunner: ProcessService {
    /// The clean environment every run starts from. ``ProcessRequest/environment`` entries replace
    /// its values.
    public let baseEnvironment: [String: String]
    /// How long a process may take to exit after SIGTERM before its group gets SIGKILL.
    public let killGrace: Duration
    /// How long the stream waits for the output pipes to close after the process exited.
    public let drainGrace: Duration

    /// The groups this runner started and has not reaped.
    let groups: ProcessGroups
    /// The pipe ends and runs this runner holds now, so a test can see that every one goes away.
    let books = RunBooks()
    private let children = Mutex<[pid_t: ChildProcess]>([:])
    private let launcher = DispatchQueue(label: "platform.processes.launch", qos: .userInitiated)

    /// - Parameters:
    ///   - baseEnvironment: The clean environment. Defaults to ``cleanEnvironment(home:inherited:)``
    ///     with the real home folder; the app passes the run environment's home.
    public convenience init(
        baseEnvironment: [String: String] = ProcessRunner.cleanEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser),
        killGrace: Duration = .seconds(2),
        drainGrace: Duration = .milliseconds(500)
    ) {
        self.init(
            baseEnvironment: baseEnvironment, killGrace: killGrace, drainGrace: drainGrace, groups: ProcessGroups())
    }

    /// A runner whose signals go through `groups`, which tests make with a recorder.
    init(baseEnvironment: [String: String], killGrace: Duration, drainGrace: Duration, groups: ProcessGroups) {
        self.baseEnvironment = baseEnvironment
        self.killGrace = killGrace
        self.drainGrace = drainGrace
        self.groups = groups
    }

    /// The environment Kit promises a script: only `PATH`, `HOME`, `LANG` and `TMPDIR`. `PATH` is
    /// the system default. `LANG` and `TMPDIR` come from `inherited` when set there.
    public static func cleanEnvironment(
        home: URL, inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path(percentEncoded: false),
            "LANG": inherited["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8",
            "TMPDIR": inherited["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(),
        ]
    }

    /// The environment a request runs with: the clean one with the request's entries on top.
    public func environment(for request: ProcessRequest) -> [String: String] {
        baseEnvironment.merging(request.environment) { _, requested in requested }
    }

    /// How many processes this runner has started and not reaped yet.
    public var runningCount: Int {
        children.withLock { $0.count }
    }

    public func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ProcessEvent.self)
        let run = ProcessRun(
            request: request, environment: environment(for: request), continuation: continuation,
            killGrace: killGrace, drainGrace: drainGrace, groups: groups, books: books,
            track: { [weak self] child in _ = self?.children.withLock { $0[child.pid] = child } },
            untrack: { [weak self] pid in _ = self?.children.withLock { $0.removeValue(forKey: pid) } })
        continuation.onTermination = { termination in
            if case .cancelled = termination { run.cancel() }
        }
        launcher.async { run.start() }
        return stream
    }

    /// Stops every process this runner started and has not reaped, as a cancel does, but with
    /// `grace` in place of ``killGrace``: SIGTERM to each group, then a wait until every leader has
    /// exited or `grace` has passed, then SIGKILL to each group. Blocks the caller for `grace` at
    /// most, so the app calls it with a short one when it quits. Leaders are reaped as they exit.
    public func stopAll(grace: Duration) {
        let running = children.withLock { Array($0.values) }
        guard !running.isEmpty else { return }
        let exits = DispatchGroup()
        for child in running {
            exits.enter()
            child.whenExited { exits.leave() }
            child.terminate()
        }
        _ = exits.wait(timeout: .now() + grace.timeInterval)
        for child in running {
            child.kill()
        }
    }
}

/// One run of one process: starting it, relaying its output, and ending the stream exactly once.
nonisolated final class ProcessRun: Sendable {
    private enum Pipe: Sendable {
        case stdout
        case stderr
    }

    private struct State {
        var child: ChildProcess?
        /// The read sources of the output pipes. Cancelling one closes its descriptor.
        var readers: [any DispatchSourceRead] = []
        var isCancelled = false
        var isTimedOut = false
        var isFinished = false
        var stdoutOpen = true
        var stderrOpen = true
        var exitStatus: Int32?
    }

    private let request: ProcessRequest
    private let environment: [String: String]
    private let continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    private let killGrace: Duration
    private let drainGrace: Duration
    private let groups: ProcessGroups
    private let books: RunBooks
    private let track: @Sendable (ChildProcess) -> Void
    private let untrack: @Sendable (pid_t) -> Void
    /// Reads both pipes in turn, so each pipe's chunks keep their order.
    private let readQueue = DispatchQueue(label: "platform.processes.read", qos: .userInitiated)
    private let state = Mutex(State())

    init(
        request: ProcessRequest, environment: [String: String],
        continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation,
        killGrace: Duration, drainGrace: Duration, groups: ProcessGroups, books: RunBooks,
        track: @escaping @Sendable (ChildProcess) -> Void,
        untrack: @escaping @Sendable (pid_t) -> Void
    ) {
        self.request = request
        self.environment = environment
        self.continuation = continuation
        self.killGrace = killGrace
        self.drainGrace = drainGrace
        self.groups = groups
        self.books = books
        self.track = track
        self.untrack = untrack
        books.runStarted()
    }

    deinit {
        books.runEnded()
    }

    /// Starts the process unless the consumer already went away.
    func start() {
        let directory = request.currentDirectory ?? request.executable.deletingLastPathComponent()
        let started = state.withLock { state -> Result<Spawn.Child, Spawn.Failure>? in
            if state.isCancelled { return nil }
            let started = Spawn.start(
                executable: request.executable, arguments: request.arguments, environment: environment,
                directory: directory, hasInput: request.standardInput != nil)
            guard case .success(let spawned) = started else { return started }
            books.opened(spawned.input == nil ? 2 : 3)
            // Inside the lock, so a cancel that comes next finds the child to stop.
            let child = ChildProcess.adopt(spawned.pid, groups: groups) { [self] status in
                untrack(spawned.pid)
                exited(status: status)
            }
            track(child)
            state.child = child
            state.readers = [reader(spawned.output, for: .stdout), reader(spawned.errors, for: .stderr)]
            // Watched only once tracked, so the reap that untracks it always comes after.
            child.watch()
            return started
        }
        switch started {
        case nil:
            return
        case .failure(let failure):
            finish(throwing: ProcessError.launchFailed("\(request.executable.lastPathComponent): \(failure.reason)"))
        case .success(let spawned):
            if let input = spawned.input { write(request.standardInput ?? Data(), to: input) }
            if let timeout = request.timeout { scheduleTimeout(after: timeout) }
        }
    }

    /// Stops the process group because the consumer stopped listening.
    func cancel() {
        let child = state.withLock { state -> ChildProcess? in
            state.isCancelled = true
            return state.child
        }
        child?.stop(grace: killGrace)
    }

    /// A read source over one pipe. Its cancel handler closes the descriptor, so the descriptor is
    /// closed exactly once and only after Dispatch is done with it.
    private func reader(_ descriptor: Int32, for pipe: Pipe) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        source.setEventHandler { [self] in read(descriptor, from: pipe, source: source) }
        source.setCancelHandler { [books] in
            close(descriptor)
            books.closed()
        }
        source.resume()
        return source
    }

    private func read(_ descriptor: Int32, from pipe: Pipe, source: any DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            let data = Data(buffer[..<count])
            continuation.yield(pipe == .stdout ? .stdout(data) : .stderr(data))
            return
        }
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        source.cancel()
        state.withLock { state in
            switch pipe {
            case .stdout: state.stdoutOpen = false
            case .stderr: state.stderrOpen = false
            }
        }
        finishIfDone(force: false)
    }

    private func exited(status: Int32) {
        state.withLock { state in
            state.exitStatus = status
            // Reaped: there is nothing left to stop, and letting go breaks the cycle through the
            // child's callback.
            state.child = nil
        }
        finishIfDone(force: false)
        // A background child may hold the pipes open; stop waiting for it after a short grace.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + drainGrace.timeInterval) { [self] in
            finishIfDone(force: true)
        }
    }

    /// Ends the stream once the process exited and, unless `force`, both pipes are drained.
    private func finishIfDone(force: Bool) {
        enum Ending {
            case exit(Int32)
            case timedOut
        }
        let (ending, readers) = state.withLock { state -> (Ending?, [any DispatchSourceRead]) in
            guard !state.isFinished, let status = state.exitStatus else { return (nil, []) }
            guard force || (!state.stdoutOpen && !state.stderrOpen) else { return (nil, []) }
            state.isFinished = true
            defer { state.readers = [] }
            return (state.isTimedOut ? .timedOut : .exit(status), state.readers)
        }
        // Our read ends close here, as they did when the stream ended before.
        for reader in readers {
            reader.cancel()
        }
        switch ending {
        case .exit(let status):
            continuation.yield(.exit(status))
            continuation.finish()
        case .timedOut:
            continuation.finish(throwing: ProcessError.timedOut)
        case nil:
            break
        }
    }

    private func finish(throwing error: any Error) {
        let shouldFinish = state.withLock { state -> Bool in
            defer { state.isFinished = true }
            return !state.isFinished
        }
        if shouldFinish { continuation.finish(throwing: error) }
    }

    /// The timer holds the run weakly: a run that ended and was let go has nothing to stop.
    private func scheduleTimeout(after timeout: Duration) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
            guard let self else { return }
            let child = state.withLock { state -> ChildProcess? in
                guard state.exitStatus == nil, !state.isFinished else { return nil }
                state.isTimedOut = true
                return state.child
            }
            child?.stop(grace: killGrace)
        }
    }

    /// Writes standard input on a background queue and closes it. A process that exits without
    /// reading gets the rest dropped: the pipe is set not to raise SIGPIPE, which would end the app.
    private func write(_ data: Data, to descriptor: Int32) {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async { [books] in
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            close(descriptor)
            books.closed()
        }
    }
}

/// Counts the pipe ends a runner holds open and the runs it has not let go, so a test can see
/// that every one is closed and released.
nonisolated final class RunBooks: Sendable {
    private let descriptors = Atomic<Int>(0)
    private let runs = Atomic<Int>(0)

    /// The parent's pipe ends open now: two for each run, three with input.
    var openDescriptors: Int {
        descriptors.load(ordering: .relaxed)
    }

    /// Runs not deallocated yet.
    var liveRuns: Int {
        runs.load(ordering: .relaxed)
    }

    func opened(_ number: Int) {
        descriptors.add(number, ordering: .relaxed)
    }

    func closed() {
        descriptors.subtract(1, ordering: .relaxed)
    }

    func runStarted() {
        runs.add(1, ordering: .relaxed)
    }

    func runEnded() {
        runs.subtract(1, ordering: .relaxed)
    }
}

extension Duration {
    /// The duration in seconds, for Dispatch.
    nonisolated var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
