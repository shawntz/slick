import Foundation
import Kit

/// Root search's translations: "translate <text>" or "tr <text>", optionally ending in "to" and a
/// language name, show one row at the top. The row says it is translating, and fills with the
/// translation when it arrives: the provider sends ``answersChanged`` and root search asks again
/// for the query on screen.
///
/// ``answer(for:)`` runs inside the keystroke, within the instant budget. It turns away any query
/// that does not start with "t" on its first byte. For a keyword it reads one setting, scans the
/// text once for " to " and looks a short name up in the language list. The translation runs
/// after a pause in typing, off the main thread, in a task that the next query cancels.
///
/// Rows are answers to one query, so root search remembers none of them and learns nothing.
final class KeywordProvider: InstantProvider {
    /// How long the query must be still before a translation starts.
    static let debounce = Duration.milliseconds(200)
    /// How many finished answers are kept, so going back to an earlier query shows it at once.
    static let keptAnswers = 16

    let namespace = TranslationRows.namespace
    private let pages: TranslatePages
    private let signal = ChangeSignal()

    /// The request being translated, from the pause until its answer arrives.
    private var pending: RootRequest?
    private var work: Task<Void, Never>?
    /// Finished answers, oldest first. Only translations stay past the next request: an answer
    /// that asks for a download is asked again, since the user may have downloaded the language.
    private var answers: [(request: RootRequest, presented: Presented)] = []

    init(pages: TranslatePages) {
        self.pages = pages
    }

    var answersChanged: ChangeSignal? { signal }

    func answer(for query: String) -> InstantAnswer? {
        guard let text = RootKeyword.text(in: query), pages.translator.settings[TranslateSettings.keywords] else {
            if work != nil { stop() }
            return nil
        }
        if TranslationText.exceeds(text, bytes: TranslationText.rootMaximumBytes) {
            if work != nil { stop() }
            // The page refuses text past its own limit, so the row carries at most one byte more.
            let original =
                TranslationText.exceeds(text, bytes: TranslationText.maximumBytes)
                ? String(decoding: text.utf8.prefix(TranslationText.maximumBytes + 1), as: UTF8.self) : String(text)
            return answer(
                TranslationRows.row(
                    .tooLong, original: original, requested: nil, catalog: pages.translator.catalogOrEmpty,
                    id: TranslationRows.rootRowID, place: .root))
        }
        guard let catalog = pages.translator.catalog else {
            // The list arrives soon after activation; the feature sends the signal when it does.
            pages.translator.startLoading()
            return answer(
                TranslationRows.loadingRow(original: String(text), requested: nil, id: TranslationRows.rootRowID))
        }
        let request = RootKeyword.request(text, catalog: catalog)
        if let done = answers.last(where: { $0.request == request }) {
            return answer(done.presented.row)
        }
        if pending != request { start(request, catalog: catalog) }
        return answer(
            TranslationRows.loadingRow(original: request.text, requested: request.target, id: TranslationRows.rootRowID)
        )
    }

    func actions(for row: Row) -> [Action] {
        pages.actions(for: row, place: .root)
    }

    /// Forgets every answer and asks root search again, as after a change of languages in
    /// settings.
    func reset() {
        stop()
        answers.removeAll()
        signal.send()
    }

    /// Asks root search again, as when the language list arrives.
    func refresh() {
        signal.send()
    }

    /// Stops the translation on its way, as when the query is no longer a translation.
    func stop() {
        work?.cancel()
        work = nil
        pending = nil
    }

    private func answer(_ row: Row) -> InstantAnswer {
        InstantAnswer(rows: [row], claimsTop: true)
    }

    private func start(_ request: RootRequest, catalog: LanguageCatalog) {
        stop()
        answers.removeAll { $0.presented.outcome.translation == nil }
        pending = request
        let translator = pages.translator
        let plan = translator.plan(target: request.target, isExplicit: request.target != nil, catalog: catalog)
        let engine = translator.engine
        let clock = translator.clock
        work = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.debounce)
                let text = await Self.cleaned(request.text)
                let outcome =
                    text.isEmpty
                    ? TranslationOutcome.notRecognized
                    : try await TranslationPipeline.run(text, plan: plan, engine: engine)
                let presented = await TranslationRows.present(
                    outcome, original: request.text, requested: request.target, catalog: catalog, place: .root)
                try Task.checkCancellation()
                self?.finish(request, presented)
            } catch {
                // Cancelled because the query changed: the newer request has its own work.
            }
        }
    }

    private func finish(_ request: RootRequest, _ presented: Presented) {
        guard pending == request else { return }
        pending = nil
        work = nil
        answers.removeAll { $0.request == request }
        answers.append((request, presented))
        if answers.count > Self.keptAnswers { answers.removeFirst(answers.count - Self.keptAnswers) }
        signal.send()
    }

    @concurrent private static func cleaned(_ text: String) async -> String {
        TranslationText.cleaned(text)
    }
}
