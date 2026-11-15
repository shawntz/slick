import Foundation
import Kit

/// A finished script's output.
nonisolated struct CapturedOutput: Hashable, Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorOutput: String { String(decoding: stderr, as: UTF8.self) }

    /// Standard output, then standard error, for the Show Output page.
    var combined: String {
        let error = errorOutput
        guard !error.isEmpty else { return output }
        let out = output
        return out.isEmpty || out.hasSuffix("\n") ? out + error : out + "\n" + error
    }

    /// The line a failure toast shows: the last line of standard error, else of standard output.
    var failureLine: String? {
        OutputText.lastLine(errorOutput) ?? OutputText.lastLine(output)
    }
}

/// Why a script did not run to the end.
nonisolated enum ScriptRunError: Error, Hashable, Sendable {
    /// It ran past the time limit and was stopped.
    case timedOut
    /// It printed more than the output limit and was stopped.
    case outputLimit
    /// The interpreter could not start.
    case couldNotStart(String)
}

/// Runs scripts through Kit's process service.
nonisolated enum ScriptExecution {
    /// Runs a script to the end and collects its output, at most `limit` bytes of standard output
    /// and standard error together. Past the limit it stops reading, which ends the process, and
    /// throws ``ScriptRunError/outputLimit``. Throws `CancellationError` when the calling task is
    /// cancelled, which ends the process too.
    @concurrent static func capture(_ processes: any ProcessService, _ request: ProcessRequest, limit: Int)
        async throws -> CapturedOutput
    {
        var output = CapturedOutput(exitCode: -1, stdout: Data(), stderr: Data())
        do {
            // Leaving this loop early drops the stream, and the process service ends the process.
            for try await event in processes.stream(request) {
                switch event {
                case .stdout(let data): output.stdout.append(data)
                case .stderr(let data): output.stderr.append(data)
                case .exit(let code): output.exitCode = code
                }
                if output.stdout.count + output.stderr.count > limit { throw ScriptRunError.outputLimit }
            }
        } catch ProcessError.timedOut {
            throw ScriptRunError.timedOut
        } catch ProcessError.launchFailed(let reason) {
            throw ScriptRunError.couldNotStart(reason)
        }
        try Task.checkCancellation()
        return output
    }

    /// What to tell the user about an error from ``capture(_:_:limit:)``. Nil for cancellation,
    /// which shows nothing.
    static func failure(for error: any Error, title: String, settings: RunSettings) -> ActionFailure? {
        switch error {
        case ScriptRunError.timedOut:
            ActionFailure(Strings.timedOut(title, after: settings.timeoutName), message: Strings.timedOutMessage)
        case ScriptRunError.outputLimit:
            ActionFailure(Strings.overLimit(title, limit: settings.outputLimitName), message: Strings.overLimitMessage)
        case ScriptRunError.couldNotStart(let reason):
            ActionFailure(Strings.couldNotStart(title), message: reason)
        case is CancellationError:
            nil
        default:
            ActionFailure(Strings.failed(title), message: error.localizedDescription)
        }
    }
}
