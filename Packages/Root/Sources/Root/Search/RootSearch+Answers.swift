import Foundation
import Kit
import KitHosting

extension RootSearch {
    // MARK: Instant answers that change

    /// Follows ``InstantProvider/answersChanged`` of every instant provider in the plan. Providers
    /// that stay keep their listener; providers that left lose it.
    func reconcileAnswerListeners() {
        var next: [ObjectIdentifier: Task<Void, Never>] = [:]
        for entry in plan.instantProviders {
            guard let signal = entry.provider.answersChanged else { continue }
            let id = ObjectIdentifier(entry.provider)
            guard next[id] == nil else { continue }
            if let listener = answerListeners[id] {
                next[id] = listener
                continue
            }
            let stream = signal.stream()
            next[id] = Task { [weak self] in
                for await _ in stream { self?.refreshAnswers(of: id) }
            }
        }
        for (id, listener) in answerListeners where next[id] == nil {
            listener.cancel()
        }
        answerListeners = next
    }

    /// Asks one instant provider again for the query on screen and puts its new rows where its old
    /// rows were, so nothing above them moves.
    ///
    /// Rows in the answers at the top stay at their place in that section, even when the new answer
    /// no longer claims the top. Rows in the provider's own section replace that section's rows. An
    /// answer that is new for this query joins as the provider's own section after the results and
    /// the instant sections of providers before it, ahead of async sections and fallbacks, as a
    /// keystroke would order it. A nil or empty answer takes the old rows away. Rows that already
    /// show elsewhere are left out. Does nothing outside a session, for a blank query, or while an
    /// async provider holds the query.
    func refreshAnswers(of providerID: ObjectIdentifier) {
        guard inSession, !isShutDown, !Self.isBlank(snapshot.query), !pendingProviders.contains(where: \.takesOver),
            let index = plan.instantProviders.firstIndex(where: { ObjectIdentifier($0.provider) == providerID })
        else { return }
        let entry = plan.instantProviders[index]
        let answer = entry.provider.answer(for: snapshot.query)
        var next = snapshot
        let old = Self.removeRows(of: entry, from: &next.sections)

        var shown: Set<ItemID> = []
        for section in next.sections {
            for row in section.rows { shown.insert(row.id) }
        }
        var rows: [Row] = []
        for row in answer?.rows ?? [] where shown.insert(row.id).inserted {
            rows.append(row)
        }

        switch old.place {
        case .answers(let rowIndex):
            if !rows.isEmpty {
                if let section = next.sections.firstIndex(where: { $0.id == Self.answersID }) {
                    next.sections[section].rows.insert(contentsOf: rows, at: rowIndex)
                } else {
                    next.sections.insert(RootSection(id: Self.answersID, title: nil, rows: rows, kind: .answers), at: 0)
                }
            }
        case .ownSection(let sectionIndex, let title):
            if !rows.isEmpty {
                next.sections.insert(
                    RootSection(
                        id: entry.sectionID, title: answer?.sectionTitle ?? title, rows: rows,
                        kind: .provider(namespace: entry.namespace)),
                    at: sectionIndex)
            }
        case .none:
            if !rows.isEmpty {
                let later = Set(plan.instantProviders[(index + 1)...].map(\.sectionID))
                let position =
                    next.sections.firstIndex {
                        $0.kind == .fallbacks || $0.id.hasPrefix("async.") || later.contains($0.id)
                    } ?? next.sections.endIndex
                next.sections.insert(
                    RootSection(
                        id: entry.sectionID, title: answer?.sectionTitle, rows: rows,
                        kind: .provider(namespace: entry.namespace)),
                    at: position)
            }
        }

        // A completion that led to one of the old rows is the old answer's: drop it, and take the
        // new top row's own completion when the new rows lead the list.
        if let completion = next.completion, old.ids.contains(completion.id) {
            next.completion = nil
        }
        if next.completion == nil, settingsCache.inlineCompletion, let first = next.sections.first?.rows.first,
            rows.contains(where: { $0.id == first.id }), let text = first.completion, !text.isEmpty
        {
            next.completion = RootCompletion(id: first.id, text: text)
        }
        next.emptyState = next.sections.isEmpty && !next.isLoading ? Self.noResults : nil
        guard next.sections != snapshot.sections || next.completion != snapshot.completion else { return }
        _ = publish(next)
        changes.send()
        refreshLiveSubtitles()
    }

    /// Where a provider's rows were before they were taken out.
    enum AnswerPlace {
        /// In the answers at the top, starting at this row.
        case answers(row: Int)
        /// In the provider's own section, which was at this index, with this title.
        case ownSection(index: Int, title: String?)
        case none
    }

    /// Takes one provider's rows out of the sections and says where they were. A section left empty
    /// is removed.
    static func removeRows(
        of entry: DirectoryPlan.InstantEntry, from sections: inout [RootSection]
    ) -> (place: AnswerPlace, ids: Set<ItemID>) {
        if let index = sections.firstIndex(where: { $0.id == entry.sectionID }) {
            let removed = sections.remove(at: index)
            return (.ownSection(index: index, title: removed.title), Set(removed.rows.map(\.id)))
        }
        guard let section = sections.firstIndex(where: { $0.id == answersID }),
            let first = sections[section].rows.firstIndex(where: { $0.id.namespace == entry.namespace })
        else { return (.none, []) }
        let ids = Set(sections[section].rows.lazy.filter { $0.id.namespace == entry.namespace }.map(\.id))
        sections[section].rows.removeAll { $0.id.namespace == entry.namespace }
        if sections[section].rows.isEmpty { sections.remove(at: section) }
        return (.answers(row: first), ids)
    }
}
