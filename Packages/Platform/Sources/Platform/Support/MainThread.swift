import Foundation
import Kit

/// Runs AppKit and Carbon work on the main thread from synchronous code that may run anywhere.
nonisolated enum MainThread {
    /// Runs `body` on the main thread and returns its result. On the main thread it runs at once;
    /// elsewhere it waits for the main thread, so call it only for short work.
    static func run<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(body)
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated(body)
        }
    }
}

/// Why a Platform service refused a call.
nonisolated public enum PlatformServiceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The service has no side effects in this run environment, such as opening a URL during a
    /// scenario. Outside `live` nothing reaches the real Mac.
    case unavailable(RunEnvironment)

    public var description: String {
        switch self {
        case .unavailable(let environment): "not available in the \(environment.rawValue) environment"
        }
    }
}
