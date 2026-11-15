import Kit
import Observation

/// Questions the settings window asks before it runs something, such as a feature button's
/// confirmation or erasing everything learned. The root view shows the pending one as an alert.
@Observable final class ConfirmationCenter {
    /// One question waiting for an answer.
    struct Pending: Identifiable {
        let id: Int
        let confirmation: Confirmation
        fileprivate let answer: CheckedContinuation<Bool, Never>
    }

    private(set) var pending: Pending?
    @ObservationIgnored private var nextID = 0

    /// Asks and returns true if the user went ahead. A question still open is answered no.
    func ask(_ confirmation: Confirmation) async -> Bool {
        if let open = pending {
            pending = nil
            open.answer.resume(returning: false)
        }
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { continuation in
            pending = Pending(id: id, confirmation: confirmation, answer: continuation)
        }
    }

    /// Answers the open question.
    func answer(_ goAhead: Bool) {
        guard let open = pending else { return }
        pending = nil
        open.answer.resume(returning: goAhead)
    }
}
