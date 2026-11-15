import Kit

/// The feature's settings, stored as `calculator.<name>`. `nonisolated`, so code off the main actor
/// can read them.
nonisolated enum CalcSettings {
    /// The most decimal places a number, percentage or unit answer shows.
    static let decimalPlaces = SettingKey("decimalPlaces", default: DecimalPlaces.automatic)
    /// How thousands are grouped. Default: as the region in System Settings does.
    static let grouping = SettingKey("grouping", default: DigitGrouping.system)
    /// The decimal separator, for answers and for what the user types.
    static let decimalMark = SettingKey("decimalMark", default: DecimalMark.system)
    /// The order of day, month and year in date answers.
    static let dateOrder = SettingKey("dateOrder", default: DateOrderChoice.system)
    /// A 12-hour or 24-hour clock in time answers.
    static let clock = SettingKey("clock", default: ClockChoice.system)
    /// The unit trigonometry uses when the question names none. Radians, as most calculators and
    /// search engines read sin(30).
    static let angles = SettingKey("angles", default: AngleChoice.radians)
    /// The currency a bare "$" and "dollars" mean.
    static let dollar = SettingKey("dollar", default: DollarChoice.automatic)
    /// Whether copied and pasted answers are kept.
    static let keepsHistory = SettingKey("keepsHistory", default: true)
    /// The most answers the history keeps.
    static let historyLimit = SettingKey("historyLimit", default: 100)
    /// Whether the feature may download exchange rates.
    static let downloadsRates = SettingKey("downloadsRates", default: true)

    /// The choices offered for the history's size.
    static let historyLimits = [25, 50, 100, 250, 500, 1000]
    /// The bounds applied to a stored history size, whatever wrote it.
    static let historyLimitRange = 1...10_000

    /// The settings that change how the engine reads and writes numbers, dates and times.
    static let contextKeys: [AnySettingKey] = [
        grouping.erased, decimalMark.erased, dateOrder.erased, clock.erased, angles.erased, dollar.erased,
    ]
}

/// The most decimal places an answer shows.
nonisolated enum DecimalPlaces: String, SettingValue, CaseIterable, Sendable {
    case automatic, zero, one, two, three, four, six, eight, ten

    /// The number of places, or nil for the engine's own rounding: 12 significant digits for
    /// arithmetic and 6 for units.
    var places: Int? {
        switch self {
        case .automatic: nil
        case .zero: 0
        case .one: 1
        case .two: 2
        case .three: 3
        case .four: 4
        case .six: 6
        case .eight: 8
        case .ten: 10
        }
    }
}

/// How thousands are grouped.
nonisolated enum DigitGrouping: String, SettingValue, CaseIterable, Sendable {
    case system, none, comma, period, space, apostrophe

    /// The separator, or nil for the region's own or for none; see ``CalcContextBuilder``.
    var separator: Unicode.Scalar? {
        switch self {
        case .system, .none: nil
        case .comma: ","
        case .period: "."
        case .space: "\u{202F}"
        case .apostrophe: "\u{2019}"
        }
    }
}

/// The decimal separator.
nonisolated enum DecimalMark: String, SettingValue, CaseIterable, Sendable {
    case system, point, comma
}

/// The order of day, month and year.
nonisolated enum DateOrderChoice: String, SettingValue, CaseIterable, Sendable {
    case system, dayMonthYear, monthDayYear, yearMonthDay
}

/// A 12-hour or 24-hour clock.
nonisolated enum ClockChoice: String, SettingValue, CaseIterable, Sendable {
    case system, twelveHour, twentyFourHour
}

/// The default unit of angles.
nonisolated enum AngleChoice: String, SettingValue, CaseIterable, Sendable {
    case radians, degrees
}

/// The currency "$" and "dollars" mean.
nonisolated enum DollarChoice: String, SettingValue, CaseIterable, Sendable {
    case automatic, usd, cad, aud, nzd, sgd, hkd

    /// The ISO 4217 code, or nil to follow the region.
    var code: String? {
        self == .automatic ? nil : rawValue.uppercased()
    }
}
