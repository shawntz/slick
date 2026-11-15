import Foundation
import Kit
import Synchronization

/// A process runner that runs nothing. A test stubs each executable with the output it should
/// produce; running anything else fails with ``ProcessError/launchFailed(_:)``.
public final class FakeProcesses: ProcessService {
    /// Produces a fake process's output from its request.
    public typealias Handler = @Sendable (ProcessRequest) -> FakeProcessOutput

    private struct State {
        var stubs: [String: Handler] = [:]
        var runs: [ProcessRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Stubs an executable, by full path or by file name, with a handler.
    public func stub(_ executable: String, handler: @escaping Handler) {
        state.withLock { $0.stubs[executable] = handler }
    }

    /// Stubs an executable, by full path or by file name, with fixed output.
    public func stub(_ executable: String, output: FakeProcessOutput) {
        stub(executable) { _ in output }
    }

    /// Every request, in order.
    public var runs: [ProcessRequest] { state.withLock { $0.runs } }

    public func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let handler = state.withLock { state in
            state.runs.append(request)
            return state.stubs[request.executable.path] ?? state.stubs[request.executable.lastPathComponent]
        }
        guard let handler else {
            return AsyncThrowingStream {
                $0.finish(throwing: ProcessError.launchFailed("no fake for \(request.executable.lastPathComponent)"))
            }
        }
        let output = handler(request)
        return AsyncThrowingStream { continuation in
            for event in output.events {
                continuation.yield(event)
            }
            if !output.keepsRunning {
                continuation.yield(.exit(output.exitCode))
                continuation.finish()
            }
        }
    }
}

/// What a fake process writes and how it ends.
public struct FakeProcessOutput: Sendable {
    /// Output events before the exit.
    public var events: [ProcessEvent]
    public var exitCode: Int32
    /// When true the process never exits; its stream stays open until the consumer is cancelled.
    public var keepsRunning: Bool

    public init(events: [ProcessEvent], exitCode: Int32 = 0, keepsRunning: Bool = false) {
        self.events = events
        self.exitCode = exitCode
        self.keepsRunning = keepsRunning
    }

    /// Writes text to standard output and exits with the code.
    public static func stdout(_ text: String, exitCode: Int32 = 0) -> FakeProcessOutput {
        FakeProcessOutput(events: [.stdout(Data(text.utf8))], exitCode: exitCode)
    }

    /// Writes text to standard error and exits with the code.
    public static func stderr(_ text: String, exitCode: Int32 = 1) -> FakeProcessOutput {
        FakeProcessOutput(events: [.stderr(Data(text.utf8))], exitCode: exitCode)
    }
}
