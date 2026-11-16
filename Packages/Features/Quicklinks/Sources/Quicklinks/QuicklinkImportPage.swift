import Foundation
import Kit

/// The page Import Quicklinks shows before it saves anything: what is added, what is added turned
/// off, what is skipped as a duplicate and what is not valid. Its one action imports.
///
/// The import is decided again against the quicklinks when the user confirms, so a change made in
/// between is honored.
final class QuicklinkImportPage: ListSource {
    /// Rows on this page, keyed by the entry's place in the file.
    nonisolated static let namespace = "quicklink-import"

    private unowned let feature: QuicklinksFeature
    let entries: [ExchangedQuicklink]
    let plan: QuicklinkImportPlan

    init(feature: QuicklinksFeature, entries: [ExchangedQuicklink], plan: QuicklinkImportPlan) {
        self.feature = feature
        self.entries = entries
        self.plan = plan
    }

    var page: ListPage {
        ListPage(
            self, title: Strings.importPageTitle, searchPlaceholder: Strings.importSearchPlaceholder, showsDetail: true)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(
            sections: await QuicklinkImportRows.sections(plan),
            notice: Notice(
                icon: .symbol("square.and.arrow.down"), title: Strings.importNoticeTitle,
                message: Strings.importNoticeMessage(plan.added)))
    }

    func detail(for row: Row) async throws -> Detail? {
        guard row.id.namespace == Self.namespace, let position = Int(row.id.key), plan.items.indices.contains(position)
        else { return nil }
        return QuicklinkImportRows.detail(plan.items[position])
    }

    func actions(for row: Row) -> [Action] {
        guard plan.added > 0 else { return [] }
        let feature = feature
        let entries = entries
        return [
            Action(
                Strings.importAction(plan.added), id: "import", icon: .symbol("square.and.arrow.down"),
                runPolicy: .dropWhileRunning
            ) { context in
                let plan = try await feature.commitImport(entries)
                context.showToast(Strings.importToast(plan))
                return .pop
            }
        ]
    }
}

/// Rows and details for the import page, built off the main thread.
nonisolated enum QuicklinkImportRows {
    @concurrent static func sections(_ plan: QuicklinkImportPlan) async -> [ListSection] {
        var add: [Row] = []
        var off: [Row] = []
        var duplicates: [Row] = []
        var invalid: [Row] = []
        for (position, item) in plan.items.enumerated() {
            let row = row(item, position: position)
            switch item.outcome {
            case .add: add.append(row)
            case .addTurnedOff, .addTurnedOffSending: off.append(row)
            case .duplicate: duplicates.append(row)
            case .notValid: invalid.append(row)
            }
        }
        return [
            ListSection(Strings.importAddSection, id: "add", showsCount: true, rows: add),
            ListSection(Strings.importOffSection, id: "off", showsCount: true, rows: off),
            ListSection(Strings.importDuplicateSection, id: "duplicate", showsCount: true, rows: duplicates),
            ListSection(Strings.importNotValidSection, id: "not-valid", showsCount: true, rows: invalid),
        ]
        .filter { !$0.rows.isEmpty }
    }

    static func row(_ item: QuicklinkImportPlan.Item, position: Int) -> Row {
        var accessories: [Accessory] = []
        if let quicklink = item.quicklink, !quicklink.isEnabled { accessories.append(.tag(Strings.offTag)) }
        if item.quicklink != nil, item.unknownApp != nil || item.outcome != .add {
            accessories.append(
                .icon(.symbol("exclamationmark.triangle", tint: .orange), tooltip: subtitle(item)))
        }
        let icon: Icon =
            switch item.outcome {
            case .add: .symbol("link")
            case .addTurnedOff, .addTurnedOffSending: .symbol("exclamationmark.triangle", tint: .orange)
            case .duplicate: .symbol("equal.circle")
            case .notValid: .symbol("xmark.circle")
            }
        return Row(
            id: ItemID(QuicklinkImportPage.namespace, String(position)), title: DisplayText.oneLine(item.title),
            subtitle: DisplayText.oneLine(subtitle(item)), icon: icon, accessories: accessories,
            keywords: [item.link], memory: .never)
    }

    /// The one line that says what happens to the entry.
    static func subtitle(_ item: QuicklinkImportPlan.Item) -> String {
        switch item.outcome {
        case .add:
            if let app = item.unknownApp { return Strings.importUnknownApp(app) }
            return LinkTemplate(item.link).displayText
        case .addTurnedOff(let scheme):
            return Strings.importTurnedOff(scheme)
        case .addTurnedOffSending(let clipboard, let selection):
            return Strings.importTurnedOffSending(clipboard: clipboard, selection: selection)
        case .duplicate(let name):
            return Strings.importDuplicate(of: name)
        case .notValid(let reason):
            return reason
        }
    }

    static func detail(_ item: QuicklinkImportPlan.Item) -> Detail {
        var metadata: [MetadataItem] = [.label(Strings.importOutcomeLabel, value: subtitle(item))]
        if let quicklink = item.quicklink {
            if !quicklink.keywords.isEmpty {
                metadata.append(.tags(Strings.detailKeywords, quicklink.keywords.map { Tag($0) }))
            }
            metadata.append(.label(Strings.detailOpensWith, value: quicklink.openWith ?? Strings.detailDefaultApp))
            metadata.append(
                .label(Strings.detailStatus, value: quicklink.isEnabled ? Strings.detailOn : Strings.detailOff))
            if quicklink.isFallback {
                metadata.append(.label(Strings.detailFallback, value: Strings.detailFallbackOn))
            }
        }
        // The link as text, so nothing in it is drawn as a link to click.
        return Detail(.text(item.link, monospaced: true), metadata: metadata)
    }
}
