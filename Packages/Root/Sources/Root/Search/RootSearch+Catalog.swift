import CoreBridge
import Foundation
import Kit
import KitHosting
import os

extension RootSearch {
    // MARK: Directory

    /// Reads the directory again: commands, providers, owners and catalog sources. New sources load,
    /// sources that left stop, and the catalog is rebuilt.
    func readDirectory() {
        guard !isShutDown else { return }
        plan = DirectoryPlan(features: configuration.directory.features, builtInSources: configuration.builtInSources)
        reconcileSources()
        reconcileTriggers()
        fallbacks = plan.fallbackList(chosen: settingsCache.fallbackCommands)
        pruneSubtitleValues()
        reconcileVisibleRows()
        refreshLiveSubtitles()
        scheduleRebuild()
    }

    private func reconcileSources() {
        var next: [ObjectIdentifier: SourceSlot] = [:]
        var order: [ObjectIdentifier] = []
        var fresh: [SourceSlot] = []
        for wanted in plan.sources {
            let id = ObjectIdentifier(wanted.source)
            guard next[id] == nil else { continue }
            if let slot = slots[id], slot.featureID == wanted.featureID {
                next[id] = slot
            } else {
                let slot = SourceSlot(source: wanted.source, featureID: wanted.featureID)
                listen(to: slot, settings: wanted.settings)
                next[id] = slot
                fresh.append(slot)
            }
            order.append(id)
        }
        for (id, slot) in slots where next[id] !== slot {
            slot.stop()
        }
        slots = next
        slotOrder = order
        for slot in fresh { load(slot) }
    }

    /// Loads a source again when it signals a change or one of its settings changes.
    private func listen(to slot: SourceSlot, settings: FeatureSettings?) {
        if let signal = slot.source.changes {
            let stream = signal.stream()
            slot.listeners.append(
                Task { [weak self, weak slot] in
                    for await _ in stream {
                        guard let self, let slot else { return }
                        self.load(slot)
                    }
                })
        }
        let keys = slot.source.reloadsOnSettings
        if let settings, !keys.isEmpty {
            slot.listeners.append(
                Task { [weak self, weak slot] in
                    for await _ in settings.changes(ofAny: keys) {
                        guard let self, let slot else { return }
                        self.load(slot)
                    }
                })
        }
    }

    /// Loads a source's rows off the keystroke path. A load that throws keeps the rows it had. A
    /// change during a load runs one more load after it.
    func load(_ slot: SourceSlot) {
        guard !isShutDown else { return }
        guard !slot.isLoading else {
            slot.reloadRequested = true
            return
        }
        slot.isLoading = true
        beginWork()
        Task { [weak self] in
            do {
                slot.rows = try await slot.source.rows()
                self?.sourceLoaded(slot)
            } catch {
                self?.log.error(
                    "catalog source \(slot.source.namespace, privacy: .public) failed, keeping its rows: \(error)")
            }
            slot.isLoading = false
            if slot.reloadRequested {
                slot.reloadRequested = false
                self?.load(slot)
            }
            self?.endWork()
        }
    }

    private func sourceLoaded(_ slot: SourceSlot) {
        guard slots[ObjectIdentifier(slot.source)] === slot else { return }
        scheduleRebuild()
    }

    // MARK: Rebuild

    /// Rebuilds the engine's catalog and the row table on the engine queue, then swaps the table in
    /// on the main thread. Requests that arrive during a rebuild collapse into one more.
    func scheduleRebuild() {
        guard !isShutDown else { return }
        guard !rebuildRunning else {
            rebuildAgain = true
            return
        }
        rebuildRunning = true
        beginWork()
        let inputs = catalogInputs()
        let now = configuration.clock.now
        let log = log
        worker.perform { [weak self] engine in
            let built = CatalogBuilder.build(inputs, now: now)
            do throws(CoreError) {
                try engine?.replaceSource(CatalogBuilder.engineSource, with: built.items)
            } catch {
                log.error("the engine refused the catalog: \(error)")
            }
            let table = built.table
            Task { @MainActor [weak self] in self?.finishRebuild(table) }
        }
    }

    private func catalogInputs() -> CatalogInputs {
        var inputs = CatalogInputs()
        inputs.commands = plan.commands
        inputs.sources = slotOrder.compactMap { slots[$0] }.map {
            CatalogInputs.SourceInput(featureID: $0.featureID, rows: $0.rows)
        }
        inputs.memory = memory
        inputs.owners = plan.ownerFeatures
        return inputs
    }

    private func finishRebuild(_ next: CatalogTable) {
        install(next)
        // The old table is freed on the engine queue: 10,000 rows take the main thread a while.
        worker.sweep()
        rebuildRunning = false
        prepareEmptySnapshot()
        reconcileVisibleRows()
        scheduleExpiry()
        if rebuildAgain {
            rebuildAgain = false
            scheduleRebuild()
        }
        endWork()
    }

    /// Swaps the table in and hands the old one to the engine queue. The old table's last reference
    /// must leave this function before the queue frees it, so it lives only in a local here.
    private func install(_ next: CatalogTable) {
        var retired = next
        swap(&table, &retired)
        worker.bury(retired)
    }

    /// Rebuilds the catalog when the next row expires, so it drops out without a reload.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiry = table.earliestExpiry, !isShutDown else { return }
        let clock = configuration.clock
        expiryTask = Task { [weak self] in
            let wait = expiry.timeIntervalSince(clock.now)
            if wait > 0 {
                do { try await clock.sleep(for: .seconds(wait)) } catch { return }
            }
            self?.scheduleRebuild()
        }
    }
}
