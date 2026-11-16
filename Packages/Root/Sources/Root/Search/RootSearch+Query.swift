import CoreBridge
import Darwin
import Foundation
import Kit
import KitHosting

extension RootSearch {
    static let suggestedID = "suggested"
    static let favoritesID = "favorites"
    static let answersID = "answers"
    static let resultsID = "results"
    static let fallbacksID = "fallbacks"
    static let noResults = EmptyState(title: "No Results")

    // MARK: RootSource

    /// Hands over the empty-query snapshot prepared earlier and starts a session. No I/O, no
    /// learning, no engine call beyond resetting the session, no trigger asked.
    public func begin() -> RootSnapshot {
        if inSession { finishTriggerSession() }
        buffer?.reset()
        inSession = true
        queryGeneration &+= 1
        cancelProviders()
        aliasHitKeys.removeAll(keepingCapacity: true)
        startTriggerSession()
        let snapshot = publish(preparedEmpty)
        if preparedHasLiveSubtitles { refreshLiveSubtitlesSoon() }
        return snapshot
    }

    /// Runs the engine and builds the sections, inside the keystroke.
    ///
    /// Order: instant answers that claim the top, engine results, instant answers in their own
    /// sections, the async provider sections that fill in later, then fallbacks. A query an async
    /// provider takes over shows that provider alone, unless an answer claims the top. An item shows once:
    /// an engine result whose ID an instant answer already shows is left out. Async providers that
    /// were running for the previous query are cancelled, and the ones this query wants start.
    public func update(query: String) -> RootSnapshot {
        inSession = true
        queryGeneration &+= 1
        cancelProviders()
        aliasHitKeys.removeAll(keepingCapacity: true)
        answerKeys.removeAll(keepingCapacity: true)
        guard !Self.isBlank(query) else {
            buffer?.reset()
            var empty = preparedEmpty
            empty.query = query
            let snapshot = publish(empty)
            refreshLiveSubtitles()
            return snapshot
        }
        if sessionTypedAt == nil, sessionBeganAt != nil { sessionTypedAt = configuration.clock.now }

        let takenOver = plan.asyncProviders.contains { $0.provider.takesOver(query) }
        var topRows: [Row] = []
        var answerSections: [RootSection] = []
        for entry in plan.instantProviders {
            guard let answer = entry.provider.answer(for: query), !answer.rows.isEmpty else { continue }
            for row in answer.rows { answerKeys.append(row.id.engineKey) }
            if answer.claimsTop {
                topRows.append(contentsOf: answer.rows)
            } else {
                answerSections.append(
                    RootSection(
                        id: entry.sectionID, title: answer.sectionTitle, rows: answer.rows,
                        kind: .provider(namespace: entry.namespace)))
            }
        }

        // A provider that claims the query shows alone, without a limit, unless an instant answer
        // claims the top for it, as a snippet keyword the user put behind ">" does.
        if takenOver, topRows.isEmpty {
            answerKeys.removeAll(keepingCapacity: true)
            for entry in plan.asyncProviders where entry.provider.takesOver(query) {
                pendingProviders.append(
                    PendingProvider(
                        provider: entry.provider, namespace: entry.namespace, sectionID: entry.sectionID,
                        takesOver: true, title: "", maximumRows: Int.max))
            }
            startProviders(for: query)
            let snapshot = publish(RootSnapshot(query: query, isLoading: true))
            refreshLiveSubtitles()
            return snapshot
        }

        let results = engineResults(for: query)

        let length = query.count
        for entry in plan.asyncProviders where length >= entry.provider.minimumQueryLength {
            pendingProviders.append(
                PendingProvider(
                    provider: entry.provider, namespace: entry.namespace, sectionID: entry.sectionID,
                    takesOver: false, title: "", maximumRows: max(0, entry.provider.maximumRows)))
        }

        var sections: [RootSection] = []
        sections.reserveCapacity(3 + answerSections.count)
        if !topRows.isEmpty {
            sections.append(RootSection(id: Self.answersID, title: nil, rows: topRows, kind: .answers))
        }
        if !results.isEmpty {
            sections.append(RootSection(id: Self.resultsID, title: "Results", rows: results, kind: .results))
        }
        sections.append(contentsOf: answerSections)
        if !fallbacks.isEmpty {
            var rows: [Row] = []
            rows.reserveCapacity(fallbacks.count)
            for fallback in fallbacks {
                rows.append(
                    Row(id: fallback.id, title: fallback.title(query), subtitle: fallback.subtitle, icon: fallback.icon)
                )
            }
            sections.append(
                RootSection(id: Self.fallbacksID, title: "Use \"\(query)\" with", rows: rows, kind: .fallbacks))
        }
        let completion = completion(for: query, top: sections.first, answersClaimTop: !topRows.isEmpty)
        let loading = !pendingProviders.isEmpty
        startProviders(for: query)
        let snapshot = publish(
            RootSnapshot(
                query: query, sections: sections, completion: completion, isLoading: loading,
                emptyState: sections.isEmpty && !loading ? Self.noResults : nil))
        refreshLiveSubtitles()
        return snapshot
    }

    /// Ends the session: async providers and live subtitles stop, and the trigger rows the session
    /// showed learn whether they were taken.
    public func end() {
        let wasInSession = inSession
        inSession = false
        queryGeneration &+= 1
        cancelProviders()
        stopLiveSubtitles()
        if wasInSession { finishTriggerSession() }
    }

    /// The highlights a row already carries, or the engine's ranges of the title for the current
    /// query when the row is an engine result past the first rows.
    public func titleHighlights(for row: Row) -> [Range<Int>] {
        guard row.titleHighlights.isEmpty, inSession, !Self.isBlank(snapshot.query), let engine, let buffer,
            let entry = table.entry(for: row.id), entry.row.title == row.title
        else { return row.titleHighlights }
        return Self.highlights(engine: engine, buffer: buffer, key: ItemKey(rawValue: row.id.engineKey))
    }

    // MARK: Engine results

    /// The engine's hits as rows, with highlights for the first ones.
    private func engineResults(for query: String) -> [Row] {
        guard let engine, let buffer else { return [] }
        let started = timings == nil ? 0 : Self.threadNanos()
        let count = (try? engine.query(Self.composed(query), into: buffer)) ?? 0
        if let timings { timings.engineNanos.append(Self.threadNanos() - started) }

        var rows: [Row] = []
        rows.reserveCapacity(count)
        var now: Date?
        var index = 0
        let liveValues = !subtitleValues.isEmpty
        while index < count {
            let hit = buffer[index]
            index += 1
            let key = hit.key.rawValue
            guard var row = table.entries[key]?.row else { continue }
            if !answerKeys.isEmpty, answerKeys.contains(key) { continue }
            if let expires = row.expires {
                let current = now ?? configuration.clock.now
                now = current
                if expires <= current { continue }
            }
            if rows.count < Self.highlightedRows {
                row.titleHighlights = Self.highlights(engine: engine, buffer: buffer, key: hit.key)
            }
            if liveValues, let subtitle = subtitleValues[row.id] { row.show(subtitle) }
            if hit.flags.contains(.alias) { aliasHitKeys.append(key) }
            rows.append(row)
        }
        return rows
    }

    /// What Tab completes to. The top row's own ``Row/completion`` wins, such as a calculator's
    /// answer or a folder path. Otherwise the engine's completion for its top hit, unless an answer
    /// claims the top, because Tab would then complete to a row that is not selected.
    private func completion(for query: String, top: RootSection?, answersClaimTop: Bool) -> RootCompletion? {
        guard settingsCache.inlineCompletion, let top, let first = top.rows.first else { return nil }
        if let text = first.completion, !text.isEmpty { return RootCompletion(id: first.id, text: text) }
        guard !answersClaimTop, top.kind == .results else { return nil }
        return engineCompletion(for: query)
    }

    /// The engine's completion for its top hit, as the full text the query becomes. The engine
    /// matches the query without its last spaces, so its text continues that. A query that ends in
    /// a space keeps the completion only when the completed text has the space there too: "text "
    /// completes to "text Editor", and "note " gets nothing rather than "note s".
    private func engineCompletion(for query: String) -> RootCompletion? {
        guard let engine, let buffer, let found = (try? engine.completion(in: buffer)) ?? nil,
            let entry = table[found.key.rawValue]
        else { return nil }
        guard query.last?.isWhitespace == true else {
            return RootCompletion(id: entry.row.id, text: query + found.text)
        }
        var typed = Substring(query)
        while typed.last?.isWhitespace == true { typed = typed.dropLast() }
        let full = typed + found.text
        guard full.count > query.count,
            full.prefix(query.count).compare(query, options: .caseInsensitive) == .orderedSame
        else { return nil }
        return RootCompletion(id: entry.row.id, text: query + full.dropFirst(query.count))
    }

    static func highlights(engine: Engine, buffer: QueryBuffer, key: ItemKey) -> [Range<Int>] {
        guard let ranges = try? engine.highlightRanges(for: key, in: buffer), !ranges.isEmpty else { return [] }
        return ranges.map { $0.location..<($0.location + $0.length) }
    }

    // MARK: Empty query

    /// Builds the empty-query snapshot: Suggested, then Favorites, each as its setting allows.
    /// Suggested starts with the trigger rows Thompson sampling picked, then the engine's
    /// predictions. A favorite does not repeat in Suggested, and the frontmost app is never
    /// suggested. Runs when the context, the suggestions, the favorites, the catalog or a setting
    /// changed, never on the summon path.
    func prepareEmptySnapshot() {
        guard !isShutDown else { return }
        let now = configuration.clock.now
        func current(_ entry: CatalogEntry?) -> Row? {
            guard let row = entry?.row, (row.expires ?? .distantFuture) > now else { return nil }
            return row
        }
        let liveValues = !subtitleValues.isEmpty
        func shown(_ row: Row) -> Row {
            guard liveValues, let subtitle = subtitleValues[row.id] else { return row }
            var row = row
            row.show(subtitle)
            return row
        }
        var favorites: [Row] = []
        var favoriteKeys: Set<UInt64> = []
        if settingsCache.showFavorites {
            for id in configuration.preferences.favorites {
                guard let row = current(table.entry(for: id)), favoriteKeys.insert(id.engineKey).inserted else {
                    continue
                }
                favorites.append(shown(row))
            }
        }
        var suggested: [Row] = []
        var triggers: [ShownTrigger] = []
        if settingsCache.showSuggestions, settingsCache.suggestionCount > 0 {
            let frontmost = configuration.systemContext.current().frontmostBundleID.map {
                ItemID(ItemID.ReservedNamespace.app, $0)
            }
            for chosen in chooseTriggerRows(at: now, frontmost: frontmost, favorites: favoriteKeys)
            where suggested.count < settingsCache.suggestionCount {
                suggested.append(chosen.suggestion.row)
                triggers.append(
                    ShownTrigger(
                        typeKey: chosen.typeKey, suggestionID: chosen.suggestion.id, rowID: chosen.suggestion.row.id,
                        expires: chosen.suggestion.expires, prior: triggerPrior(chosen.typeKey)))
            }
            for key in suggestionKeys where suggested.count < settingsCache.suggestionCount {
                guard !favoriteKeys.contains(key), let row = current(table[key]),
                    !suggested.contains(where: { $0.id == row.id })
                else { continue }
                suggested.append(shown(row))
            }
        }
        var sections: [RootSection] = []
        if !suggested.isEmpty {
            sections.append(RootSection(id: Self.suggestedID, title: "Suggested", rows: suggested, kind: .suggested))
        }
        if !favorites.isEmpty {
            sections.append(RootSection(id: Self.favoritesID, title: "Favorites", rows: favorites, kind: .favorites))
        }
        preparedEmpty = RootSnapshot(sections: sections)
        preparedTriggers = triggers
        let limit = settingsCache.visibleRows
        preparedHasLiveSubtitles =
            !plan.liveSubtitles.isEmpty
            && sections.lazy.flatMap(\.rows).prefix(limit).contains { plan.liveSubtitles[$0.id] != nil }
        scheduleSuggestionTimer(after: now)
        if inSession, Self.isBlank(snapshot.query) {
            var empty = preparedEmpty
            empty.query = snapshot.query
            _ = publish(empty)
            changes.send()
            refreshLiveSubtitles()
        }
    }

    // MARK: Helpers

    /// Stamps a new revision on the snapshot and makes it current.
    func publish(_ next: RootSnapshot) -> RootSnapshot {
        var next = next
        revision &+= 1
        next.revision = revision
        next.tabCommand = Self.isBlank(next.query) ? nil : tabCommand
        snapshot = next
        return next
    }

    /// The query with combining marks composed onto their letters, as typed text usually comes, so
    /// pasted decomposed text such as "cafe" plus a combining acute finds "Café". The engine folds one
    /// character at a time and would miss it otherwise. ASCII queries pass through without a copy.
    nonisolated static func composed(_ query: String) -> String {
        guard query.utf8.contains(where: { $0 >= 0xCC }),
            query.unicodeScalars.contains(where: { $0.properties.canonicalCombiningClass != .notReordered })
        else { return query }
        return query.precomposedStringWithCanonicalMapping
    }

    /// True for a query of spaces, tabs and newlines only, which shows the empty state.
    nonisolated static func isBlank(_ query: String) -> Bool {
        query.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    /// CPU time of the calling thread, for the bench.
    nonisolated static func threadNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }
}
