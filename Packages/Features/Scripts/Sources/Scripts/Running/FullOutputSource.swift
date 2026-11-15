import Foundation
import Kit

/// A full output script's page: the output streams in as it arrives, in a monospaced body whose
/// ANSI colors the host draws, and the status and run time show when it ends.
///
/// Leaving the page ends the stream, which ends the script. Stop Script ends it while the page
/// stays. Output past the limit in settings ends it too.
final class FullOutputSource: DetailSource {
    private let script: Script
    private let request: ProcessRequest
    private let processes: any ProcessService
    private let clock: any ClockService
    private let settings: RunSettings

    private var run: Task<Void, Never>?
    /// True from the start of a run until its last update.
    private(set) var isRunning = false
    let actionsChanged: ChangeSignal? = ChangeSignal()

    init(
        script: Script, request: ProcessRequest, processes: any ProcessService, clock: any ClockService,
        settings: RunSettings
    ) {
        self.script = script
        self.request = request
        self.processes = processes
        self.clock = clock
        self.settings = settings
    }

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        run?.cancel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DetailUpdate.self)
        let events = processes.textStream(request)
        let (clock, limit, limitName) = (clock, settings.outputLimit, settings.outputLimitName)
        let started = clock.now
        setRunning(true)
        let task = Task { [weak self] in
            let ending = await Self.relay(events, into: continuation, limit: limit, limitName: limitName)
            self?.setRunning(false)
            let seconds = clock.now.timeIntervalSince(started)
            continuation.yield(.metadata(Self.metadata(ending, seconds: seconds, locale: clock.locale)))
            continuation.finish()
        }
        run = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The host passes what it shows, so the source keeps no copy of the output.
    func actions(for detail: Detail) -> [Action] {
        var actions: [Action] = []
        if case .text(let output, _) = detail.body, !output.isEmpty {
            actions.append(
                .copy(ANSI.strip(output), title: Strings.copyOutput, shortcut: .copy).with(id: "copy-output"))
        }
        if isRunning {
            actions.append(
                Action(Strings.stopScript, id: "stop", icon: .symbol("stop.fill"), shortcut: KeyCombo(.c, .control)) {
                    [weak self] _ in
                    self?.stop()
                    return .keepOpen
                })
        } else {
            actions.append(
                Action(Strings.runAgain, id: "run-again", icon: .symbol("arrow.clockwise"), shortcut: .refresh) {
                    context in
                    context.reload()
                    return .keepOpen
                })
        }
        actions.append(.openWith(script.url, title: Strings.editWith).with(id: "edit-with"))
        actions.append(.reveal([script.url]))
        return actions
    }

    /// Ends the running script. The page shows that it stopped.
    func stop() {
        run?.cancel()
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        actionsChanged?.send()
    }

    /// How a run ended.
    enum Ending: Hashable, Sendable {
        case exit(Int32)
        case stopped
        case timedOut
        case overLimit
        case couldNotStart(String)
    }

    /// Appends the output as it arrives, off the main thread, and says how the run ended.
    @concurrent private static func relay(
        _ events: AsyncThrowingStream<ProcessTextEvent, any Error>,
        into continuation: AsyncThrowingStream<DetailUpdate, any Error>.Continuation,
        limit: Int, limitName: String
    ) async -> Ending {
        let running: [MetadataItem] = [.label(Strings.statusLabel, value: Strings.statusRunning)]
        continuation.yield(.replace(Detail(.text("", monospaced: true), metadata: running)))
        var shown = 0
        var exitCode: Int32?
        do {
            for try await event in events {
                switch event {
                case .stdout(let text), .stderr(let text):
                    let size = text.utf8.count
                    guard shown + size <= limit else {
                        // Leaving the loop drops the stream, which ends the process.
                        let room = max(0, limit - shown)
                        continuation.yield(.append(String(decoding: Array(text.utf8.prefix(room)), as: UTF8.self)))
                        continuation.yield(.append(Strings.outputCut(limit: limitName)))
                        return .overLimit
                    }
                    shown += size
                    continuation.yield(.append(text))
                case .exit(let code):
                    exitCode = code
                }
            }
        } catch ProcessError.timedOut {
            return .timedOut
        } catch ProcessError.launchFailed(let reason) {
            return .couldNotStart(reason)
        } catch {
            return .stopped
        }
        if Task.isCancelled { return .stopped }
        return exitCode.map(Ending.exit) ?? .stopped
    }

    static func metadata(_ ending: Ending, seconds: TimeInterval, locale: Locale) -> [MetadataItem] {
        let status: MetadataItem =
            switch ending {
            case .exit(0):
                .label(
                    Strings.statusLabel, value: Strings.statusFinished,
                    icon: .symbol("checkmark.circle", tint: .green))
            case .exit(let code):
                .label(
                    Strings.statusLabel, value: Strings.statusExitCode(code), icon: .symbol("xmark.circle", tint: .red))
            case .stopped: .label(Strings.statusLabel, value: Strings.statusStopped)
            case .timedOut: .label(Strings.statusLabel, value: Strings.statusTimedOut)
            case .overLimit: .label(Strings.statusLabel, value: Strings.statusOverLimit)
            case .couldNotStart(let reason):
                .label(
                    Strings.statusLabel, value: Strings.statusCouldNotStart(reason),
                    icon: .symbol("xmark.circle", tint: .red))
            }
        let runTime = max(0, seconds).formatted(.number.precision(.fractionLength(1)).locale(locale))
        return [status, .label(Strings.runTimeLabel, value: Strings.seconds(runTime))]
    }
}
