import Kit
import Synchronization

/// Settings in memory, with change streams that behave like the live service's: a write that
/// leaves the stored value as it was sends no change.
public final class FakeSettings: SettingsService {
    private let state = Mutex<[String: SettingStorage]>([:])
    private let broadcast = FakeBroadcast<String>()

    public init() {}

    /// Every stored value by full name, `<feature id>.<key>`.
    public var values: [String: SettingStorage] { state.withLock { $0 } }

    /// Returns once every change stream's consumer has handled every change it received.
    public func settle() async {
        await broadcast.waitUntilIdle()
    }

    var isSettled: Bool { broadcast.isIdle }

    public func storage(for name: String) -> SettingStorage? {
        state.withLock { $0[name] }
    }

    public func set(_ storage: SettingStorage?, for name: String) {
        let changed = state.withLock { values in
            guard values[name] != storage else { return false }
            values[name] = storage
            return true
        }
        if changed { broadcast.send(name) }
    }

    public func changes(for names: Set<String>) -> AsyncStream<String> {
        broadcast.stream { names.contains($0) ? $0 : nil }
    }
}
