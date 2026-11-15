import Foundation

/// Watches folders for changes, such as a folder of script commands.
public protocol FileWatchService: Sendable {
    /// Yields the paths that changed under the folders, coalesced over a short interval. Each call
    /// returns its own stream; watching stops when the consuming task is cancelled.
    func watch(_ directories: [URL]) -> AsyncStream<[URL]>
}
