import Foundation

/// Runs subprocesses, such as script commands and script filters.
public protocol ProcessService: Sendable {
    /// Starts a process and streams its output. Cancelling the task that consumes the stream
    /// terminates the process. The stream finishes after the ``ProcessEvent/exit(_:)`` event, or
    /// throws ``ProcessError`` when the process could not start or ran past its timeout.
    func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error>
}

extension ProcessService {
    /// Runs a process to the end and collects its output. Throws `CancellationError` when the
    /// calling task is cancelled, so cut-off output is never mistaken for a result.
    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        var result = ProcessResult(exitCode: -1, stdout: Data(), stderr: Data())
        for try await event in stream(request) {
            switch event {
            case .stdout(let data): result.stdout.append(data)
            case .stderr(let data): result.stderr.append(data)
            case .exit(let code): result.exitCode = code
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// The process's output as text, decoded off the main thread with ``UTF8StreamDecoder``, so a
    /// character split across chunks arrives whole. Cancelling the consumer terminates the process.
    public func textStream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessTextEvent, any Error> {
        let events = stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var stdout = UTF8StreamDecoder()
                var stderr = UTF8StreamDecoder()
                do {
                    for try await event in events {
                        switch event {
                        case .stdout(let data): continuation.yieldText(stdout.decode(data), as: ProcessTextEvent.stdout)
                        case .stderr(let data): continuation.yieldText(stderr.decode(data), as: ProcessTextEvent.stderr)
                        case .exit(let code):
                            continuation.yieldText(stdout.finish(), as: ProcessTextEvent.stdout)
                            continuation.yieldText(stderr.finish(), as: ProcessTextEvent.stderr)
                            continuation.yield(.exit(code))
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Text from a running process. See ``ProcessService/textStream(_:)``.
public enum ProcessTextEvent: Hashable, Sendable {
    case stdout(String)
    case stderr(String)
    /// The process ended with this status. Always the last event.
    case exit(Int32)
}

extension AsyncThrowingStream.Continuation where Element == ProcessTextEvent {
    fileprivate func yieldText(_ text: String, as event: (String) -> ProcessTextEvent) {
        if !text.isEmpty { yield(event(text)) }
    }
}

/// How to start a process.
public struct ProcessRequest: Hashable, Sendable {
    public var executable: URL
    public var arguments: [String]
    /// Added to a clean environment that holds only `PATH`, `HOME`, `LANG` and `TMPDIR`. An entry
    /// replaces the clean one, so a script can get a `PATH` that includes Homebrew.
    public var environment: [String: String]
    /// The working directory. Nil uses the executable's folder.
    public var currentDirectory: URL?
    /// Written to standard input, which is then closed.
    public var standardInput: Data?
    /// The process is terminated after this long. Nil means no limit.
    public var timeout: Duration?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration? = .seconds(30)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

/// Output from a running process.
public enum ProcessEvent: Hashable, Sendable {
    /// A chunk of standard output, in arrival order. Chunks do not follow line boundaries.
    case stdout(Data)
    case stderr(Data)
    /// The process ended with this status. Always the last event.
    case exit(Int32)
}

/// The collected output of a finished process.
public struct ProcessResult: Hashable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Standard output as UTF-8 text.
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    /// Standard error as UTF-8 text.
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

/// Why a process did not run to the end.
public enum ProcessError: Error, Hashable, Sendable {
    case launchFailed(String)
    case timedOut
}
