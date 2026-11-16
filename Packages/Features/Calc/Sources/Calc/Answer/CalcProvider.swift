import CoreBridge
import Foundation
import Kit

/// The calculator in root search: answers as the user types.
///
/// Budget: 100 µs per keystroke on the main thread. The engine rejects a query that is not math in
/// tens of nanoseconds and allocates nothing, and nothing before it allocates either: no trimming,
/// no settings read. Work that allocates starts only once the engine has an answer.
///
/// Its answers change when exchange rates arrive, so it declares ``answersChanged``: root search
/// asks again for the query on screen and the loading row becomes the conversion in place.
final class CalcProvider: InstantProvider {
    /// A longer query is pasted text, not a question. The engine stops at 256 bytes anyway.
    static let maximumQueryBytes = 1024

    let namespace = AnswerRows.namespace
    private let engine: CalcEngine
    private let rates: RateKeeper
    private let actionsMaker: CalcActions
    private let settings: FeatureSettings
    private let clock: any ClockService

    init(engine: CalcEngine, rates: RateKeeper, actions: CalcActions, context: FeatureContext) {
        self.engine = engine
        self.rates = rates
        self.actionsMaker = actions
        self.settings = context.settings
        self.clock = context.clock
    }

    var answersChanged: ChangeSignal? { rates.ratesChanged }

    func answer(for query: String) -> InstantAnswer? {
        guard engine.isReady, let calculator = engine.calculator, query.utf8.count <= Self.maximumQueryBytes,
            let result = calculator.evaluate(
                QueryFolding.folded(query) ?? query, at: clock.now.timeIntervalSince1970)
        else { return nil }
        return present(result, query: query)
    }

    func actions(for row: Row) -> [Action] {
        actionsMaker.forAnswer(row)
    }

    private func present(_ result: CalculatorAnswer, query: String) -> InstantAnswer {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.convertsCurrency(result) { rates.currencyQuestionTyped() }
        let row: Row
        if result.kind == .error, result.problem == .noRates {
            row = AnswerRows.ratesRow(ratesStatus(), question: question)
        } else {
            row = AnswerRows.row(
                for: result, question: question, context: engine.context,
                places: settings[CalcSettings.decimalPlaces].places)
        }
        return InstantAnswer(
            rows: [row], claimsTop: result.claimsTop, sectionTitle: result.claimsTop ? nil : CalcStrings.featureName)
    }

    /// What a currency conversion without rates says.
    private func ratesStatus() -> AnswerPayload.Status {
        if rates.state == .loading { return .ratesLoading }
        return rates.isEnabled ? .ratesUnavailable : .ratesOff
    }

    /// True when the answer is a currency conversion: one that used rates, which the engine notes
    /// with their date, or one that needed rates it did not have. A bare amount such as "$5" needs
    /// no rates, so it never starts a download.
    static func convertsCurrency(_ result: CalculatorAnswer) -> Bool {
        switch result.kind {
        case .currency: !result.note.isEmpty
        case .error: result.problem == .noRates || result.problem == .noRate
        default: false
        }
    }
}
