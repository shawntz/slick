import Kit
import Observation

/// A counter that views read and models bump, so a computed property that reads a store refreshes
/// when the store changed behind the model's back.
///
/// Models compute what they show from their sources on every read, so a test sees a write at once.
/// The counter only tells SwiftUI to read again.
@Observable final class Revision {
    private(set) var value = 0

    /// Registers the reader for the next ``bump()``.
    func track() {
        _ = value
    }

    /// Tells every reader that what it read may have changed.
    func bump() {
        value &+= 1
    }
}

/// The tasks a model keeps running, cancelled when the model goes away.
final class TaskBag {
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        tasks.append(task)
    }

    /// Bumps `revision` each time `signal` fires.
    func follow(_ signal: ChangeSignal, bumping revision: Revision) {
        let stream = signal.stream()
        add(
            Task { [weak revision] in
                for await _ in stream { revision?.bump() }
            })
    }

    /// Bumps `revision` each time one of `keys` changes in `settings`.
    func follow(_ keys: [AnySettingKey], in settings: FeatureSettings, bumping revision: Revision) {
        guard !keys.isEmpty else { return }
        let stream = settings.changes(ofAny: keys)
        add(
            Task { [weak revision] in
                for await _ in stream { revision?.bump() }
            })
    }

    func cancelAll() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }
}
