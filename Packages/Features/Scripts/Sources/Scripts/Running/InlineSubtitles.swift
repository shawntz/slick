import Foundation
import Kit
import Synchronization

/// The last subtitle of each inline script, by command ID, and a signal per script that refreshes
/// its subtitle at once.
///
/// An inline script runs by itself only when the user turned on automatic refresh for it. Until
/// then its subtitle shows what its last manual run printed.
nonisolated final class InlineSubtitles: Sendable {
    private let values = Mutex<[String: LiveSubtitle.Value]>([:])
    private let signals = Mutex<[String: ChangeSignal]>([:])

    func value(for commandID: String) -> LiveSubtitle.Value? {
        values.withLock { $0[commandID] }
    }

    func set(_ value: LiveSubtitle.Value, for commandID: String) {
        values.withLock { $0[commandID] = value }
    }

    /// The script's signal, the same object on every call, so the host keeps listening across
    /// rescans.
    func signal(for commandID: String) -> ChangeSignal {
        signals.withLock { signals in
            if let signal = signals[commandID] { return signal }
            let signal = ChangeSignal()
            signals[commandID] = signal
            return signal
        }
    }

    /// The subtitle for an inline script's output: its first line, red when the script failed.
    static func value(for output: CapturedOutput) -> LiveSubtitle.Value {
        guard output.exitCode == 0 else {
            return LiveSubtitle.Value(output.failureLine ?? Strings.failedWithCode(output.exitCode), color: .red)
        }
        guard let raw = OutputText.firstRawLine(output.output), let line = OutputText.firstLine(raw) else {
            return LiveSubtitle.Value("")
        }
        return LiveSubtitle.Value(line, color: ANSI.leadingColor(raw))
    }

    /// The subtitle for an error from ``ScriptExecution/capture(_:_:limit:)``, or nil for
    /// cancellation, which keeps the previous subtitle.
    static func value(for error: any Error, title: String, settings: RunSettings) -> LiveSubtitle.Value? {
        guard let failure = ScriptExecution.failure(for: error, title: title, settings: settings) else { return nil }
        return LiveSubtitle.Value(failure.title, color: .red)
    }
}
