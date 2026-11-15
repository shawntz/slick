import Foundation
import Kit

/// A process service that runs nothing, for run environments other than `live`: every stream fails
/// at once with ``ProcessError/launchFailed(_:)``. A scenario that needs a process uses a fake.
nonisolated public struct RefusingProcesses: ProcessService {
    public let environment: RunEnvironment

    public init(environment: RunEnvironment) {
        self.environment = environment
    }

    public func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let reason = "\(request.executable.lastPathComponent): \(PlatformServiceError.unavailable(environment))"
        return AsyncThrowingStream { $0.finish(throwing: ProcessError.launchFailed(reason)) }
    }
}

/// An HTTP service with no network, for run environments other than `live`: every request throws
/// ``PlatformServiceError/unavailable(_:)``. A scenario that needs answers uses a fake.
nonisolated public struct RefusingHTTP: HTTPService {
    public let environment: RunEnvironment

    public init(environment: RunEnvironment) {
        self.environment = environment
    }

    @concurrent public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw PlatformServiceError.unavailable(environment)
    }

    @concurrent public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        throw PlatformServiceError.unavailable(environment)
    }
}
