import Foundation
import Kit
import Testing

@testable import Platform

/// Runs only /bin/echo, /bin/cat, /bin/sh and /bin/sleep with harmless scripts.
@Suite(.timeLimit(.minutes(1))) struct ProcessTests {
    let runner = ProcessRunner(
        baseEnvironment: ProcessRunner.cleanEnvironment(
            home: URL(filePath: "/synthetic/home"), inherited: ["LANG": "en_US.UTF-8", "TMPDIR": "/tmp/"]),
        killGrace: .milliseconds(500), drainGrace: .milliseconds(300))

    static let sh = URL(filePath: "/bin/sh")

    static func script(_ text: String, timeout: Duration? = .seconds(10)) -> ProcessRequest {
        ProcessRequest(executable: sh, arguments: ["-c", text], timeout: timeout)
    }

    @Test func argumentsReachTheProcessAndOutputComesBack() async throws {
        let result = try await runner.run(
            ProcessRequest(executable: URL(filePath: "/bin/echo"), arguments: ["hello", "world"]))
        #expect(result.exitCode == 0)
        #expect(result.output == "hello world\n")
        #expect(result.errorOutput.isEmpty)
    }

    @Test func standardInputIsWrittenAndClosed() async throws {
        let text = String(repeating: "line of synthetic input\n", count: 2_000)
        let result = try await runner.run(
            ProcessRequest(executable: URL(filePath: "/bin/cat"), standardInput: Data(text.utf8)))
        #expect(result.output == text)
    }

    @Test func standardErrorAndTheExitCodeAreReported() async throws {
        var request = Self.script("echo \"out $GREETING\"; echo err >&2; exit 3")
        request.environment = ["GREETING": "hi"]
        let result = try await runner.run(request)
        #expect(result.exitCode == 3)
        #expect(result.output == "out hi\n")
        #expect(result.errorOutput == "err\n")
    }

    @Test func theEnvironmentStartsCleanAndRequestEntriesWin() async throws {
        var request = Self.script(#"printf '%s|%s|%s|%s' "$PATH" "$HOME" "$LANG" "${USER-unset}""#)
        request.environment = ["PATH": "/opt/synthetic/bin:/usr/bin:/bin"]
        let result = try await runner.run(request)
        #expect(result.output == "/opt/synthetic/bin:/usr/bin:/bin|/synthetic/home|en_US.UTF-8|unset")
        #expect(Set(runner.baseEnvironment.keys) == ["PATH", "HOME", "LANG", "TMPDIR"])
    }

    @Test func theWorkingDirectoryDefaultsToTheExecutablesFolder() async throws {
        let folder = TemporaryFolder()
        var request = Self.script("pwd")
        request.currentDirectory = folder.url
        let chosen = try await runner.run(request).output.trimmingCharacters(in: .newlines)
        #expect(canonicalPath(URL(filePath: chosen)) == canonicalPath(folder.url))
        let fallback = try await runner.run(Self.script("pwd")).output
        #expect(fallback == "/bin\n")
        withExtendedLifetime(folder) {}
    }

    @Test func largeOutputArrivesWhole() async throws {
        let result = try await runner.run(Self.script("head -c 300000 /dev/zero"))
        #expect(result.stdout.count == 300_000)
        #expect(result.exitCode == 0)
    }

    /// The background `sleep` keeps the output pipe open long after the shell exits. The run must
    /// come back well before it ends. The margin is wide on purpose: on a loaded machine starting
    /// the shell alone can take seconds, and a narrow one measured the machine, not the runner.
    @Test func aBackgroundChildDoesNotHoldTheStreamOpen() async throws {
        let started = ContinuousClock.now
        let result = try await runner.run(Self.script("/bin/sleep 60 & echo $!"))
        let child = pid_t(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        defer { if let child, child > 1 { kill(child, SIGTERM) } }
        #expect(child != nil, "the script prints the background child's process ID")
        #expect(result.exitCode == 0)
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func aProcessKilledByASignalReportsTheShellCode() async throws {
        let result = try await runner.run(Self.script("kill -TERM $$"))
        #expect(result.exitCode == 128 + SIGTERM)
    }

    @Test func aMissingExecutableFailsToLaunch() async {
        await #expect {
            try await runner.run(ProcessRequest(executable: URL(filePath: "/nonexistent/synthetic-tool")))
        } throws: { error in
            guard case ProcessError.launchFailed(let reason) = error else { return false }
            return reason.contains("synthetic-tool")
        }
    }

    @Test func theTimeoutTerminatesTheProcess() async throws {
        let started = ContinuousClock.now
        await #expect(throws: ProcessError.timedOut) {
            try await runner.run(Self.script("exec /bin/sleep 20", timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        try await waitUntil { runner.runningCount == 0 }
    }

    @Test func cancellingTheCallerThrowsAndTerminatesTheProcess() async throws {
        let request = Self.script("echo started; exec /bin/sleep 20", timeout: nil)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let runner = runner
        let consumer = Task {
            var output = Data()
            for try await event in runner.stream(request) {
                if case .stdout(let data) = event {
                    output.append(data)
                    startedContinuation.yield()
                }
            }
            try Task.checkCancellation()
            return output
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        #expect(runner.runningCount == 1)
        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        try await waitUntil { runner.runningCount == 0 }

        // Kit's run(_:) throws too, rather than returning cut-off output.
        let collector = Task { try await runner.run(request) }
        try await waitUntil { runner.runningCount == 1 }
        collector.cancel()
        await #expect(throws: CancellationError.self) { try await collector.value }
        try await waitUntil { runner.runningCount == 0 }
    }

    @Test func textStreamDecodesTheOutput() async throws {
        var text = ""
        var exit: Int32?
        for try await event in runner.textStream(Self.script("printf 'caf\\303\\251 '; printf 'ok'")) {
            switch event {
            case .stdout(let chunk): text += chunk
            case .stderr: break
            case .exit(let code): exit = code
            }
        }
        #expect(text == "café ok")
        #expect(exit == 0)
    }
}

/// A path with symbolic links resolved and no trailing slash, for comparing folders.
func canonicalPath(_ url: URL) -> String {
    let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
}

/// The task's value. A task that runs past `limit` is cancelled, so a test fails instead of hanging
/// on an unstructured task that the test's own time limit cannot cancel.
func boundedValue<T: Sendable>(of task: Task<T, Never>, limit: Duration = .seconds(10)) async -> T {
    let watchdog = Task {
        try? await Task.sleep(for: limit)
        task.cancel()
    }
    defer { watchdog.cancel() }
    return await task.value
}

/// Polls a condition every 10 ms for up to five seconds.
func waitUntil(_ condition: @Sendable () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition still false after 5 s", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
