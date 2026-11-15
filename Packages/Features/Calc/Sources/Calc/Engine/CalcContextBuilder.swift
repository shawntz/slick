import CoreBridge
import Foundation
import Kit

/// The format choices from settings, read on the main actor and handed to the context builder.
nonisolated struct FormatChoices: Hashable, Sendable {
    var grouping: DigitGrouping
    var decimalMark: DecimalMark
    var dateOrder: DateOrderChoice
    var clock: ClockChoice
    var angles: AngleChoice
    var dollar: DollarChoice

    init(
        grouping: DigitGrouping = .system, decimalMark: DecimalMark = .system, dateOrder: DateOrderChoice = .system,
        clock: ClockChoice = .system, angles: AngleChoice = .radians, dollar: DollarChoice = .automatic
    ) {
        self.grouping = grouping
        self.decimalMark = decimalMark
        self.dateOrder = dateOrder
        self.clock = clock
        self.angles = angles
        self.dollar = dollar
    }

    init(_ settings: FeatureSettings) {
        self.init(
            grouping: settings[CalcSettings.grouping], decimalMark: settings[CalcSettings.decimalMark],
            dateOrder: settings[CalcSettings.dateOrder], clock: settings[CalcSettings.clock],
            angles: settings[CalcSettings.angles], dollar: settings[CalcSettings.dollar])
    }
}

/// Turns the region and the user's choices into the engine's context. The engine has no locale
/// logic of its own, so everything it needs to read and write numbers, dates and times is decided
/// here. Pure, so it runs off the main thread and tests call it directly.
nonisolated enum CalcContextBuilder {
    /// Currencies people call dollars. A region whose currency is one of them gets it for "$".
    static let dollarCurrencies: Set<String> = ["USD", "CAD", "AUD", "NZD", "SGD", "HKD", "TWD"]

    static func context(region: RegionSnapshot, choices: FormatChoices, now: Date) -> CalculatorContext {
        let locale = region.locale
        let decimal: Unicode.Scalar =
            switch choices.decimalMark {
            case .system: decimalSeparator(of: locale)
            case .point: "."
            case .comma: ","
            }
        var grouping: Unicode.Scalar? =
            switch choices.grouping {
            case .system: groupingSeparator(of: locale, decimal: decimal)
            case .none: nil
            default: choices.grouping.separator
            }
        // The same mark cannot both group and separate decimals.
        if grouping == decimal { grouping = nil }
        let dateOrder: CalculatorContext.DateOrder =
            switch choices.dateOrder {
            case .system: Self.dateOrder(of: locale)
            case .dayMonthYear: .dayMonthYear
            case .monthDayYear: .monthDayYear
            case .yearMonthDay: .yearMonthDay
            }
        let hourCycle: CalculatorContext.HourCycle =
            switch choices.clock {
            case .system: Self.hourCycle(of: locale)
            case .twelveHour: .twelveHour
            case .twentyFourHour: .twentyFourHour
            }
        return CalculatorContext(
            localZone: region.timeZone.identifier,
            localOffsetSeconds: region.timeZone.secondsFromGMT(for: now),
            decimalSeparator: decimal,
            groupingSeparator: grouping,
            dateOrder: dateOrder,
            hourCycle: hourCycle,
            angleUnit: choices.angles == .degrees ? .degrees : .radians,
            dollarCurrency: choices.dollar.code ?? dollarCurrency(of: locale))
    }

    /// The region's decimal separator, "." when it has none.
    static func decimalSeparator(of locale: Locale) -> Unicode.Scalar {
        locale.decimalSeparator?.unicodeScalars.first ?? "."
    }

    /// The region's grouping separator. A region that groups with the decimal separator, or with
    /// nothing, gets no grouping.
    static func groupingSeparator(of locale: Locale, decimal: Unicode.Scalar) -> Unicode.Scalar? {
        guard let scalar = locale.groupingSeparator?.unicodeScalars.first, scalar != decimal else { return nil }
        return scalar
    }

    /// The order of day, month and year in the region's short date format.
    static func dateOrder(of locale: Locale) -> CalculatorContext.DateOrder {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "d/M/y"
        let year = pattern.firstIndex(of: "y")
        let month = pattern.firstIndex(of: "M")
        let day = pattern.firstIndex(of: "d")
        guard let month, let day else { return .dayMonthYear }
        if let year, year < month, year < day { return .yearMonthDay }
        return month < day ? .monthDayYear : .dayMonthYear
    }

    /// The region's clock, which also follows the 24-hour switch in System Settings.
    static func hourCycle(of locale: Locale) -> CalculatorContext.HourCycle {
        switch locale.hourCycle {
        case .zeroToEleven, .oneToTwelve: .twelveHour
        case .zeroToTwentyThree, .oneToTwentyFour: .twentyFourHour
        @unknown default: .twelveHour
        }
    }

    /// The region's currency when people there call it dollars, otherwise US dollars.
    static func dollarCurrency(of locale: Locale) -> String {
        guard let code = locale.currency?.identifier.uppercased(), dollarCurrencies.contains(code) else { return "USD" }
        return code
    }
}
