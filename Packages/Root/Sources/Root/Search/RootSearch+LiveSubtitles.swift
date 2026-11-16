import Foundation
import Kit
import KitHosting

extension RootSearch {
    /// Root never refreshes a live subtitle more often than this.
    static let shortestSubtitleInterval: Duration = .seconds(10)

    /// Starts the refresh loops of the commands with a live subtitle among the rows the list shows
    /// before it scrolls, and stops the loops of commands that left them. A loop whose command now
    /// hands a different change signal or interval, after its declarations changed, starts again
    /// with the new one. Costs one short walk when no command has a live subtitle.
    func refreshLiveSubtitles() {
        guard !plan.liveSubtitles.isEmpty || !subtitleRunners.isEmpty else { return }
        var visible: [ItemID] = []
        if inSession, !plan.liveSubtitles.isEmpty {
            var counted = 0
            let limit = settingsCache.visibleRows
            scan: for section in snapshot.sections {
                for row in section.rows {
                    guard counted < limit else { break scan }
                    counted += 1
                    if plan.liveSubtitles[row.id] != nil, !visible.contains(row.id) { visible.append(row.id) }
                }
            }
        }
        for (id, runners) in subtitleRunners where !visible.contains(id) {
            for runner in runners { runner.cancel() }
            subtitleRunners[id] = nil
            subtitleRunnerKeys[id] = nil
        }
        for id in visible {
            guard let live = plan.liveSubtitles[id] else { continue }
            let key = SubtitleRunnerKey(live)
            if let running = subtitleRunners[id] {
                guard subtitleRunnerKeys[id] != key else { continue }
                for runner in running { runner.cancel() }
            }
            subtitleRunners[id] = startSubtitle(live, for: id)
            subtitleRunnerKeys[id] = key
        }
    }

    /// Runs ``refreshLiveSubtitles()`` on the next turn of the main actor, so the summon path only
    /// creates one task.
    func refreshLiveSubtitlesSoon() {
        Task { [weak self] in self?.refreshLiveSubtitles() }
    }

    /// Stops every refresh loop. Root search left the screen.
    func stopLiveSubtitles() {
        guard !subtitleRunners.isEmpty else { return }
        for runners in subtitleRunners.values {
            for runner in runners { runner.cancel() }
        }
        subtitleRunners.removeAll()
        subtitleRunnerKeys.removeAll()
    }

    /// Fetches now and then at the subtitle's interval, at least ten seconds apart, and again at once
    /// when its change signal fires. The fetch runs in a task, so nothing waits for it, and off the
    /// main thread when the subtitle was made with ``LiveSubtitle/background(every:changes:fetch:)``.
    private func startSubtitle(_ live: LiveSubtitle, for id: ItemID) -> [Task<Void, Never>] {
        let clock = configuration.clock
        let interval = max(live.interval, Self.shortestSubtitleInterval)
        var runners = [
            Task { [weak self] in
                while !Task.isCancelled {
                    let value = await self?.fetchSubtitle(live)
                    guard !Task.isCancelled, let self else { return }
                    if let value { self.applySubtitle(value, to: id) }
                    do { try await clock.sleep(for: interval) } catch { return }
                }
            }
        ]
        if let signal = live.changes {
            let stream = signal.stream()
            runners.append(
                Task { [weak self] in
                    for await _ in stream {
                        let value = await self?.fetchSubtitle(live)
                        guard !Task.isCancelled, let self else { return }
                        if let value { self.applySubtitle(value, to: id) }
                    }
                })
        }
        return runners
    }

    /// Fetches a live subtitle once, counted as work so ``settle()`` waits for it. A subtitle made
    /// with ``LiveSubtitle/background(every:changes:fetch:)`` fetches off the main thread.
    private func fetchSubtitle(_ live: LiveSubtitle) async -> LiveSubtitle.Value? {
        beginWork()
        defer { endWork() }
        return await live.value()
    }

    /// Keeps the new subtitle and its color for the next snapshots, and puts them on the rows on
    /// screen now.
    func applySubtitle(_ value: LiveSubtitle.Value, to id: ItemID) {
        guard !isShutDown, plan.liveSubtitles[id] != nil else { return }
        subtitleValues[id] = value
        guard inSession else { return }
        var next = snapshot
        var changed = false
        for sectionIndex in next.sections.indices {
            for rowIndex in next.sections[sectionIndex].rows.indices
            where next.sections[sectionIndex].rows[rowIndex].id == id {
                let before = next.sections[sectionIndex].rows[rowIndex]
                next.sections[sectionIndex].rows[rowIndex].show(value)
                if next.sections[sectionIndex].rows[rowIndex] != before { changed = true }
            }
        }
        guard changed else { return }
        _ = publish(next)
        changes.send()
    }

    /// Forgets the subtitles of commands that no longer have a live subtitle.
    func pruneSubtitleValues() {
        guard !subtitleValues.isEmpty else { return }
        subtitleValues = subtitleValues.filter { plan.liveSubtitles[$0.key] != nil }
    }
}

/// What a refresh loop follows: its change signal, by identity, and its interval.
struct SubtitleRunnerKey: Equatable {
    let signal: ObjectIdentifier?
    let interval: Duration

    init(_ live: LiveSubtitle) {
        signal = live.changes.map(ObjectIdentifier.init)
        interval = live.interval
    }
}

extension Row {
    /// Shows a live subtitle: its text, and its color or the theme's when it has none.
    nonisolated mutating func show(_ subtitle: LiveSubtitle.Value) {
        self.subtitle = subtitle.text
        subtitleColor = subtitle.color
    }
}
