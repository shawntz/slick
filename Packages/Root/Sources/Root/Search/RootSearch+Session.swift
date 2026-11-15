import Foundation
import Kit
import KitHosting

extension RootSearch {
    /// Brings the rows on screen for a typed query in line with a changed catalog or directory,
    /// without ranking again, so nothing the user looks at changes order.
    ///
    /// A row whose item is gone leaves: a catalog row its source deleted or that expired, a command
    /// or answer whose feature was turned off, a fallback that is off, an async section whose
    /// provider left. A row whose item changed shows its new title, subtitle and icon in place. New
    /// items wait for the next keystroke. Sends ``changes`` when anything changed.
    func reconcileVisibleRows() {
        guard inSession, !isShutDown, !Self.isBlank(snapshot.query) else { return }
        let now = configuration.clock.now
        let fallbackIDs = Set(fallbacks.map(\.id))
        let asyncSections = Set(plan.asyncProviders.map(\.sectionID))
        let instantSections = Set(plan.instantProviders.map(\.sectionID))
        var changed = dropDepartedProviders()
        var sections: [RootSection] = []
        sections.reserveCapacity(snapshot.sections.count)
        for var section in snapshot.sections {
            switch section.kind {
            case .results:
                var rows: [Row] = []
                rows.reserveCapacity(section.rows.count)
                for row in section.rows {
                    guard let entry = table.entry(for: row.id), (entry.row.expires ?? .distantFuture) > now else {
                        changed = true
                        continue
                    }
                    var fresh = entry.row
                    fresh.titleHighlights = fresh.title == row.title ? row.titleHighlights : []
                    if let subtitle = subtitleValues[fresh.id] { fresh.show(subtitle) }
                    if fresh != row { changed = true }
                    rows.append(fresh)
                }
                section.rows = rows
            case .provider(let namespace):
                // A provider's own section stays while its provider does, whatever its rows' IDs.
                let present =
                    section.id.hasPrefix("async.")
                    ? asyncSections.contains(section.id) : instantSections.contains(section.id)
                guard present, plan.owners[namespace] != nil else {
                    changed = true
                    continue
                }
            case .answers:
                let before = section.rows.count
                section.rows.removeAll { plan.owners[$0.id.namespace] == nil }
                changed = changed || section.rows.count != before
            case .fallbacks:
                let before = section.rows.count
                section.rows.removeAll { !fallbackIDs.contains($0.id) }
                changed = changed || section.rows.count != before
            case .suggested, .favorites:
                break
            }
            if !section.rows.isEmpty { sections.append(section) }
        }
        guard changed else { return }
        var next = snapshot
        next.sections = sections
        next.isLoading = providersOutstanding > 0
        next.emptyState = sections.isEmpty && !next.isLoading ? Self.noResults : nil
        if let completion = next.completion, sections.first?.rows.first?.id != completion.id {
            next.completion = nil
        }
        _ = publish(next)
        changes.send()
        refreshLiveSubtitles()
    }
}
