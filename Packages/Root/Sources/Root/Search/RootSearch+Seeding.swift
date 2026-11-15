import CoreBridge
import Foundation
import Kit
import os

extension RootSearch {
    /// Seeds the engine with ``RootConfiguration/firstRunSeeds`` once: when the engine is open,
    /// `learning.json` is loaded, no seeding ran before and nothing was learned yet. Runs off the main
    /// thread. Afterwards it never runs again, also not after an erase.
    func seedIfFirstRun() {
        guard !seedingStarted, isOpen, learning.isLoaded, !isShutDown, let provider = configuration.firstRunSeeds
        else { return }
        seedingStarted = true
        guard !learning.read(\.seeded) else { return }
        beginWork()
        let hasUses = memory.lastUse() != nil
        Task { [weak self] in
            guard let self else { return }
            if !hasUses, await !self.engineHasLearned() {
                let seeds = LearningSeed.merged(await Self.gatherSeeds(provider))
                await self.applySeeds(seeds)
                self.log.info("root search seeded \(seeds.count, privacy: .public) items for the first run")
            }
            self.learning.update { $0.seeded = true }
            self.refreshContext()
            self.endWork()
        }
    }

    /// Calls App's seed provider off the main thread.
    @concurrent nonisolated static func gatherSeeds(
        _ provider: @Sendable () async -> [LearningSeed]
    ) async -> [LearningSeed] {
        await provider()
    }

    /// True when the engine holds a run or a seed.
    private func engineHasLearned() async -> Bool {
        guard let statistics = await engineStatistics() else { return false }
        return statistics.counts.events > 0 || statistics.counts.seeds > 0
    }

    /// Gives each seed to the engine on its queue and returns when that is done.
    private func applySeeds(_ seeds: [LearningSeed]) async {
        guard !seeds.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.perform { engine in
                for seed in seeds {
                    try? engine?.seed(
                        ItemKey(rawValue: seed.id.engineKey), weight: Float(seed.weight),
                        at: seed.lastUsed.timeIntervalSince1970)
                }
                continuation.resume()
            }
        }
    }

    /// The engine's learning statistics, read and decoded on its queue. Nil without an engine or
    /// when they do not decode.
    func engineStatistics() async -> EngineStatistics? {
        await withCheckedContinuation { (continuation: CheckedContinuation<EngineStatistics?, Never>) in
            worker.perform { engine in
                guard let json = try? engine?.statisticsJSON() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: try? JSONDecoder().decode(EngineStatistics.self, from: Data(json.utf8)))
            }
        }
    }
}

/// The parts of the engine's statistics JSON root search reads.
nonisolated struct EngineStatistics: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        var events: Int
        var seeds: Int
    }

    /// One learned query and its items, as the engine names them: keys as decimal strings, titles
    /// as the catalog had them.
    struct AffinityRow: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            var key: String
            var title: String?
            var weight: Double?
        }

        var query: String
        /// The key of the item that holds the learned band for this query, as a decimal string.
        /// Nil when none does, or from an engine that does not report it.
        var band: String?
        var items: [Item]
    }

    var paused: Bool?
    var counts: Counts
    var affinity: [AffinityRow]
}
