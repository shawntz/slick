import Dispatch
import Kit
import Synchronization

/// The live settings service.
///
/// It loads every value from its backend once, when it is made, and from then on reads come from
/// memory under a lock that is never held across I/O, so an instant provider may read a setting on
/// every keystroke. A write updates memory at once and reaches the backend on a serial background
/// queue, in order. Make it at launch, before the panel can open, because loading reads the disk.
///
/// A write that leaves a value as it was does not notify. Values changed behind the service's back,
/// such as with `defaults write`, are not seen until the next launch.
nonisolated public final class PlatformSettings: SettingsService {
    private let values: Mutex<[String: SettingStorage]>
    private let backend: any SettingsBackend
    private let writer = DispatchQueue(label: "platform.settings.writer", qos: .utility)
    private let changed = Broadcast<String>()

    public init(backend: any SettingsBackend) {
        self.backend = backend
        values = Mutex(backend.loadAll())
    }

    public func storage(for name: String) -> SettingStorage? {
        values.withLock { $0[name] }
    }

    public func set(_ storage: SettingStorage?, for name: String) {
        let backend = backend
        let didChange = values.withLock { values -> Bool in
            guard values[name] != storage else { return false }
            values[name] = storage
            // Queue the write while holding the lock, so two writers reach the disk in the same
            // order they reached memory.
            writer.async { backend.write(storage, for: name) }
            return true
        }
        if didChange { changed.send(name) }
    }

    public func changes(for names: Set<String>) -> AsyncStream<String> {
        changed.stream { names.contains($0) ? $0 : nil }
    }

    /// Waits until every write made so far has reached the backend. Call it before the app quits,
    /// and in tests before reading the backend.
    public func flush() {
        writer.sync {}
    }

    /// How many change streams are open.
    public var listenerCount: Int {
        changed.listenerCount
    }
}
