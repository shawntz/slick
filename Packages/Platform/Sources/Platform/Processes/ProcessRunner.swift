import Foundation
import Kit
import Synchronization

/// The live process service, on `Foundation.Process`.
///
/// Each run starts on a background queue, never on the caller's thread. Output streams in chunks as
/// it arrives. The stream ends with ``ProcessEvent/exit(_:)`` once the process has exited and both
/// output pipes are drained. A process killed by a signal reports 128 plus the signal number, as a
/// shell does. Cancelling the consumer, or reaching the timeout, sends SIGTERM and then SIGKILL
/// after ``killGrace``.
///
/// Known limit: only the process itself is signalled. A child it started in the background keeps
/// running, and once the process exited the stream waits at most ``drainGrace`` for such a child
/// to close the output pipes.
nonisolated public final class ProcessRunner: ProcessService {
    /// The clean environment every run starts from. ``ProcessRequest/environment`` entries replace
    /// its values.
    public let baseEnvironment: [String: String]
    /// How long a process may take to exit after SIGTERM before it gets SIGKILL.
    public let killGrace: Duration
    /// How long the stream waits for the output pipes to close after the process exited.
    public let drainGrace: Duration

    private let running = Mutex<Set<ObjectIdentifier>>([])
    private let launcher = DispatchQueue(label: "platform.processes.launch", qos: .userInitiated)

    /// - Parameters:
    ///   - baseEnvironment: The clean environment. Defaults to ``cleanEnvironment(home:inherited:)``
    ///     with the real home folder; the app passes the run environment's home.
    public init(
        baseEnvironment: [String: String] = ProcessRunner.cleanEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser),
        killGrace: Duration = .seconds(2),
        drainGrace: Duration = .milliseconds(500)
    ) {
        self.baseEnvironment = baseEnvironment
        self.killGrace = killGrace
        self.drainGrace = drainGrace
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

    /// How many processes this runner has started that have not exited yet.
    public var runningCount: Int {
        running.withLock { $0.count }
    }

    public func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ProcessEvent.self)
        let run = ProcessRun(
            request: request, environment: environment(for: request), continuation: continuation,
            killGrace: killGrace, drainGrace: drainGrace,
            onLaunch: { [weak self] id in _ = self?.running.withLock { $0.insert(id) } },
            onExit: { [weak self] id in _ = self?.running.withLock { $0.remove(id) } })
        continuation.onTermination = { termination in
            if case .cancelled = termination { run.cancel() }
        }
        launcher.async { run.start() }
        return stream
    }
}

/// One run of one process: launching it, relaying its output, and ending the stream exactly once.
nonisolated final class ProcessRun: Sendable {
    private enum Pipe: Sendable {
        case stdout
        case stderr
    }

    private struct State {
        var process: ProcessBox?
        /// The read ends of the output pipes, kept so the handlers can be removed when the stream
        /// ends early.
        var readers: [FileHandleBox] = []
        var isCancelled = false
        var isTimedOut = false
        var isFinished = false
        var stdoutOpen = true
        var stderrOpen = true
        var exitStatus: Int32?

        /// Drops the process and the pipes once the stream has ended, which breaks the cycle
        /// through their handlers.
        mutating func release() {
            process = nil
            readers = []
        }
    }

    private let request: ProcessRequest
    private let environment: [String: String]
    private let continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    private let killGrace: Duration
    private let drainGrace: Duration
    private let onLaunch: @Sendable (ObjectIdentifier) -> Void
    private let onExit: @Sendable (ObjectIdentifier) -> Void
    private let state = Mutex(State())

    init(
        request: ProcessRequest, environment: [String: String],
        continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation,
        killGrace: Duration, drainGrace: Duration,
        onLaunch: @escaping @Sendable (ObjectIdentifier) -> Void,
        onExit: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.request = request
        self.environment = environment
        self.continuation = continuation
        self.killGrace = killGrace
        self.drainGrace = drainGrace
        self.onLaunch = onLaunch
        self.onExit = onExit
    }

    /// Launches the process unless the consumer already went away.
    func start() {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = environment
        process.currentDirectoryURL = request.currentDirectory ?? request.executable.deletingLastPathComponent()
        let output = Foundation.Pipe()
        let errors = Foundation.Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = request.standardInput.map { _ in Foundation.Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [self] handle in read(handle, from: .stdout) }
        errors.fileHandleForReading.readabilityHandler = { [self] handle in read(handle, from: .stderr) }
        process.terminationHandler = { [self] process in
            let status = process.terminationStatus
            exited(status: process.terminationReason == .uncaughtSignal ? 128 + status : status)
        }

        let box = ProcessBox(process)
        let launchError = state.withLock { state -> (any Error)? in
            if state.isCancelled { return CancellationError() }
            do {
                try process.run()
            } catch {
                return error
            }
            state.process = box
            state.readers = [FileHandleBox(output.fileHandleForReading), FileHandleBox(errors.fileHandleForReading)]
            // Inside the lock, so the exit, which takes the same lock, is always counted after.
            onLaunch(ObjectIdentifier(box))
            return nil
        }
        if let launchError {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if !(launchError is CancellationError) {
                finish(throwing: ProcessError.launchFailed(Self.describe(launchError, executable: request.executable)))
            }
            return
        }
        if let input, let data = request.standardInput { Self.write(data, to: input) }
        if let timeout = request.timeout { scheduleTimeout(after: timeout) }
    }

    /// Terminates the process because the consumer stopped listening.
    func cancel() {
        let process = state.withLock { state -> ProcessBox? in
            state.isCancelled = true
            return state.process
        }
        process.map(terminate)
    }

    private func read(_ handle: FileHandle, from pipe: Pipe) {
        let data = handle.availableData
        guard data.isEmpty else {
            continuation.yield(pipe == .stdout ? .stdout(data) : .stderr(data))
            return
        }
        handle.readabilityHandler = nil
        state.withLock { state in
            switch pipe {
            case .stdout: state.stdoutOpen = false
            case .stderr: state.stderrOpen = false
            }
        }
        finishIfDone(force: false)
    }

    private func exited(status: Int32) {
        let box = state.withLock { state -> ProcessBox? in
            state.exitStatus = status
            return state.process
        }
        if let box { onExit(ObjectIdentifier(box)) }
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
        let (ending, readers) = state.withLock { state -> (Ending?, [FileHandleBox]) in
            guard !state.isFinished, let status = state.exitStatus else { return (nil, []) }
            guard force || (!state.stdoutOpen && !state.stderrOpen) else { return (nil, []) }
            state.isFinished = true
            defer { state.release() }
            return (state.isTimedOut ? .timedOut : .exit(status), state.readers)
        }
        for reader in readers {
            reader.handle.readabilityHandler = nil
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
            defer {
                state.isFinished = true
                state.release()
            }
            return !state.isFinished
        }
        if shouldFinish { continuation.finish(throwing: error) }
    }

    private func scheduleTimeout(after timeout: Duration) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
            let process = state.withLock { state -> ProcessBox? in
                guard state.exitStatus == nil, !state.isFinished else { return nil }
                state.isTimedOut = true
                return state.process
            }
            process.map(terminate)
        }
    }

    /// Sends SIGTERM, then SIGKILL if the process is still running after the grace period.
    private func terminate(_ box: ProcessBox) {
        guard box.process.isRunning else { return }
        box.process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace.timeInterval) {
            if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
        }
    }

    /// Writes standard input on a background queue and closes it. A process that exits without
    /// reading gets the rest dropped: the pipe is set not to raise SIGPIPE, which would end the app.
    private static func write(_ data: Data, to pipe: Foundation.Pipe) {
        let handle = pipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    private static func describe(_ error: any Error, executable: URL) -> String {
        let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
        return "\(executable.lastPathComponent): \(reason)"
    }
}

/// A pipe's file handle, shared to remove its handler. `FileHandle` is thread safe for that.
nonisolated final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

/// A `Process` shared between the threads that read its output and the one that may terminate it.
/// `Process` is thread safe for `isRunning`, `terminate()` and `processIdentifier`.
nonisolated final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

extension Duration {
    /// The duration in seconds, for Dispatch.
    nonisolated var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
