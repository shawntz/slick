import Kit
import Synchronization

/// Secrets in memory, by full name `<feature id>.<name>`.
public final class FakeSecrets: SecretService {
    private let state = Mutex<[String: String]>([:])

    public init() {}

    /// Every stored secret by full name.
    public var values: [String: String] { state.withLock { $0 } }

    public func secret(for name: String) async throws -> String? {
        state.withLock { $0[name] }
    }

    public func setSecret(_ value: String?, for name: String) async throws {
        state.withLock { $0[name] = value }
    }
}
