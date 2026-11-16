import Foundation
import Kit
import KitTemplates

/// The page Import Snippets shows before it saves anything: what is added, what is added without
/// its keyword, what is skipped as a duplicate and what is not valid. Its one action imports.
///
/// The import is decided again against the library when the user confirms, so a change made in
/// between, such as an edit by hand, is honored and nothing the user has is overwritten.
final class SnippetImportPage: ListSource {
    /// Rows on this page, keyed by the entry's place in the files.
    nonisolated static let namespace = "snippet-import"

    private unowned let feature: SnippetsFeature
    let entries: [ImportedEntry]
    let plan: ImportPlan
    private let prefix: String

    init(feature: SnippetsFeature, entries: [ImportedEntry], plan: ImportPlan, prefix: String) {
        self.feature = feature
        self.entries = entries
        self.plan = plan
        self.prefix = prefix
    }

    var page: ListPage {
        ListPage(
            self, title: Strings.importPageTitle, searchPlaceholder: Strings.importSearchPlaceholder, showsDetail: true)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let sections = await SnippetImportRows.sections(plan, prefix: prefix)
        return ListResult(
            sections: sections,
            notice: Notice(
                icon: .symbol("square.and.arrow.down"), title: Strings.importNoticeTitle,
                message: Strings.importNoticeMessage(plan.summary.added)))
    }

    func detail(for row: Row) async throws -> Detail? {
        guard row.id.namespace == Self.namespace, let position = Int(row.id.key), plan.items.indices.contains(position)
        else { return nil }
        return await SnippetImportRows.detail(plan.items[position], prefix: prefix)
    }

    func actions(for row: Row) -> [Action] {
        guard plan.summary.added > 0 else { return [] }
        let feature = feature
        let entries = entries
        return [
            Action(
                Strings.importAction(plan.summary.added), id: "import", icon: .symbol("square.and.arrow.down"),
                runPolicy: .dropWhileRunning
            ) { context in
                let summary = try await feature.commitImport(entries)
                context.showToast(Strings.importToast(summary))
                return .pop
            }
        ]
    }
}

/// Rows and details for the import page, built off the main thread.
nonisolated enum SnippetImportRows {
    @concurrent static func sections(_ plan: ImportPlan, prefix: String) async -> [ListSection] {
        var add: [Row] = []
        var withoutKeyword: [Row] = []
        var duplicates: [Row] = []
        var notValid: [Row] = []
        for (position, item) in plan.items.enumerated() {
            let row = row(item, position: position, prefix: prefix)
            switch item.outcome {
            case .add: add.append(row)
            case .addWithoutKeyword: withoutKeyword.append(row)
            case .duplicate: duplicates.append(row)
            case .notValid: notValid.append(row)
            }
        }
        return [
            ListSection(Strings.importAddSection, id: "add", showsCount: true, rows: add),
            ListSection(
                Strings.importWithoutKeywordSection, id: "without-keyword", showsCount: true, rows: withoutKeyword),
            ListSection(Strings.importDuplicateSection, id: "duplicate", showsCount: true, rows: duplicates),
            ListSection(Strings.importNotValidSection, id: "not-valid", showsCount: true, rows: notValid),
        ]
        .filter { !$0.rows.isEmpty }
    }

    static func row(_ item: ImportPlan.Item, position: Int, prefix: String) -> Row {
        var accessories: [Accessory] = []
        if let keyword = item.snippet?.typedKeyword(prefix: prefix) { accessories.append(.tag(keyword)) }
        let isFlagged = !item.keptAsTyped.isEmpty || !item.nowFilled.isEmpty
        if isFlagged, item.snippet != nil {
            accessories.append(
                .icon(.symbol("exclamationmark.triangle", tint: .orange), tooltip: Strings.importPlaceholdersDiffer))
        }
        let icon: Icon =
            switch item.outcome {
            case .add, .addWithoutKeyword: .symbol("text.quote")
            case .duplicate: .symbol("equal.circle")
            case .notValid: .symbol("xmark.circle")
            }
        return Row(
            id: ItemID(SnippetImportPage.namespace, String(position)), title: DisplayText.oneLine(item.title),
            subtitle: DisplayText.oneLine(subtitle(item, prefix: prefix)), icon: icon, accessories: accessories,
            keywords: item.keyword.map { [$0] } ?? [], memory: .never)
    }

    /// The one line that says what happens to the entry, or what to look at.
    static func subtitle(_ item: ImportPlan.Item, prefix: String) -> String {
        switch item.outcome {
        case .add:
            if let token = item.keptAsTyped.first { return Strings.importKeptAsTyped(token) }
            if let token = item.nowFilled.first { return Strings.importNowFilled(token) }
            if let original = item.renamedFrom { return Strings.importRenamed(original) }
            return SnippetRows.preview(item.text)
        case .addWithoutKeyword(.taken(let keyword, let holder)):
            return Strings.importKeywordTaken(prefix + keyword, by: holder)
        case .addWithoutKeyword(.refused(let keyword, let reason)):
            return Strings.importKeywordRefused(prefix + keyword, reason: reason)
        case .duplicate(let name):
            return Strings.importDuplicate(of: name)
        case .notValid(let reason):
            return Strings.importNotValid(reason)
        }
    }

    @concurrent static func detail(_ item: ImportPlan.Item, prefix: String) async -> Detail {
        var metadata: [MetadataItem] = [.label(Strings.importOutcomeLabel, value: subtitle(item, prefix: prefix))]
        if let snippet = item.snippet {
            if let keyword = snippet.typedKeyword(prefix: prefix) {
                metadata.append(.label(Strings.keywordLabel, value: keyword))
                metadata.append(
                    .label(
                        Strings.expansionLabel,
                        value: snippet.expands ? Strings.expandsValue : Strings.doesNotExpandValue))
            } else if let keyword = item.keyword {
                metadata.append(.label(Strings.importKeywordInFileLabel, value: prefix + keyword))
            }
            if let collection = snippet.collection {
                metadata.append(.label(Strings.collectionLabel, value: collection, icon: .symbol("folder")))
            }
            if let original = item.renamedFrom {
                metadata.append(.label(Strings.importNameInFileLabel, value: original))
            }
        }
        if !item.keptAsTyped.isEmpty {
            metadata.append(
                .tags(Strings.importKeptAsTypedLabel, item.keptAsTyped.map { Tag(tag($0), color: .orange) }))
        }
        if !item.nowFilled.isEmpty {
            metadata.append(.tags(Strings.importNowFilledLabel, item.nowFilled.map { Tag(tag($0), color: .purple) }))
        }
        let body: DetailBody? = item.text.isEmpty ? nil : .markdown(SnippetDetail.marked(Template(item.text)))
        return Detail(body, metadata: metadata)
    }

    /// A placeholder as a tag: on one line and short.
    private static func tag(_ token: String) -> String {
        DisplayText.fileName(token, limit: 40)
    }
}
