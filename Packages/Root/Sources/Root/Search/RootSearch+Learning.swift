import CoreBridge
import Foundation
import Kit
import KitHosting

/// What the engine queue needs to set the context, copied on the main thread.
nonisolated struct ContextInputs: Sendable {
    var system: SystemContext
    var now: Date
    var clock: any ClockService
    var lastRun: ContextBuilder.LastRun?
    var sessionStart: Bool
}

extension RootSearch {
    /// After this long without a run, the next context counts as a session start.
    static let idleSessionGap: TimeInterval = 2 * 3_600

    // MARK: Learning

    /// Records a run: a use with its snapshot, the remembered row for a live provider's row, and the
    /// engine's learning with the source the row was reached by. The engine work runs on its queue,
    /// so the main thread only copies values.
    ///
    /// A row whose memory is ``RowMemory/never`` records nothing, and nothing is recorded while
    /// learning is paused. Only a pick from typed results teaches the query: suggestions, favorites,
    /// hotkeys and fallbacks never do.
    public func didRun(_ row: Row, launch: LaunchSource) {
        guard !settingsCache.learningPaused, !isShutDown else { return }
        if launch == .suggestion || launch == .root { noteTriggerRun(row) }
        guard row.memory != .never else { return }
        let now = configuration.clock.now
        let pick = executionSource(for: row, launch: launch)
        var stored = row
        stored.titleHighlights = []
        memory.recordUse(of: row.id, snapshot: row.memory == .remember ? stored : nil, at: now)
        if row.memory == .remember, shouldRemember(row), memory.remember(stored, at: now) {
            scheduleRebuild()
        }
        if learning.read({ $0.firstEvent == nil }) {
            learning.update { $0.firstEvent = $0.firstEvent ?? now }
        }
        lastRun = ContextBuilder.LastRun(key: row.id.engineKey, at: now)
        sessionStart = false
        let key = ItemKey(rawValue: row.id.engineKey)
        let inputs = contextInputs(now: now)
        beginWork()
        worker.perform { [weak self] engine in
            _ = try? engine?.recordExecution(
                of: key, query: pick.query, source: pick.source, rank: pick.rank, at: now.timeIntervalSince1970)
            let suggestions = Self.applyContext(inputs, to: engine)
            Task { @MainActor [weak self] in self?.receive(suggestions, learned: true) }
        }
    }

    /// Forgets an item's query affinity and counts, its uses and its remembered row.
    public func forget(_ id: ItemID) {
        guard !isShutDown else { return }
        if memory.forget(id) { scheduleRebuild() }
        if lastRun?.key == id.engineKey { lastRun = nil }
        let key = ItemKey(rawValue: id.engineKey)
        let inputs = contextInputs(now: configuration.clock.now)
        beginWork()
        worker.perform { [weak self] engine in
            try? engine?.forget(key)
            let suggestions = Self.applyContext(inputs, to: engine)
            Task { @MainActor [weak self] in self?.receive(suggestions, learned: true) }
        }
    }

    /// How the row was reached, the query it teaches and its displayed position.
    func executionSource(for row: Row, launch: LaunchSource) -> (source: ExecutionSource, query: String, rank: Int?) {
        switch launch {
        case .suggestion:
            return (.suggestion, "", position(of: row.id)?.index)
        case .fallback, .tabFromRoot:
            return (.fallback, inSession ? snapshot.query : "", nil)
        case .hotkey, .deeplink, .command, .selection, .textExpansion, .settings, .page:
            return (.hotkey, "", nil)
        case .root:
            guard inSession, let found = position(of: row.id) else { return (.hotkey, "", nil) }
            if Self.isBlank(snapshot.query) { return (.suggestion, "", found.index) }
            switch found.kind {
            case .suggested, .favorites:
                return (.suggestion, "", found.index)
            case .fallbacks:
                return (.fallback, snapshot.query, found.index)
            case .answers, .results, .provider:
                let source: ExecutionSource = aliasHitKeys.contains(row.id.engineKey) ? .alias : .typed
                return (source, snapshot.query, found.index)
            }
        }
    }

    /// The section and overall position of a row on screen.
    private func position(of id: ItemID) -> (kind: RootSection.Kind, index: Int)? {
        var index = 0
        for section in snapshot.sections {
            for row in section.rows {
                if row.id == id { return (section.kind, index) }
                index += 1
            }
        }
        return nil
    }

    /// True for a row that only a live provider or a suggestion makes: no command and no catalog
    /// source holds its ID, and a source that is on owns its namespace.
    private func shouldRemember(_ row: Row) -> Bool {
        guard row.id.namespace != ItemID.ReservedNamespace.command, plan.owners[row.id.namespace] != nil else {
            return false
        }
        if let entry = table.entry(for: row.id), entry.origin != .remembered { return false }
        return true
    }

    // MARK: Context

    /// Sets the engine's context from the Mac's state, the clock and the last run, and prepares the
    /// empty-query snapshot from the new suggestions. Runs on a context change, a session start,
    /// the hourly tick and after a run, never inside ``begin()`` or ``update(query:)``.
    func refreshContext() {
        guard !isShutDown else { return }
        let inputs = contextInputs(now: configuration.clock.now)
        beginWork()
        worker.perform { [weak self] engine in
            let suggestions = Self.applyContext(inputs, to: engine)
            Task { @MainActor [weak self] in self?.receive(suggestions) }
        }
    }

    func contextInputs(now: Date) -> ContextInputs {
        let idle = lastRun.map { now.timeIntervalSince($0.at) > Self.idleSessionGap } ?? false
        return ContextInputs(
            system: configuration.systemContext.current(), now: now, clock: configuration.clock, lastRun: lastRun,
            sessionStart: sessionStart || idle)
    }

    /// Sets the context on the engine queue and returns the suggestions for it.
    nonisolated static func applyContext(_ inputs: ContextInputs, to engine: Engine?) -> [UInt64] {
        guard let engine else { return [] }
        let context = ContextBuilder.make(
            system: inputs.system, now: inputs.now, calendar: inputs.clock.calendar, lastRun: inputs.lastRun,
            sessionStart: inputs.sessionStart)
        try? engine.setContext(context)
        let suggestions = (try? engine.suggestions(limit: suggestionDepth)) ?? []
        return suggestions.map(\.key.rawValue)
    }

    /// Takes the engine's suggestions for the new context. `learned` says the engine's learning
    /// changed, which the learning inspector hears of.
    func receive(_ suggestions: [UInt64], learned: Bool = false) {
        suggestionKeys = suggestions
        prepareEmptySnapshot()
        if learned { inspector.changes.send() }
        endWork()
    }

    // MARK: Aliases and settings

    /// Sends the aliases that changed since the last call to the engine. An alias that went away is
    /// sent as empty text, which removes it.
    func applyAliases() {
        let current = configuration.preferences.aliases
        var changed: [(key: UInt64, alias: String)] = []
        for (id, alias) in current where appliedAliases[id] != alias {
            changed.append((id.engineKey, alias))
        }
        for id in appliedAliases.keys where current[id] == nil {
            changed.append((id.engineKey, ""))
        }
        appliedAliases = current
        guard !changed.isEmpty, !isShutDown else { return }
        let updates = changed.map { (ItemKey(rawValue: $0.key), $0.alias) }
        beginWork()
        worker.perform { [weak self] engine in
            for (key, alias) in updates {
                try? engine?.setAlias(alias, for: key)
            }
            Task { @MainActor [weak self] in self?.endWork() }
        }
    }

    /// Reads the fallback list again from the directory plan, the user's fallback choices and the
    /// older setting. True when the list changed.
    func refreshFallbacks() -> Bool {
        let next = plan.fallbackList(
            choices: configuration.preferences.fallbackChoices, legacy: settingsCache.fallbackCommands)
        let changed = next.map(\.id) != fallbacks.map(\.id)
        fallbacks = next
        return changed
    }

    func applyLearningPaused() {
        let paused = settingsCache.learningPaused
        worker.perform { engine in
            try? engine?.setLearningPaused(paused)
        }
    }

    func settingsChanged() {
        let old = settingsCache
        settingsCache = RootSettingsCache(hostSettings)
        if old.learningPaused != settingsCache.learningPaused {
            applyLearningPaused()
            inspector.changes.send()
        }
        if old.fallbackCommands != settingsCache.fallbackCommands, refreshFallbacks() {
            reconcileVisibleRows()
        }
        if old.tabCommand != settingsCache.tabCommand, inSession, !Self.isBlank(snapshot.query),
            snapshot.tabCommand != tabCommand
        {
            _ = publish(snapshot)
            changes.send()
        }
        prepareEmptySnapshot()
    }

    // MARK: Listening

    /// Follows the directory, the preferences, the settings, the system context, session starts
    /// and the hour. Streams are made here, before any task runs, so no change is missed.
    func startListening() {
        let directoryChanges = configuration.directory.changes.stream()
        let preferenceChanges = configuration.preferences.changes.stream()
        let names = Set(RootSettingsCache.keys.map { hostSettings.storageName(for: $0.name) })
        let settingChanges = configuration.settings.changes(for: names)
        let contextChanges = configuration.systemContext.changes()
        let sessionStarts = configuration.systemContext.sessionStarts()
        let clock = configuration.clock

        tasks.append(
            Task { [weak self] in
                for await _ in directoryChanges { self?.readDirectory() }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in preferenceChanges {
                    self?.applyAliases()
                    if self?.refreshFallbacks() == true { self?.reconcileVisibleRows() }
                    self?.prepareEmptySnapshot()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in settingChanges { self?.settingsChanged() }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in contextChanges {
                    self?.refreshContext()
                    self?.askAllTriggers()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in sessionStarts {
                    self?.sessionStart = true
                    self?.refreshContext()
                    self?.askAllTriggers()
                }
            })
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    let wait = ContextBuilder.untilNextHour(after: clock.now, calendar: clock.calendar)
                    do { try await clock.sleep(for: wait) } catch { return }
                    self?.refreshContext()
                    self?.validateRememberedRows()
                }
            })
    }
}
