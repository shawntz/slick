import Foundation
import Kit

/// The list behind the Translate page. It filters itself: each query is one translation, run
/// after the host's debounce in a task the host cancels when the query or the menu changes. A
/// cancelled translation throws, so its answer never reaches the page. Nothing translates on the
/// main thread: the pipeline and the row are built in `@concurrent` functions.
///
/// When the page shows again after the panel was closed while it asked for a download, it
/// translates again, since the user may have downloaded the language in System Settings.
final class TranslateList: ListSource, PageEvents {
    /// Long enough that a translation waits for a pause in typing, short enough to feel live.
    static let debounce = Duration.milliseconds(250)

    private let pages: TranslatePages
    private let catalog: LanguageCatalog
    private let hint: LanguageTag?
    private let signal = ChangeSignal()
    /// What the last load showed, so the detail pane needs no second translation.
    private(set) var shown: Presented?

    init(pages: TranslatePages, catalog: LanguageCatalog, hint: LanguageTag?) {
        self.pages = pages
        self.catalog = catalog
        self.hint = hint
    }

    var filtering: ListFiltering { .custom(debounce: Self.debounce) }
    var changes: ChangeSignal? { signal }
    var reloadsOnSettings: [AnySettingKey] { [TranslateSettings.secondTarget.erased] }

    func load(_ request: ListRequest) async throws -> ListResult {
        let translator = pages.translator
        let target = request.filter.flatMap { catalog.entry($0)?.tag }
        if request.reason == .filter, let target { translator.rememberMenuTarget(target) }
        guard !TranslationText.exceeds(request.query, bytes: TranslationText.maximumBytes) else {
            shown = nil
            return ListResult(
                rows: [],
                emptyState: EmptyState(
                    icon: TranslationRows.problemIcon, title: TranslateStrings.tooLongTitle,
                    message: TranslateStrings.tooLongMessage))
        }
        let text = await Self.cleaned(request.query)
        try Task.checkCancellation()
        guard !text.isEmpty else {
            shown = nil
            return ListResult(rows: [])
        }
        let plan = translator.plan(target: target, isExplicit: false, hint: hint, catalog: catalog)
        let outcome = try await TranslationPipeline.run(text, plan: plan, engine: translator.engine)
        try Task.checkCancellation()
        let presented = await TranslationRows.present(
            outcome, original: text, requested: plan.target, catalog: catalog, place: .page)
        try Task.checkCancellation()
        shown = presented
        return ListResult(rows: [presented.row])
    }

    func actions(for row: Row) -> [Action] {
        pages.actions(for: row, place: .page)
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let shown, shown.row.id == row.id else { return nil }
        return shown.detail
    }

    func pageWillShowAgain(_ reason: PageShowReason) {
        if case .needsDownload = shown?.outcome { signal.send() }
    }

    @concurrent private static func cleaned(_ text: String) async -> String {
        TranslationText.cleaned(text)
    }
}
