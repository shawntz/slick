import Foundation
import Kit

/// The process service commands run through, for each kind of run.
///
/// In the launcher it is Kit's process service from the feature's context: the shell starts in a
/// process group of its own with Kit's clean environment and the request's entries on top, standard
/// input reads from `/dev/null`, and when the page stops listening the service sends SIGTERM to the
/// whole group, then SIGKILL once the shell has exited or two seconds have passed. So Stop ends
/// every process the command started. Scenarios, self-tests and benchmarks get
/// ``SimulatedShellProcesses``, which starts nothing.
nonisolated enum ShellProcessesKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ProcessService {
        context.processes
    }

    static func isolated(_ context: FeatureContext) -> any ProcessService {
        SimulatedShellProcesses()
    }
}

/// A process service that starts no process. It answers each command with a line of output and a
/// clean exit, so a scenario can show the output page. `echo` prints its words, as a shell would.
nonisolated final class SimulatedShellProcesses: ProcessService {
    func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let output = Self.output(for: request.arguments.last ?? "")
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout(Data(output.utf8)))
            continuation.yield(.exit(0))
            continuation.finish()
        }
    }

    /// What a simulated command prints.
    static func output(for command: String) -> String {
        let words = command.trimmingCharacters(in: .whitespaces)
        if words == "echo" { return "\n" }
        if words.hasPrefix("echo ") { return String(words.dropFirst(5)) + "\n" }
        return Strings.simulatedOutput + "\n"
    }
}
