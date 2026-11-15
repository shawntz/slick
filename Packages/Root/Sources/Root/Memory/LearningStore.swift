import Foundation
import Kit
import Synchronization
import os

/// What root search learns beside the engine, kept in `learning.json`: whether first-run seeding
/// happened, when the first run was recorded, and how the user responds to each trigger type.
///
/// Reads and writes are in-memory and safe from any thread. Every change queues one save on a
/// utility queue; saves that pile up collapse into one.
nonisolated final class LearningStore: Sendable {
    struct State: Codable, Sendable {
        /// True once first-run seeding ran or was skipped. Erasing keeps it, so an erase does not
        /// seed again.
        var seeded = false
        /// When the first run was recorded. Nil after an erase until the next run.
        var firstEvent: Date?
        /// Per trigger type, by `<feature id>.<trigger id>`.
        var triggers: [String: TriggerStats] = [:]
        /// Ignored suggestions, by `<feature id>.<trigger id>` and the suggestion ID.
        var ignored: [String: IgnoredSuggestion] = [:]
    }

    private struct Box {
        var state = State()
        var loaded = false
        var saveQueued = false
    }

    private let box = Mutex(Box())
    private let io = DispatchQueue(label: "root.learning", qos: .utility)
    private let file: URL?
    private let log = KitLog.logger(category: "root")

    init(file: URL?) {
        self.file = file
    }

    /// The current state.
    var state: State {
        box.withLock { $0.state }
    }

    /// True once ``load()`` finished.
    var isLoaded: Bool {
        box.withLock { $0.loaded }
    }

    /// Reads part of the state.
    func read<T>(_ body: (State) -> T) -> T {
        box.withLock { body($0.state) }
    }

    /// Changes the state and queues a save.
    func update(_ body: (inout State) -> Void) {
        let queue = box.withLock { box in
            body(&box.state)
            guard !box.saveQueued else { return false }
            box.saveQueued = true
            return true
        }
        if queue { io.async { self.save() } }
    }

    /// Reads the file. What was recorded before the load wins over what the file says.
    func load() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            io.async {
                let stored = self.readFile()
                self.box.withLock { box in
                    if let stored {
                        box.state.seeded = box.state.seeded || stored.seeded
                        box.state.firstEvent = [box.state.firstEvent, stored.firstEvent].compactMap { $0 }.min()
                        box.state.triggers.merge(stored.triggers) { current, _ in current }
                        box.state.ignored.merge(stored.ignored) { current, _ in current }
                    }
                    box.loaded = true
                }
                continuation.resume()
            }
        }
    }

    /// Returns once every save queued so far is written.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            io.async { continuation.resume() }
        }
    }

    private func readFile() -> State? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            log.error("root search could not read \(file.lastPathComponent, privacy: .public): \(error)")
            return nil
        }
    }

    private func save() {
        let state = box.withLock { box in
            box.saveQueued = false
            return box.state
        }
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else {
            log.error("root search could not encode \(file.lastPathComponent, privacy: .public)")
            return
        }
        JSONFiles.write(data, to: file, log: log)
    }
}
