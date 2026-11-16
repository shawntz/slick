import Foundation
import Kit
import Synchronization

/// File dialogs for scenarios. Each open dialog hands back the files a `chooseFiles` step queued
/// for it, oldest first, and cancels when nothing is queued. A save dialog always cancels. Every
/// request is kept, so a step can check what was asked. Nothing is ever shown.
nonisolated final class ScenarioFileDialogs: FileDialogService {
    private struct State {
        var answers: [[URL]] = []
        var openRequests: [OpenDialogRequest] = []
        var saveRequests: [SaveDialogRequest] = []
    }

    private let state = Mutex(State())

    init() {}

    /// The files the next open dialog hands back, as if the user chose them there.
    func queue(_ files: [URL]) {
        state.withLock { $0.answers.append(files) }
    }

    /// Every open dialog asked for, oldest first.
    var openRequests: [OpenDialogRequest] { state.withLock { $0.openRequests } }

    /// Every save dialog asked for, oldest first.
    var saveRequests: [SaveDialogRequest] { state.withLock { $0.saveRequests } }

    func chooseFiles(_ request: OpenDialogRequest) async -> [URL] {
        state.withLock { state in
            state.openRequests.append(request)
            return state.answers.isEmpty ? [] : state.answers.removeFirst()
        }
    }

    func chooseSaveLocation(_ request: SaveDialogRequest) async -> URL? {
        state.withLock { $0.saveRequests.append(request) }
        return nil
    }
}

/// Made-up files in the run's own home folder, which the scenario environment shows as "~".
/// Paths are relative to it, and one that climbs out or starts at the root is refused, so a
/// scenario never writes anywhere else.
nonisolated enum ScenarioHomeFiles {
    /// The file at `path` inside `home`, or nil for a path that is empty, absolute or climbs out.
    static func resolve(_ path: String, in home: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return home.appending(path: path, directoryHint: .notDirectory)
    }

    /// Writes each text to its path in `home`, making folders on the way. Returns the problems.
    static func write(_ files: [String: String], in home: URL) -> [String] {
        var problems: [String] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            guard let url = resolve(path, in: home) else {
                problems.append("makeFiles takes a path inside the run's home folder, not \(path)")
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                problems.append("makeFiles cannot write \(path): \(error.localizedDescription)")
            }
        }
        return problems
    }
}
