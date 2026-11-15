import Foundation
import Kit
import KitHosting
import os

extension RootSearch {
    // MARK: Async providers

    /// Starts one task per pending provider for this query: the provider's debounce for the query,
    /// then its results. Every task carries the query's generation, so a result for an older query
    /// is dropped even when it ignores cancellation. Runs inside the keystroke, so it only creates
    /// the tasks; the providers' own calls happen after the keystroke.
    func startProviders(for query: String) {
        guard !pendingProviders.isEmpty else { return }
        providersOutstanding = pendingProviders.count
        let generation = queryGeneration
        let clock = configuration.clock
        for index in pendingProviders.indices {
            let provider = pendingProviders[index].provider
            providerTasks.append(
                Task { [weak self] in
                    let wait = provider.debounce(for: query)
                    if wait > .zero {
                        do { try await clock.sleep(for: wait) } catch { return }
                    }
                    guard !Task.isCancelled, self?.queryGeneration == generation else { return }
                    var rows: [Row] = []
                    do {
                        rows = try await provider.results(for: query)
                    } catch {
                        guard !Task.isCancelled, self?.queryGeneration == generation else { return }
                        self?.log.error(
                            "async provider \(provider.namespace, privacy: .public) failed, its section stays empty: \(error)"
                        )
                    }
                    guard !Task.isCancelled, let self, self.queryGeneration == generation else { return }
                    self.deliver(rows, title: provider.sectionTitle(for: query), at: index, generation: generation)
                })
        }
    }

    /// Returns once every provider task of the current query ended, for tests and the bench. A task
    /// still in its debounce ends only when the clock passes it or the query changes.
    @_spi(RootBench) public func providersFinished() async {
        let tasks = providerTasks
        for task in tasks { await task.value }
    }

    /// Cancels the providers of the previous query and forgets their sections.
    func cancelProviders() {
        if !providerTasks.isEmpty {
            for task in providerTasks { task.cancel() }
            providerTasks.removeAll(keepingCapacity: true)
        }
        pendingProviders.removeAll(keepingCapacity: true)
        providersOutstanding = 0
    }

    /// Puts an async provider's rows into its own section of the snapshot on screen and sends
    /// ``changes``.
    ///
    /// The section goes after every section before it in display order and before the fallbacks and
    /// the sections of later providers, so nothing above it moves and the selection stays where it
    /// is. Rows that already show elsewhere are left out, and at most ``AsyncProvider/maximumRows``
    /// remain unless the provider took the query over. Returns false, and changes nothing, when the
    /// query moved on or the provider already delivered.
    @discardableResult
    func deliver(_ rows: [Row], title: String, at index: Int, generation: Int) -> Bool {
        guard inSession, generation == queryGeneration, pendingProviders.indices.contains(index),
            !pendingProviders[index].isDone
        else { return false }
        let started = timings == nil ? 0 : Self.threadNanos()
        pendingProviders[index].isDone = true
        providersOutstanding = max(0, providersOutstanding - 1)
        let pending = pendingProviders[index]

        var next = snapshot
        next.sections.removeAll { $0.id == pending.sectionID }
        var shown: Set<ItemID> = []
        for section in next.sections {
            for row in section.rows { shown.insert(row.id) }
        }
        var kept: [Row] = []
        kept.reserveCapacity(min(rows.count, pending.maximumRows))
        for row in rows where kept.count < pending.maximumRows {
            if shown.insert(row.id).inserted { kept.append(row) }
        }
        if !kept.isEmpty {
            let later = Set(pendingProviders[(index + 1)...].map(\.sectionID))
            let position =
                next.sections.firstIndex { $0.kind == .fallbacks || later.contains($0.id) } ?? next.sections.endIndex
            next.sections.insert(
                RootSection(
                    id: pending.sectionID, title: title, rows: kept, kind: .provider(namespace: pending.namespace)),
                at: position)
        }
        next.isLoading = providersOutstanding > 0
        next.emptyState = next.sections.isEmpty && !next.isLoading ? Self.noResults : nil
        if next.completion == nil, settingsCache.inlineCompletion, next.sections.first?.id == pending.sectionID,
            let first = kept.first, let text = first.completion, !text.isEmpty
        {
            next.completion = RootCompletion(id: first.id, text: text)
        }
        _ = publish(next)
        if let timings { timings.deliveryNanos.append(Self.threadNanos() - started) }
        changes.send()
        refreshLiveSubtitles()
        return true
    }

    /// Drops the pending sections of providers that left the directory, such as when their feature
    /// was turned off. True when one was dropped.
    func dropDepartedProviders() -> Bool {
        guard !pendingProviders.isEmpty else { return false }
        let present = Set(plan.asyncProviders.map { ObjectIdentifier($0.provider) })
        var dropped = false
        for index in pendingProviders.indices
        where !pendingProviders[index].isDone && !present.contains(ObjectIdentifier(pendingProviders[index].provider)) {
            pendingProviders[index].isDone = true
            providersOutstanding = max(0, providersOutstanding - 1)
            dropped = true
        }
        return dropped
    }
}
