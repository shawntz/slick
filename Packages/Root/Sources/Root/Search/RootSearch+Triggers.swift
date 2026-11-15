import Foundation
import Kit
import KitHosting
import os

/// A trigger row in the empty state, kept so the end of the session can tell whether it was taken.
nonisolated struct ShownTrigger: Sendable {
    var typeKey: String
    var suggestionID: String
    var rowID: ItemID
    var expires: Date
    var prior: AcceptancePrior

    /// The key its ignores are counted under.
    var ignoreKey: String { typeKey + "|" + suggestionID }
}

/// What root search learned about one suggestion trigger type, for settings.
nonisolated public struct TriggerLearningState: Hashable, Sendable {
    /// The feature's manifest ID.
    public var featureID: String
    /// The trigger's ``SuggestionTrigger/id``.
    public var triggerID: String
    /// The mean acceptance rate now, from the trigger's prior and what the user did.
    public var acceptance: Double
    /// Sessions in which a suggestion of this type showed for a second or was taken.
    public var impressions: Int
    /// Suggestions of this type the user ran.
    public var taken: Int
    /// True once acceptance stayed low and root search stopped asking the trigger.
    public var isOff: Bool
}

extension RootSearch {
    /// How long a session must show a trigger row before leaving it counts as ignoring it.
    static let ignoreAfter: TimeInterval = 1

    // MARK: Directory

    /// Follows the triggers of the features that are on: new ones are asked at once, ones that left
    /// stop, and their rows leave the empty state.
    func reconcileTriggers() {
        var next: [ObjectIdentifier: TriggerSlot] = [:]
        var order: [ObjectIdentifier] = []
        var fresh: [TriggerSlot] = []
        for entry in plan.triggers {
            let id = ObjectIdentifier(entry.trigger)
            guard next[id] == nil else { continue }
            if let slot = triggerSlots[id], slot.typeKey == entry.typeKey {
                next[id] = slot
            } else {
                let slot = TriggerSlot(entry)
                listen(to: slot, settings: entry.settings)
                next[id] = slot
                fresh.append(slot)
            }
            order.append(id)
        }
        var departed = false
        for (id, slot) in triggerSlots where next[id] !== slot {
            slot.stop()
            departed = departed || !slot.suggestions.isEmpty
        }
        triggerSlots = next
        triggerOrder = order
        for slot in fresh { ask(slot) }
        if departed { prepareEmptySnapshot() }
    }

    /// Asks a trigger again after its change signal, a setting it reloads on, or its refresh
    /// interval.
    private func listen(to slot: TriggerSlot, settings: FeatureSettings) {
        if let signal = slot.trigger.changes {
            let stream = signal.stream()
            slot.listeners.append(
                Task { [weak self, weak slot] in
                    for await _ in stream {
                        guard let self, let slot else { return }
                        self.ask(slot)
                    }
                })
        }
        let keys = slot.trigger.reloadsOnSettings
        if !keys.isEmpty {
            let stream = settings.changes(ofAny: keys)
            slot.listeners.append(
                Task { [weak self, weak slot] in
                    for await _ in stream {
                        guard let self, let slot else { return }
                        self.ask(slot)
                    }
                })
        }
        if let interval = slot.trigger.refreshInterval, interval > .zero {
            let clock = configuration.clock
            let wait = max(interval, .seconds(1))
            slot.listeners.append(
                Task { [weak self, weak slot] in
                    while !Task.isCancelled {
                        do { try await clock.sleep(for: wait) } catch { return }
                        guard let self, let slot else { return }
                        self.ask(slot)
                    }
                })
        }
    }

    // MARK: Asking

    /// Asks every trigger again: the context changed or the Mac woke.
    func askAllTriggers() {
        for id in triggerOrder {
            if let slot = triggerSlots[id] { ask(slot) }
        }
    }

    /// Asks one trigger for its suggestions off the keystroke and summon paths. A trigger that is
    /// off or lacks a permission is not asked and loses its rows. One that throws keeps the
    /// suggestions it had. A reason to ask during an ask asks once more afterwards.
    func ask(_ slot: TriggerSlot) {
        guard !isShutDown, triggerSlots[ObjectIdentifier(slot.trigger)] === slot else { return }
        let isOff = learning.read { $0.triggers[slot.typeKey]?.isOff ?? false }
        guard !isOff, slot.isPermitted else {
            if !slot.suggestions.isEmpty {
                slot.suggestions = []
                prepareEmptySnapshot()
            }
            return
        }
        guard !slot.isAsking else {
            slot.askAgain = true
            return
        }
        slot.isAsking = true
        beginWork()
        let now = configuration.clock.now
        Task { [weak self] in
            do {
                let suggestions = try await slot.trigger.suggestions(at: now)
                if let self, self.triggerSlots[ObjectIdentifier(slot.trigger)] === slot {
                    slot.suggestions = suggestions
                    self.prepareEmptySnapshot()
                }
            } catch {
                self?.log.error(
                    "suggestion trigger \(slot.typeKey, privacy: .public) failed, keeping its suggestions: \(error)")
            }
            slot.isAsking = false
            if slot.askAgain {
                slot.askAgain = false
                self?.ask(slot)
            }
            self?.endWork()
        }
    }

    // MARK: Choosing

    /// The trigger rows for the empty state now, by Thompson sampling: one draw per trigger type and
    /// panel session from the type's Beta belief, times each suggestion's urgency. Leaves out types
    /// that are off or lack a permission, expired suggestions, suggestions ignored three times, the
    /// frontmost app and favorites.
    func chooseTriggerRows(at now: Date, frontmost: ItemID?, favorites: Set<UInt64>) -> [TriggerCandidate] {
        guard !triggerOrder.isEmpty else { return [] }
        if drawsStale {
            triggerDraws.removeAll(keepingCapacity: true)
            drawsStale = false
        }
        let state = learning.state
        var candidates: [TriggerCandidate] = []
        for id in triggerOrder {
            guard let slot = triggerSlots[id], !slot.suggestions.isEmpty, slot.isPermitted else { continue }
            let prior = slot.trigger.prior
            var stats = state.triggers[slot.typeKey] ?? TriggerStats(prior: prior, now: now)
            stats.adopt(prior)
            guard !stats.isOff else { continue }
            let draw: Double
            if let drawn = triggerDraws[slot.typeKey] {
                draw = drawn
            } else {
                let belief = stats.decayed(to: now)
                draw = BetaSampler.sample(belief.accepts, belief.rejects, using: &random)
                triggerDraws[slot.typeKey] = draw
            }
            for suggestion in slot.suggestions where suggestion.expires > now {
                let row = suggestion.row.id
                if let ignored = state.ignored[slot.typeKey + "|" + suggestion.id],
                    ignored.count >= IgnoredSuggestion.limit
                {
                    continue
                }
                if row == frontmost || favorites.contains(row.engineKey) { continue }
                candidates.append(TriggerCandidate(typeKey: slot.typeKey, suggestion: suggestion, draw: draw))
            }
        }
        return TriggerChooser.choose(candidates, at: now)
    }

    /// The prior of a trigger type that is in the directory.
    func triggerPrior(_ typeKey: String) -> AcceptancePrior {
        for id in triggerOrder {
            if let slot = triggerSlots[id], slot.typeKey == typeKey { return slot.trigger.prior }
        }
        return AcceptancePrior(accepts: 1, rejects: 1)
    }

    /// Prepares the empty state again at the next moment a suggestion changes on its own: one
    /// expires, becomes imminent, or its urgency ramp starts, peaks or ends.
    func scheduleSuggestionTimer(after now: Date) {
        var next: Date?
        func consider(_ date: Date?) {
            guard let date, date > now else { return }
            next = min(next ?? date, date)
        }
        for slot in triggerSlots.values {
            for suggestion in slot.suggestions {
                consider(suggestion.expires)
                consider(suggestion.imminentFrom)
                if case .ramp(let start, let full, let end) = suggestion.urgency {
                    consider(start)
                    consider(full)
                    consider(end)
                }
            }
        }
        suggestionTimer?.cancel()
        suggestionTimer = nil
        guard let next, !isShutDown else { return }
        let clock = configuration.clock
        suggestionTimer = Task { [weak self] in
            let wait = next.timeIntervalSince(clock.now)
            if wait > 0 {
                do { try await clock.sleep(for: .seconds(wait)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.prepareEmptySnapshot()
        }
    }

    // MARK: Feedback

    /// A session starts with the trigger rows prepared for it. Copies only.
    func startTriggerSession() {
        shownTriggers = preparedTriggers
        acceptedTriggerRows.removeAll(keepingCapacity: true)
        sessionBeganAt = shownTriggers.isEmpty ? nil : configuration.clock.now
        sessionTypedAt = nil
    }

    /// The user ran a row: when it is a trigger row this session showed, it counts as taken.
    func noteTriggerRun(_ row: Row) {
        guard !shownTriggers.isEmpty, shownTriggers.contains(where: { $0.rowID == row.id }) else { return }
        acceptedTriggerRows.append(row.id)
    }

    /// The session ended: each trigger row it showed is taken or, when it showed for at least a
    /// second before the user typed or left, ignored. Three ignores hide a suggestion for good, and
    /// a type whose acceptance stays low switches off. Paused learning records nothing. The next
    /// prepared state draws again.
    func finishTriggerSession() {
        let shown = shownTriggers
        let accepted = acceptedTriggerRows
        let began = sessionBeganAt
        let typed = sessionTypedAt
        shownTriggers = []
        acceptedTriggerRows.removeAll(keepingCapacity: true)
        sessionBeganAt = nil
        sessionTypedAt = nil
        drawsStale = true
        guard !shown.isEmpty, !isShutDown else { return }
        defer { prepareEmptySnapshotSoon() }
        guard !settingsCache.learningPaused, let began else { return }
        let now = configuration.clock.now
        let sawIt = (typed ?? now).timeIntervalSince(began) >= Self.ignoreAfter
        var switchedOff: [String] = []
        learning.update { state in
            for trigger in shown {
                let taken = accepted.contains(trigger.rowID)
                guard taken || sawIt else { continue }
                var stats = state.triggers[trigger.typeKey] ?? TriggerStats(prior: trigger.prior, now: now)
                stats.adopt(trigger.prior)
                let wasOff = stats.isOff
                if taken {
                    stats.accept(at: now)
                } else {
                    stats.ignore(at: now)
                    var ignored =
                        state.ignored[trigger.ignoreKey] ?? IgnoredSuggestion(count: 0, expires: trigger.expires)
                    ignored.count += 1
                    ignored.expires = max(ignored.expires, trigger.expires)
                    state.ignored[trigger.ignoreKey] = ignored
                }
                if stats.isOff, !wasOff { switchedOff.append(trigger.typeKey) }
                state.triggers[trigger.typeKey] = stats
            }
            state.ignored = state.ignored.filter { $0.value.expires > now }
        }
        for typeKey in switchedOff {
            log.notice("suggestion trigger \(typeKey, privacy: .public) switched off: its suggestions are rarely taken")
        }
        inspector.changes.send()
    }

    /// Prepares the empty state on the next turn of the main actor, off the path that asked for it.
    func prepareEmptySnapshotSoon() {
        guard !isShutDown else { return }
        beginWork()
        Task { [weak self] in
            self?.prepareEmptySnapshot()
            self?.endWork()
        }
    }

    // MARK: Settings

    /// What root search learned about each trigger type of the features that are on, in directory
    /// order. Settings can list the types that switched off.
    public var triggerStates: [TriggerLearningState] {
        let now = configuration.clock.now
        let state = learning.state
        return triggerOrder.compactMap { triggerSlots[$0] }.map { slot in
            var stats = state.triggers[slot.typeKey] ?? TriggerStats(prior: slot.trigger.prior, now: now)
            stats.adopt(slot.trigger.prior)
            return TriggerLearningState(
                featureID: slot.featureID, triggerID: slot.trigger.id, acceptance: stats.mean(at: now),
                impressions: stats.impressions, taken: stats.taken, isOff: stats.isOff)
        }
    }

    /// Switches a trigger type back on with what it learned so far forgotten, so it gets a fresh
    /// start from its prior.
    public func resetTrigger(featureID: String, triggerID: String) {
        let typeKey = featureID + "." + triggerID
        learning.update { state in
            state.triggers[typeKey] = nil
            state.ignored = state.ignored.filter { !$0.key.hasPrefix(typeKey + "|") }
        }
        for id in triggerOrder {
            if let slot = triggerSlots[id], slot.typeKey == typeKey { ask(slot) }
        }
        inspector.changes.send()
    }
}
