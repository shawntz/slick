import CoreBridge
import Foundation
import Kit

/// What a calculator row carries, so its actions need nothing else.
nonisolated struct AnswerPayload: Codable, Hashable, Sendable {
    /// What the row is.
    enum Status: String, Codable, Hashable, Sendable {
        /// An answer.
        case answer
        /// A question the engine understood but cannot answer, such as "1/0".
        case problem
        /// A currency conversion waiting for rates that are downloading.
        case ratesLoading
        /// A currency conversion without rates, because the download failed.
        case ratesUnavailable
        /// A currency conversion without rates, because downloads are off.
        case ratesOff
    }

    /// Another form of the answer, such as its hex value.
    struct Form: Codable, Hashable, Sendable {
        var label: String
        var text: String
    }

    var status: Status
    /// What the user typed, trimmed.
    var question: String
    /// The answer as the row shows it.
    var answer: String
    /// The answer as a plain number, when it is one: no grouping and no unit.
    var plainNumber: String?
    var forms: [Form]
    /// True for an answer that used exchange rates. Optional, so payloads saved before it was added
    /// still decode.
    var usesRates: Bool?
}

/// Builds calculator rows from the engine's answers. Pure, so tests and benchmarks call it directly.
nonisolated enum AnswerRows {
    /// The namespace of every calculator row.
    static let namespace = "calculator"

    /// The row for an answer. `places` is the decimal places setting, nil for the engine's own.
    static func row(
        for result: CalculatorAnswer, question: String, context: CalculatorContext, places: Int?
    ) -> Row {
        if result.kind == .error {
            let payload = AnswerPayload(status: .problem, question: question, answer: "", forms: [])
            return Row(
                id: ItemID(namespace, question), title: result.main, subtitle: CalcStrings.problem(result.problem),
                icon: .symbol("exclamationmark.triangle"), payload: Payload(payload), memory: .never)
        }
        let roundsHere = places != nil && rounds(result.kind)
        let shown =
            roundsHere
            ? NumberRounding.round(
                result.main, places: places ?? 0, decimal: context.decimalSeparator,
                grouping: context.groupingSeparator)
            : result.main
        let payload = AnswerPayload(
            status: .answer, question: question, answer: shown,
            plainNumber: plainNumber(result, places: roundsHere ? places : nil, decimal: context.decimalSeparator),
            forms: result.alternates.map { AnswerPayload.Form(label: $0.label, text: $0.text) },
            usesRates: result.kind == .currency && !result.note.isEmpty ? true : nil)
        return Row(
            id: ItemID(namespace, question), title: shown,
            subtitle: CalcStrings.reading(result.kind, note: result.note),
            icon: icon(for: result.kind), payload: Payload(payload),
            completion: result.copy.isEmpty ? nil : result.copy,
            memory: .never)
    }

    /// The row a currency conversion shows while there is no rate table.
    static func ratesRow(_ status: AnswerPayload.Status, question: String) -> Row {
        let (title, subtitle): (String, String) =
            switch status {
            case .ratesLoading: (CalcStrings.ratesLoadingTitle, CalcStrings.ratesLoadingSubtitle)
            case .ratesOff: (CalcStrings.ratesOffTitle, CalcStrings.ratesOffSubtitle)
            default: (CalcStrings.ratesUnavailableTitle, CalcStrings.ratesUnavailableSubtitle)
            }
        let payload = AnswerPayload(status: status, question: question, answer: "", forms: [])
        return Row(
            id: ItemID(namespace, question), title: title, subtitle: subtitle, icon: .symbol("banknote"),
            payload: Payload(payload), memory: .never)
    }

    /// True for the kinds the decimal places setting rounds. Money keeps its currency's digits,
    /// and dates, times, durations and text are not decimals.
    static func rounds(_ kind: CalculatorKind) -> Bool {
        kind == .number || kind == .percent || kind == .quantity
    }

    /// The answer as a plain number, from the engine's copy value: no grouping, no unit and the
    /// context's decimal separator. A percentage loses its sign. Nil when the answer is not one
    /// number, such as a date, a fraction or "2 h 30 min".
    static func plainNumber(_ result: CalculatorAnswer, places: Int?, decimal: Unicode.Scalar) -> String? {
        switch result.kind {
        case .number, .percent, .quantity, .currency, .duration: break
        default: return nil
        }
        var text = result.copy
        if result.kind == .percent, text.hasSuffix("%") { text.removeLast() }
        guard isPlainNumber(text, decimal: decimal) else { return nil }
        guard let places else { return text }
        return NumberRounding.round(text, places: places, decimal: decimal, grouping: nil)
    }

    /// True for an optional minus, digits, an optional fraction after `decimal`, and an optional
    /// exponent.
    static func isPlainNumber(_ text: String, decimal: Unicode.Scalar) -> Bool {
        var scalars = text.unicodeScalars[...]
        if scalars.first == "-" { scalars = scalars.dropFirst() }
        let integer = scalars.prefix { ("0"..."9").contains($0) }
        guard !integer.isEmpty else { return false }
        scalars = scalars.dropFirst(integer.count)
        if scalars.first == decimal {
            scalars = scalars.dropFirst()
            let fraction = scalars.prefix { ("0"..."9").contains($0) }
            guard !fraction.isEmpty else { return false }
            scalars = scalars.dropFirst(fraction.count)
        }
        if scalars.first == "e" || scalars.first == "E" {
            scalars = scalars.dropFirst()
            if scalars.first == "-" || scalars.first == "+" { scalars = scalars.dropFirst() }
            let exponent = scalars.prefix { ("0"..."9").contains($0) }
            guard !exponent.isEmpty else { return false }
            scalars = scalars.dropFirst(exponent.count)
        }
        return scalars.isEmpty
    }

    static func icon(for kind: CalculatorKind) -> Icon {
        switch kind {
        case .number, .percent: .symbol("plus.forwardslash.minus")
        case .quantity: .symbol("ruler")
        case .duration: .symbol("timer")
        case .currency: .symbol("banknote")
        case .date: .symbol("calendar")
        case .time: .symbol("clock")
        case .text: .symbol("textformat")
        case .error: .symbol("exclamationmark.triangle")
        }
    }
}
