import CoreBridge
import Kit

/// Every string of the feature that a person reads, in one place so it can be translated. Titles of
/// commands, actions, sections, empty states, toasts and HUDs use title case without a full stop.
/// Everything else is a plain sentence. Answers, notes and the labels of other forms come from the
/// engine instead.
nonisolated enum CalcStrings {
    // MARK: Feature

    static let featureName = "Calculator"
    static let summary =
        "Answers math, unit, currency, date and time zone questions as you type, and keeps the answers you copy."
    static let accessibilityReason = "Paste answers into the frontmost app."
    static let engineMissingTitle = "Calculator Unavailable"
    static let engineMissingMessage = "The calculator engine could not start, so root search shows no answers."
    static let readOnlyTitle = "Calculator History Is Read Only"
    static let readOnlyMessage =
        "The history file was written by a newer version of \(Brand.name). Answers you copy show in the history "
        + "until the feature stops, and the file is left as it is."

    // MARK: How the engine read the question

    /// The row's subtitle: what kind of question the engine saw, then its note, such as the rates'
    /// date or the zone.
    static func reading(_ kind: CalculatorKind, note: String) -> String {
        let label =
            switch kind {
            case .number: "Arithmetic"
            case .percent: "Percentage"
            case .quantity: "Units"
            case .duration: "Duration"
            case .currency: "Currency"
            case .date: "Date"
            case .time: "Time"
            case .text: "Text"
            case .error: "No answer"
            }
        return note.isEmpty ? label : label + " · " + note
    }

    /// The subtitle of a question without an answer.
    static func problem(_ problem: CalculatorProblem?) -> String {
        switch problem {
        case .divisionByZero: "A number cannot be divided by zero."
        case .overflow: "The answer is too large to work out."
        case .undefined: "The answer is not defined."
        case .notReal: "The answer is not a real number."
        case .notWhole: "This needs a whole number."
        case .incompatibleUnits: "These units measure different things, so one cannot become the other."
        case .noRate: "The European Central Bank publishes no rate for this currency."
        case .noTimeZones, .unknownZone: "There are no time zone rules for this place."
        case .invalidDate: "This date does not exist."
        case .noRates, .unsupported, nil: "The calculator cannot answer this question."
        }
    }

    // MARK: Exchange rates in root search

    static let ratesLoadingTitle = "Loading Exchange Rates"
    static let ratesLoadingSubtitle =
        "Rates are on their way from the European Central Bank. Press Return to see the answer."
    static let ratesUnavailableTitle = "Exchange Rates Unavailable"
    static let ratesUnavailableSubtitle =
        "The European Central Bank could not be reached. Press Return to try again."
    static let ratesOffTitle = "Exchange Rates Are Off"
    static let ratesOffSubtitle =
        "Press Return to turn them on. One request a day goes to the European Central Bank."

    // MARK: Actions

    static let copyAnswer = "Copy Answer"
    static let pasteAnswer = "Paste Answer"
    static let copyPlainNumber = "Copy as Plain Number"
    static let copyQuestionAndAnswer = "Copy Question and Answer"
    static let openHistory = "Open Calculator History"
    static let useAgain = "Use Again"
    static let deleteEntry = "Delete Answer"
    static let clearHistory = "Clear History"
    static let showAnswer = "Show Answer"
    static let tryAgain = "Try Again"
    static let turnOnRates = "Turn On Exchange Rates"
    static let refreshRates = "Refresh Exchange Rates"
    static let refreshedRates = "Refreshed Exchange Rates"
    static let otherForms = "Other Forms"

    static func copied(_ text: String) -> String { "Copied \(shortened(text))" }
    static let copiedQuestionAndAnswer = "Copied Question and Answer"

    /// "Copy Hex", from the engine's label for another form of the answer.
    static func copyForm(_ label: String) -> String {
        "Copy " + label.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The question and answer on one line, as Copy Question and Answer writes them.
    static func questionAndAnswer(_ question: String, _ answer: String) -> String {
        "\(question) = \(answer)"
    }

    static let ratesFailedTitle = "Exchange Rates Unavailable"
    static let ratesFailedMessage = "The European Central Bank could not be reached. Try again later."
    static let ratesOffMessage = "Turn on Download exchange rates in the Calculator settings to convert currencies."

    // MARK: History page

    static let historyCommand = "Calculator History"
    static let historyKeywords = ["calc", "calculator", "math", "answers", "past calculations", "results"]
    static let historyPlaceholder = "Search calculator history"
    static let emptyHistoryTitle = "No Calculator History"
    static let emptyHistoryMessage = "Answers you copy or paste from the calculator show up here."
    static let historyOffTitle = "Calculator History Is Off"
    static let historyOffMessage = "Turn on history in the Calculator settings to keep the answers you copy."
    /// Names the question, so a stale list cannot hide which answer goes.
    static func deleteQuestion(_ question: String) -> String {
        "Delete “\(shortened(question))” from History?"
    }
    static let deleteMessage = "This cannot be undone."
    static let deleteConfirm = "Delete"
    static let deletedToast = "Deleted Answer"
    static let clearQuestion = "Clear Calculator History?"
    static let clearMessage = "Every saved answer is deleted. This cannot be undone."
    static let clearConfirm = "Clear History"
    static let clearedToast = "Cleared Calculator History"

    // MARK: Settings

    static let answersSection = "Answers"
    static let decimalPlaces = "Decimal places"
    static let decimalPlacesInfo =
        "Rounds numbers, percentages and units to at most this many places. Money keeps its currency's cents."
    static func decimalPlacesOption(_ choice: DecimalPlaces) -> String {
        guard let places = choice.places else { return "Automatic" }
        return places == 1 ? "1 place" : "\(places) places"
    }

    static let grouping = "Digit grouping"
    static let groupingInfo =
        "Separates thousands in answers. A separator that matches the decimal separator is left out."
    static func groupingOption(_ choice: DigitGrouping) -> String {
        switch choice {
        case .system: "As in System Settings"
        case .none: "None: 1234567"
        case .comma: "Comma: 1,234,567"
        case .period: "Period: 1.234.567"
        case .space: "Space: 1 234 567"
        case .apostrophe: "Apostrophe: 1’234’567"
        }
    }

    static let decimalMark = "Decimal separator"
    static let decimalMarkInfo = "Used in answers and in what you type."
    static func decimalMarkOption(_ choice: DecimalMark) -> String {
        switch choice {
        case .system: "As in System Settings"
        case .point: "Point: 1.5"
        case .comma: "Comma: 1,5"
        }
    }

    static let dateOrder = "Dates"
    static func dateOrderOption(_ choice: DateOrderChoice) -> String {
        switch choice {
        case .system: "As in System Settings"
        case .dayMonthYear: "Day, month, year"
        case .monthDayYear: "Month, day, year"
        case .yearMonthDay: "Year, month, day"
        }
    }

    static let clock = "Times"
    static func clockOption(_ choice: ClockChoice) -> String {
        switch choice {
        case .system: "As in System Settings"
        case .twelveHour: "12-hour clock"
        case .twentyFourHour: "24-hour clock"
        }
    }

    static let angles = "Angles"
    static let anglesInfo = "The unit of sin(30) and asin(0.5) when the question names none."
    static func anglesOption(_ choice: AngleChoice) -> String {
        choice == .degrees ? "Degrees" : "Radians"
    }

    static let dollar = "$ and dollars mean"
    static let dollarInfo =
        "Automatic follows your region when its currency is a dollar, and uses US dollars otherwise."
    static func dollarOption(_ choice: DollarChoice) -> String {
        switch choice {
        case .automatic: "Automatic"
        case .usd: "US dollars"
        case .cad: "Canadian dollars"
        case .aud: "Australian dollars"
        case .nzd: "New Zealand dollars"
        case .sgd: "Singapore dollars"
        case .hkd: "Hong Kong dollars"
        }
    }

    static let historySection = "History"
    static func historyFooter(appName: String) -> String {
        "Answers you copy or paste are kept in Features/calculator/\(CalcHistory.fileName) in "
            + "\(appName)'s data folder. They never leave this Mac."
    }
    static let keepsHistory = "Keep answers you copy or paste"
    static let keepsHistoryInfo = "Turning this off keeps what is saved until you clear it."
    static let historyLimit = "Keep at most"
    static let historyLimitInfo = "Lowering it deletes the oldest answers at once, after asking."
    static func historyLimitOption(_ count: Int) -> String { "\(count) answers" }
    static func limitQuestion(_ count: Int) -> String { "Keep Only \(count) Answers?" }
    static func limitMessage(_ count: Int) -> String {
        "Answers older than the newest \(count) are deleted now. This cannot be undone."
    }
    static let limitConfirm = "Delete Older Answers"

    static let ratesSection = "Exchange Rates"
    static let ratesFooter =
        "The first time you type a currency conversion, and then at most once a day, one request goes to "
        + "www.ecb.europa.eu for the European Central Bank's reference rates. It carries nothing about you "
        + "or what you typed. The rates are saved in Features/calculator/\(ReferenceRates.fileName) in the "
        + "same data folder, so conversions work offline and show the day of the rates they use."
    static let downloadsRates = "Download exchange rates"
    static let downloadsRatesInfo = "When this is off, currency conversions use the last saved rates, if any."

    // MARK: Helpers

    /// Text cut to a length a HUD can show.
    static func shortened(_ text: String, limit: Int = 40) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Text on one line for a title: line breaks and other control characters become spaces,
    /// direction overrides are dropped, runs of plain spaces become one, and the ends are trimmed.
    /// Other spaces, such as the narrow one that groups digits, stay as they are.
    static func oneLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                pendingSpace = !scalars.isEmpty
                continue
            default:
                if scalar == " " {
                    pendingSpace = !scalars.isEmpty
                    continue
                }
            }
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { continue }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
