import Foundation
import Kit
import Observation

/// The toast the settings window shows at the bottom: from a feature's button, through
/// ``SettingsActionHost``, or from the window's own work, such as a login item the system refused.
@Observable final class ToastCenter {
    /// One toast on screen.
    struct Shown: Identifiable {
        var id: ToastID
        var toast: Toast
    }

    private(set) var current: Shown?
    /// Seconds a toast without a spinner stays. Zero keeps it until replaced, for tests.
    @ObservationIgnored var lifetime: Duration = .seconds(4)
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var nextID: UInt64 = 1 << 32

    /// Shows a toast, or replaces the one with the same ID.
    func show(_ toast: Toast, id: ToastID) {
        current = Shown(id: id, toast: toast)
        expiry?.cancel()
        guard toast.style != .progress, lifetime > .zero else { return }
        let lifetime = self.lifetime
        expiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, self?.current?.id == id else { return }
            self?.current = nil
        }
    }

    /// Shows a toast that the window made itself.
    func show(_ toast: Toast) {
        nextID += 1
        show(toast, id: ToastID(nextID))
    }

    /// Shows a failure toast for an error, as the host does for a failed action. A cancellation
    /// shows nothing.
    func show(_ error: any Error, title fallback: String) {
        guard !(error is CancellationError) else { return }
        show(.failure(ErrorText.title(error, fallback: fallback), message: ErrorText.message(error)))
    }

    func dismiss(_ id: ToastID) {
        guard current?.id == id else { return }
        current = nil
    }

    func dismissCurrent() {
        current = nil
    }
}

/// How an error reads in a toast.
enum ErrorText {
    static func title(_ error: any Error, fallback: String) -> String {
        if let failure = error as? ActionFailure { return failure.title }
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return fallback
    }

    static func message(_ error: any Error) -> String? {
        if let failure = error as? ActionFailure { return failure.message }
        if let localized = error as? any LocalizedError { return localized.failureReason }
        return nil
    }
}
