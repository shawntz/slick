import Kit
import KitHosting

extension RootSearch {
    /// How many remembered IDs one ``RememberedRowValidator`` call checks.
    static let validationBatch = 200

    /// Asks each source that can tell, in batches and off the keystroke path, which of its
    /// remembered rows still exist, and forgets the rest so dead rows stop ranking. Runs once the
    /// stored rows are loaded and on the hourly tick.
    func validateRememberedRows() {
        guard !isShutDown else { return }
        var groups: [ObjectIdentifier: (validator: any RememberedRowValidator, ids: [ItemID])] = [:]
        for id in memory.rememberedIDs() {
            guard let validator = plan.owners[id.namespace]?.actions as? any RememberedRowValidator else { continue }
            groups[ObjectIdentifier(validator), default: (validator, [])].ids.append(id)
        }
        guard !groups.isEmpty else { return }
        beginWork()
        Task { [weak self, memory] in
            var removed = false
            for group in groups.values {
                var start = 0
                while start < group.ids.count {
                    let batch = Array(group.ids[start..<min(start + Self.validationBatch, group.ids.count)])
                    start += batch.count
                    let existing = await group.validator.existingItems(among: batch)
                    for id in batch where !existing.contains(id) {
                        removed = memory.forget(id) || removed
                    }
                }
            }
            if removed { self?.scheduleRebuild() }
            self?.endWork()
        }
    }
}
