import Foundation
import Kit
import Testing
import UniformTypeIdentifiers

@testable import Platform

/// Watches only fresh temporary folders.
@Suite(.timeLimit(.minutes(1))) struct FileWatchTests {
    @Test func aNewFileIsReportedInTheCallersSpelling() async throws {
        let folder = TemporaryFolder()
        let watcher = FSEventsWatcher(latency: .milliseconds(50))
        let changes = watcher.watch([folder.url])
        #expect(watcher.openStreamCount == 1)
        let file = folder.url.appending(path: "notes.txt")
        let reported = Task {
            for await batch in changes where batch.contains(where: { $0.lastPathComponent == "notes.txt" }) {
                return batch
            }
            return []
        }
        // FSEvents may start a moment after the call returns; write until the change is seen.
        let writer = Task {
            for attempt in 0..<50 where !Task.isCancelled {
                try? Data("attempt \(attempt)".utf8).write(to: file)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let batch = await boundedValue(of: reported)
        writer.cancel()
        let match = try #require(batch.first { $0.lastPathComponent == "notes.txt" })
        let folderPath = folder.url.path(percentEncoded: false)
        #expect(match.path(percentEncoded: false).hasPrefix(folderPath))
        withExtendedLifetime(folder) {}
    }

    @Test func cancellingTheConsumerStopsTheStream() async throws {
        let folder = TemporaryFolder()
        let watcher = FSEventsWatcher()
        let changes = watcher.watch([folder.url])
        let consumer = Task {
            for await _ in changes {}
        }
        #expect(watcher.openStreamCount == 1)
        consumer.cancel()
        await boundedValue(of: consumer)
        try await waitUntil { watcher.openStreamCount == 0 }
        withExtendedLifetime(folder) {}
    }

    @Test func watchingNothingEndsAtOnce() async {
        let watcher = FSEventsWatcher()
        var iterator = watcher.watch([]).makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(watcher.openStreamCount == 0)
    }

    @Test func realPathsMapBackToTheRequestedFolder() {
        let paths = WatchedPaths(roots: [
            (requested: "/var/folders/xy/T/watched/", real: "/private/var/folders/xy/T/watched"),
            (requested: "/synthetic/other", real: "/synthetic/other"),
        ])
        #expect(paths.realPaths == ["/private/var/folders/xy/T/watched", "/synthetic/other"])
        #expect(
            paths.requestedURL(forEventPath: "/private/var/folders/xy/T/watched/a.txt")?.path(percentEncoded: false)
                == "/var/folders/xy/T/watched/a.txt")
        #expect(
            paths.requestedURL(forEventPath: "/synthetic/other/sub/b")?.path(percentEncoded: false)
                == "/synthetic/other/sub/b")
        #expect(paths.requestedURL(forEventPath: "/synthetic/otherness/c") == nil)
        #expect(paths.requestedURL(forEventPath: "/elsewhere/d") == nil)
        let batch = paths.requestedURLs(forEventPaths: [
            "/synthetic/other/x", "/private/var/folders/xy/T/watched/y", "/synthetic/other/x", "/elsewhere",
        ])
        #expect(batch.map { $0.path(percentEncoded: false) } == ["/synthetic/other/x", "/var/folders/xy/T/watched/y"])
    }
}

/// The dialogs themselves never open in tests; only their configuration is checked.
@Suite struct FileDialogTests {
    @Test func allowedTypesBecomeContentTypes() {
        #expect(DialogTypes.contentTypes(for: ["png", ".jpg", "public.json", "png"]) == [.png, .jpeg, .json])
        #expect(DialogTypes.contentTypes(for: []).isEmpty)
    }

    @Test func outsideLiveEveryDialogIsCancelled() async {
        let dialogs = CancellingFileDialogs()
        #expect(await dialogs.chooseFiles(OpenDialogRequest(allowsMultiple: true)).isEmpty)
        #expect(await dialogs.chooseSaveLocation(SaveDialogRequest(suggestedName: "export.json")) == nil)
    }
}
