import Darwin
import Foundation
import Kit
import Synchronization
import Testing

@testable import Platform

/// Stopping a run ends its whole process group, and nothing else.
///
/// These tests start only /bin/sh, /bin/sleep, /bin/echo and /usr/bin/true, never as login or
/// interactive shells, each in a temporary folder of its own. Real signals go only through the
/// runner, which signals only a group whose leader it started and has not reaped. A test sends
/// signal 0, which delivers nothing, to the two process IDs its own command printed, to see that
/// they are gone. Waits poll for the event with a bound.
@Suite(.timeLimit(.minutes(1))) struct ProcessStopTests {
    static let sh = URL(filePath: "/bin/sh")
    let folder = TemporaryFolder()

    /// A runner with short graces, whose signals are recorded on their way to the system.
    func makeRunner(killGrace: Duration = .milliseconds(300)) -> (ProcessRunner, SignalRecorder) {
        let recorder = SignalRecorder(forwardingTo: ProcessGroups.signalGroup)
        let runner = ProcessRunner(
            baseEnvironment: ProcessRunner.cleanEnvironment(
                home: folder.url, inherited: ["LANG": "en_US.UTF-8", "TMPDIR": folder.url.path(percentEncoded: false)]),
            killGrace: killGrace, drainGrace: .milliseconds(300), groups: ProcessGroups(systemCall: recorder.call))
        return (runner, recorder)
    }

    func script(_ text: String, timeout: Duration? = nil) -> ProcessRequest {
        ProcessRequest(executable: Self.sh, arguments: ["-c", text], currentDirectory: folder.url, timeout: timeout)
    }

    /// The shell prints its own ID and its background sleep's, then waits for the sleep.
    static let shellWithABackgroundSleep = #"/bin/sleep 30 & echo "$$ $!"; wait"#

    // MARK: - Stop ends the children

    /// On macOS 27.2 this passed with Foundation's `Process` too, which already started each
    /// process in a group of its own and whose SIGTERM reached the sleep.
    @Test func stoppingARunEndsItsBackgroundChildToo() async throws {
        let runner = ProcessRunner(
            baseEnvironment: ProcessRunner.cleanEnvironment(home: folder.url, inherited: [:]),
            killGrace: .milliseconds(300), drainGrace: .milliseconds(300))
        let run = OutputLines(runner.stream(script(Self.shellWithABackgroundSleep)))
        let ids = try #require(await run.processIDs())
        #expect(getpgid(ids.child) == ids.leader, "the sleep is in the shell's group")

        run.consumer.cancel()
        await #expect(throws: CancellationError.self) { try await run.consumer.value }
        try await waitFor { isGone(ids.leader) && isGone(ids.child) }
        try await waitFor { runner.runningCount == 0 }
    }

    @Test func aStopSendsTermThenKillToTheGroupAndNothingAfterTheReap() async throws {
        let (runner, recorder) = makeRunner()
        let run = OutputLines(runner.stream(script(Self.shellWithABackgroundSleep)))
        let ids = try #require(await run.processIDs())

        run.consumer.cancel()
        try await waitFor { isGone(ids.leader) && isGone(ids.child) }
        try await waitFor { runner.runningCount == 0 }
        #expect(
            recorder.calls == [.init(group: ids.leader, signal: SIGTERM), .init(group: ids.leader, signal: SIGKILL)])
        #expect(runner.groups.liveGroups.isEmpty)
        #expect(!runner.groups.send(SIGTERM, toGroup: ids.leader), "a reaped group is refused")
        #expect(recorder.calls.count == 2)
    }

    @Test func theTimeoutStopsTheWholeGroup() async throws {
        let (runner, recorder) = makeRunner()
        let run = OutputLines(runner.stream(script(Self.shellWithABackgroundSleep, timeout: .seconds(1))))
        let ids = await run.processIDs()
        await #expect(throws: ProcessError.timedOut) { try await run.consumer.value }
        try await waitFor { runner.runningCount == 0 }
        #expect(runner.groups.liveGroups.isEmpty)
        // On a machine so loaded that the shell had not printed within the timeout, there is no
        // sleep to look for, and the rest still holds.
        if let ids {
            try await waitFor { isGone(ids.leader) && isGone(ids.child) }
            #expect(recorder.calls.map(\.signal) == [SIGTERM, SIGKILL])
            #expect(recorder.calls.allSatisfy { $0.group == ids.leader })
        }
    }

    /// Uses only the runner's public interface, so it also runs against the runner before process
    /// groups. There it fails: that runner sent SIGKILL to the shell alone, and the sleep, which
    /// ignores SIGTERM as the shell does, outlived it.
    @Test func aGroupThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let runner = ProcessRunner(
            baseEnvironment: ProcessRunner.cleanEnvironment(home: folder.url, inherited: [:]),
            killGrace: .milliseconds(300), drainGrace: .milliseconds(300))
        let run = OutputLines(runner.stream(script("trap '' TERM; " + Self.shellWithABackgroundSleep)))
        let ids = try #require(await run.processIDs())

        run.consumer.cancel()
        try await waitFor { isGone(ids.leader) && isGone(ids.child) }
        try await waitFor { runner.runningCount == 0 }
    }

    @Test func aGroupThatIgnoresTermGetsKillOnceTheGraceHasPassed() async throws {
        let (runner, recorder) = makeRunner()
        let run = OutputLines(runner.stream(script("trap '' TERM; " + Self.shellWithABackgroundSleep)))
        let ids = try #require(await run.processIDs())

        let stopped = ContinuousClock.now
        run.consumer.cancel()
        try await waitFor { isGone(ids.leader) && isGone(ids.child) }
        #expect(ContinuousClock.now - stopped >= .milliseconds(300), "nothing ended before the grace")
        try await waitFor { runner.runningCount == 0 }
        #expect(
            recorder.calls == [.init(group: ids.leader, signal: SIGTERM), .init(group: ids.leader, signal: SIGKILL)])
    }

    // MARK: - A process that ends by itself

    @Test func aProcessThatEndsByItselfIsReapedAndSignalledNothing() async throws {
        let (runner, recorder) = makeRunner()
        // The sleep's output goes elsewhere, so the stream ends with the shell.
        let run = OutputLines(runner.stream(script(#"/bin/sleep 10 >/dev/null 2>&1 & echo "$$ $!""#)))
        let ids = try #require(await run.processIDs())
        let status = try await run.consumer.value
        #expect(status == 0)
        try await waitFor { runner.runningCount == 0 }
        #expect(isGone(ids.leader))
        #expect(!isGone(ids.child), "a child left in the background keeps running, as after a terminal command")
        #expect(recorder.calls.isEmpty)
        #expect(!runner.groups.send(SIGTERM, toGroup: ids.leader), "a reaped group is refused")
        #expect(recorder.calls.isEmpty)
    }

    @Test func aReapedGroupIsRefused() async throws {
        let (runner, recorder) = makeRunner()
        let run = OutputLines(runner.stream(script("echo $$")))
        let leader = try #require(await run.firstLine().flatMap { pid_t($0) })
        _ = try await run.consumer.value
        try await waitFor { runner.runningCount == 0 }
        #expect(!runner.groups.liveGroups.contains(leader))
        #expect(!runner.groups.send(SIGKILL, toGroup: leader))
        #expect(recorder.calls.isEmpty)
    }

    // MARK: - Output and spawning

    @Test func outputArrivesWholeAndInOrder() async throws {
        let (runner, _) = makeRunner()
        let result = try await runner.run(
            script(#"i=0; while [ $i -lt 3000 ]; do echo "line $i"; i=$((i+1)); done; echo finished >&2"#))
        #expect(result.exitCode == 0)
        #expect(result.output == (0..<3000).map { "line \($0)\n" }.joined())
        #expect(result.errorOutput == "finished\n")
    }

    @Test func standardInputComesFromDevNullWhenTheRequestHasNone() async throws {
        let (runner, _) = makeRunner()
        let result = try await runner.run(
            ProcessRequest(executable: URL(filePath: "/bin/cat"), currentDirectory: folder.url))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func theWorkingFolderAndTheEnvironmentReachTheChild() async throws {
        let (runner, _) = makeRunner()
        var request = script(#"pwd; printf '%s|%s' "$GREETING" "${USER-unset}""#)
        request.environment = ["GREETING": "hi"]
        let lines = try await runner.run(request).output.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(canonicalPath(URL(filePath: lines.first ?? "")) == canonicalPath(folder.url))
        #expect(lines.last == "hi|unset")
    }

    @Test func aSpawnThatFailsSignalsNothingAndLeavesNothingOpen() async throws {
        let (runner, recorder) = makeRunner()
        let missingFolder = folder.url.appending(path: "missing", directoryHint: .isDirectory)
        let requests = [
            ProcessRequest(executable: URL(filePath: "/nonexistent/synthetic-tool"), currentDirectory: folder.url),
            ProcessRequest(executable: URL(filePath: "/usr/bin/true"), currentDirectory: missingFolder),
            ProcessRequest(executable: Self.sh, arguments: ["-c", "echo a\u{0}b"], currentDirectory: folder.url),
        ]
        for request in requests {
            let consumer = Task { try await runner.run(request) }
            await #expect(throws: ProcessError.self) { try await consumer.value }
            consumer.cancel()
        }
        #expect(runner.runningCount == 0)
        #expect(runner.groups.liveGroups.isEmpty)
        #expect(runner.books.openDescriptors == 0)
        #expect(recorder.calls.isEmpty)
    }

    @Test func theChildGetsOnlyItsThreeDescriptors() async throws {
        let (runner, _) = makeRunner()
        // A descriptor of the app's that is not close-on-exec.
        let open = Darwin.open("/dev/null", O_RDONLY)
        try #require(open > 2)
        defer { close(open) }
        // /dev/fd lists the descriptors of the process that looks, so no redirection is needed.
        let check = #"fd=0; while [ $fd -lt 256 ]; do [ -e /dev/fd/$fd ] && printf '%s ' $fd; fd=$((fd+1)); done"#
        var request = script(check)
        request.standardInput = Data("input".utf8)
        let withInput = try await runner.run(request).output
        let withoutInput = try await runner.run(script(check)).output
        #expect(withInput == "0 1 2 ")
        #expect(withoutInput == "0 1 2 ")
    }

    @Test func everyPipeEndIsClosedOnEveryPath() async throws {
        let (runner, _) = makeRunner()
        let before = openPipeCount()
        for _ in 0..<20 {
            _ = try await runner.run(script("echo out; echo err >&2"))
            var withInput = ProcessRequest(executable: URL(filePath: "/bin/cat"), currentDirectory: folder.url)
            withInput.standardInput = Data("synthetic input".utf8)
            _ = try await runner.run(withInput)
            await #expect(throws: ProcessError.timedOut) {
                try await runner.run(script("exec /bin/sleep 30", timeout: .milliseconds(50)))
            }
            let cancelled = OutputLines(runner.stream(script("echo started; exec /bin/sleep 30")))
            _ = await cancelled.firstLine()
            cancelled.consumer.cancel()
            _ = try? await cancelled.consumer.value
        }
        try await waitFor { runner.runningCount == 0 && runner.books.openDescriptors == 0 }
        // Every run, its child and its read sources are let go once it ended.
        try await waitFor { runner.books.liveRuns == 0 }
        // Other suites open pipes at the same time, so this allows for some. A leak of even one end
        // per run here would add 80.
        #expect(openPipeCount() < before + 20)
    }

    // MARK: - Stopping everything

    @Test func stopAllEndsEveryRunWithinItsGrace() async throws {
        let (runner, recorder) = makeRunner(killGrace: .seconds(30))
        let polite = OutputLines(runner.stream(script(Self.shellWithABackgroundSleep)))
        let stubborn = OutputLines(runner.stream(script("trap '' TERM; " + Self.shellWithABackgroundSleep)))
        let first = try #require(await polite.processIDs())
        let second = try #require(await stubborn.processIDs())

        let started = ContinuousClock.now
        runner.stopAll(grace: .milliseconds(200))
        #expect(ContinuousClock.now - started < .seconds(10), "stopAll returns after its grace, not the runner's")
        #expect(
            recorder.calls.filter { $0.signal == SIGKILL }.map(\.group).sorted()
                == [first.leader, second.leader].sorted())

        try await waitFor {
            isGone(first.leader) && isGone(first.child) && isGone(second.leader) && isGone(second.child)
        }
        try await waitFor { runner.runningCount == 0 }
        _ = try? await polite.consumer.value
        _ = try? await stubborn.consumer.value
    }

    @Test func stopAllWithNothingRunningReturnsAtOnce() {
        let (runner, recorder) = makeRunner()
        runner.stopAll(grace: .seconds(30))
        #expect(recorder.calls.isEmpty)
    }

    @Test func quittingStopsTheLiveRunnersProcessesAndNothingElse() async throws {
        let (runner, recorder) = makeRunner(killGrace: .seconds(30))
        let run = OutputLines(runner.stream(script("trap '' TERM; " + Self.shellWithABackgroundSleep)))
        let ids = try #require(await run.processIDs())

        PlatformServices.stopProcesses(RefusingProcesses(environment: .scenario))
        #expect(recorder.calls.isEmpty)
        PlatformServices.stopProcesses(runner)
        #expect(recorder.calls.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(PlatformServices.processStopGrace <= .seconds(1))
        try await waitFor { isGone(ids.leader) && isGone(ids.child) && runner.runningCount == 0 }
        _ = try? await run.consumer.value
    }

    // MARK: - Waiting without reaping

    /// What the runner rests on: the child leads a group of its own, and `waitid` with `WNOWAIT`
    /// sees its exit and leaves it to be reaped.
    @Test func aChildLeadsItsOwnGroupAndAWaitThatOnlyLooksLeavesItUnreaped() throws {
        let child = try Spawn.start(
            executable: URL(filePath: "/bin/cat"), arguments: [], environment: [:], directory: folder.url,
            hasInput: true
        ).get()
        defer {
            for descriptor in [child.output, child.errors] { close(descriptor) }
        }
        #expect(getpgid(child.pid) == child.pid)
        #expect(getpgid(child.pid) != getpgrp())
        // cat ends when its input closes.
        close(try #require(child.input))

        var info = siginfo_t()
        #expect(waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOWAIT) == 0)
        #expect(info.si_pid == child.pid)
        var status: Int32 = -1
        #expect(waitpid(child.pid, &status, WNOHANG) == child.pid, "still there to reap after the look")
        #expect(ChildProcess.shellStatus(status) == 0)
    }

    @Test func statusesReadAsAShellReportsThem() {
        #expect(ChildProcess.shellStatus(0) == 0)
        #expect(ChildProcess.shellStatus(3 << 8) == 3)
        #expect(ChildProcess.shellStatus(Int32(SIGKILL)) == 128 + SIGKILL)
        #expect(ChildProcess.shellStatus(Int32(SIGTERM) | 0o200) == 128 + SIGTERM, "a core dump still names the signal")
        #expect(ChildProcess.shellStatus(0o177 | (Int32(SIGSTOP) << 8)) == -1)
    }
}

/// Reads a run's standard output line by line while a task consumes the stream, and keeps the
/// task, so a test can cancel it as the host cancels a run.
final class OutputLines: Sendable {
    let consumer: Task<Int32?, any Error>
    private let lines: AsyncStream<String>

    init(_ events: AsyncThrowingStream<ProcessEvent, any Error>) {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        consumer = Task.detached {
            defer { continuation.finish() }
            var pending = ""
            var status: Int32?
            for try await event in events {
                switch event {
                case .stdout(let data):
                    pending += String(decoding: data, as: UTF8.self)
                    while let end = pending.firstIndex(of: "\n") {
                        continuation.yield(String(pending[..<end]))
                        pending = String(pending[pending.index(after: end)...])
                    }
                case .stderr: break
                case .exit(let code): status = code
                }
            }
            try Task.checkCancellation()
            return status
        }
    }

    /// The first line, or nil when the stream ended first.
    func firstLine() async -> String? {
        var iterator = lines.makeAsyncIterator()
        return await iterator.next()
    }

    /// The two process IDs the first line names: the shell's own and its background child's.
    func processIDs() async -> (leader: pid_t, child: pid_t)? {
        guard let line = await firstLine() else { return nil }
        let ids = line.split(separator: " ").compactMap { pid_t($0) }
        guard ids.count == 2, ids.allSatisfy({ $0 > 1 }), ids[0] != ids[1] else { return nil }
        return (ids[0], ids[1])
    }
}

/// Whether no process has this ID. It asks the process table for the process's group, so a test
/// calls no signalling function for a process it did not start.
nonisolated func isGone(_ pid: pid_t) -> Bool {
    precondition(pid > 1)
    return getpgid(pid) == -1 && errno == ESRCH
}

/// Polls `condition` every 10 ms until it holds, for up to `limit`.
func waitFor(
    within limit: Duration = .seconds(15), _ condition: @Sendable () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition still false after \(limit)", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// How many of this process's descriptors are pipes.
nonisolated func openPipeCount() -> Int {
    var count = 0
    for descriptor in 0..<min(getdtablesize(), 4096) {
        var info = stat()
        if fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFIFO { count += 1 }
    }
    return count
}

extension SignalRecorder {
    /// A recorder that also passes each call on, for tests that need the signal to land.
    convenience init(forwardingTo systemCall: @escaping ProcessGroups.SystemCall) {
        self.init(result: 0, forward: systemCall)
    }
}
