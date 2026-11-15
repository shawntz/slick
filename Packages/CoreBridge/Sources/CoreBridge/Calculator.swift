import SlickCoreC
import Synchronization

/// The calculator behind root search: arithmetic, percentages, bases, units, currency, dates,
/// durations and time zones. It answers in microseconds and says even faster when a query is not
/// math, so it runs on the main thread inside the keystroke.
///
/// Safe to use from any thread: the Rust handle sits behind a `Mutex`, which costs a few
/// nanoseconds uncontended. Time zone data and exchange rates are separate objects that you build
/// off the main thread and then attach.
public final class Calculator: Sendable {
    /// An answer at or above this confidence should claim the top of root search.
    public static let claimsTopConfidence = Int(SLICK_CALC_CLAIMS_TOP)
    /// Queries longer than this many UTF-8 bytes, after trimming, are never calculations.
    public static let maximumQueryLength = Int(SLICK_CALC_MAX_QUERY_LEN)

    private struct State {
        let handle: OpaquePointer
        /// Holds the UTF-8 of a query without contiguous storage, such as some bridged strings.
        let scratch: UnsafeMutableBufferPointer<UInt8>
    }

    private let state: Mutex<State>

    /// A calculator in the default context: UTC, '.' and ',', day-month-year, a 12-hour clock,
    /// radians and US dollars, with no zones and no rates. Checks the ABI version first.
    public init() throws(CoreError) {
        try RustCore.checkABI()
        var created: OpaquePointer?
        try CoreError.check(slick_calc_new(&created))
        guard let created else { throw .nullPointer }
        let scratch = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1024)
        scratch.initialize(repeating: 0)
        state = Mutex(State(handle: created, scratch: scratch))
    }

    deinit {
        state.withLock { s in
            slick_calc_free(s.handle)
            s.scratch.deallocate()
        }
    }

    /// Builds the lookup tables now, about 0.7 ms, so the first keystroke does not pay for it.
    /// Call it once off the main thread at launch.
    public static func prepare() {
        slick_calc_prepare()
    }

    /// Sets the formats, the local zone and what "$" means. Call it when the locale or the time
    /// zone changes, not per keystroke. A refused context leaves the old one in place.
    public func setContext(_ context: CalculatorContext) throws(CoreError) {
        var raw = SlickCalcContext()
        raw.local_offset_s = Int32(clamping: context.localOffsetSeconds)
        raw.decimal = context.decimalSeparator.value
        raw.grouping = context.groupingSeparator?.value ?? 0
        raw.date_order = context.dateOrder.rawValue
        raw.hour_cycle = context.hourCycle.rawValue
        raw.angle = context.angleUnit.rawValue
        var zone = context.localZone
        var dollar = context.dollarCurrency
        let status = state.withLock { s in
            zone.withUTF8 { z in
                dollar.withUTF8 { d in
                    slick_calc_set_context(s.handle, &raw, z.baseAddress, z.count, d.baseAddress, d.count)
                }
            }
        }
        try CoreError.check(status)
    }

    /// Attaches time zone rules, or detaches them with nil. Without them, queries such as "time in
    /// tokyo" answer that zone data is not loaded.
    public func setTimeZones(_ zones: CalculatorTimeZones?) {
        state.withLock { s in
            _ = slick_calc_set_zones(s.handle, zones?.handle)
        }
    }

    /// Attaches exchange rates, or detaches them with nil. Without them, currency conversions
    /// answer that rates are not loaded; the calculator never guesses a rate.
    public func setRates(_ rates: CurrencyRates?) {
        state.withLock { s in
            _ = slick_calc_set_rates(s.handle, rates?.handle)
        }
    }

    /// Evaluates `query` at `now`, Unix seconds. Returns nil when the query is not math, without
    /// allocating, including the String to UTF-8 step. A calculation without an answer, such as
    /// "1/0", comes back with kind `.error` and the reason in `main`.
    public func evaluate(_ query: String, at now: Double) -> CalculatorAnswer? {
        let milliseconds = Self.milliseconds(now)
        return state.withLock { s -> CalculatorAnswer? in
            var result = SlickCalcResult()
            let status = Self.withUTF8(of: query, scratch: s.scratch) { bytes, count in
                slick_calc_evaluate(s.handle, bytes, count, milliseconds, &result)
            }
            guard status == 1, let kind = CalculatorKind(rawValue: result.kind) else { return nil }
            let h = s.handle
            var alternates: [CalculatorAnswer.Alternate] = []
            alternates.reserveCapacity(Int(result.alternate_count))
            var index: UInt32 = 0
            while index < UInt32(result.alternate_count) {
                alternates.append(
                    CalculatorAnswer.Alternate(
                        label: Self.text(h, UInt32(SLICK_CALC_TEXT_ALTERNATE_LABEL), index, nil),
                        text: Self.text(h, UInt32(SLICK_CALC_TEXT_ALTERNATE), index, nil)))
                index += 1
            }
            return CalculatorAnswer(
                kind: kind,
                confidence: Int(result.confidence),
                problem: CalculatorProblem(rawValue: result.problem),
                main: Self.text(h, UInt32(SLICK_CALC_TEXT_MAIN), 0, Int(result.main_len)),
                copy: Self.text(h, UInt32(SLICK_CALC_TEXT_COPY), 0, Int(result.copy_len)),
                note: Self.text(h, UInt32(SLICK_CALC_TEXT_NOTE), 0, Int(result.note_len)),
                alternates: alternates)
        }
    }

    // MARK: Helpers

    static func milliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let ms = (seconds * 1000).rounded(.down)
        if ms >= 9.2e18 { return Int64.max }
        if ms <= -9.2e18 { return Int64.min }
        return Int64(ms)
    }

    /// Runs `body` with the query's UTF-8. Native strings are read in place. Others are copied into
    /// `scratch`; one longer than the scratch space cannot be a calculation and reads as empty.
    private static func withUTF8(
        of string: String, scratch: UnsafeMutableBufferPointer<UInt8>,
        _ body: (UnsafePointer<UInt8>?, Int) -> Int32
    ) -> Int32 {
        if let status = string.utf8.withContiguousStorageIfAvailable({ body($0.baseAddress, $0.count) }) {
            return status
        }
        var n = 0
        for byte in string.utf8 {
            if n == scratch.count { return body(nil, 0) }
            scratch[n] = byte
            n += 1
        }
        return body(UnsafePointer(scratch.baseAddress), n)
    }

    /// One text of the current answer. `length` is known for the main texts; alternates measure.
    private static func text(_ handle: OpaquePointer, _ which: UInt32, _ index: UInt32, _ length: Int?) -> String {
        let n = length ?? Int(max(0, slick_calc_text(handle, which, index, nil, 0)))
        guard n > 0 else { return "" }
        return String(unsafeUninitializedCapacity: n) { buffer in
            Int(max(0, slick_calc_text(handle, which, index, buffer.baseAddress, buffer.count)))
        }
    }
}

/// What a calculator answer is.
public enum CalculatorKind: UInt8, Hashable, Sendable {
    case number = 1
    case percent = 2
    /// A number with a unit, such as a length or a temperature.
    case quantity = 3
    /// A length of time, such as "3 h 15 min".
    case duration = 4
    case currency = 5
    case date = 6
    /// A moment or a time of day, possibly in another time zone.
    case time = 7
    /// Text, such as a number in words.
    case text = 8
    /// A calculation without an answer. `problem` says why and `main` says it in words.
    case error = 9
}

/// Why a calculation has no answer.
public enum CalculatorProblem: UInt8, Hashable, Sendable {
    case divisionByZero = 1
    case overflow = 2
    case undefined = 3
    case notReal = 4
    case notWhole = 5
    case incompatibleUnits = 6
    case noRates = 7
    case noRate = 8
    case noTimeZones = 9
    case unknownZone = 10
    case invalidDate = 11
    case unsupported = 12
}

/// One calculator answer.
public struct CalculatorAnswer: Hashable, Sendable {
    /// Another way to write the answer, such as the value in hex or in the other unit system.
    public struct Alternate: Hashable, Sendable {
        /// A short label such as "Hex", "Fraction" or "Imperial".
        public let label: String
        public let text: String
    }

    public let kind: CalculatorKind
    /// How sure the calculator is that the query was meant as math, from 1 to 100.
    public let confidence: Int
    /// Set for `.error` answers.
    public let problem: CalculatorProblem?
    /// The formatted answer, such as "3.10686 mi".
    public let main: String
    /// The value to copy: no grouping, no unit, the context's decimal separator. Dates are ISO
    /// 8601.
    public let copy: String
    /// Context such as the rate date or the zone name. Often empty.
    public let note: String
    /// Up to four other forms, best first.
    public let alternates: [Alternate]

    /// True when the answer should claim the top of root search.
    public var claimsTop: Bool { confidence >= Calculator.claimsTopConfidence }
}

/// What the calculator knows about the user's formats and place. The calculator has no locale
/// logic of its own: fill this from the locale and the time zone when either changes.
public struct CalculatorContext: Hashable, Sendable {
    /// The order of day, month and year in answers.
    public enum DateOrder: UInt8, Hashable, Sendable {
        case dayMonthYear = 0
        case monthDayYear = 1
        case yearMonthDay = 2
    }

    /// A 12-hour or 24-hour clock in answers.
    public enum HourCycle: UInt8, Hashable, Sendable {
        case twelveHour = 0
        case twentyFourHour = 1
    }

    /// The unit trigonometry takes and returns when the query names none.
    public enum AngleUnit: UInt8, Hashable, Sendable {
        case radians = 0
        case degrees = 1
    }

    /// The local IANA zone, such as "Europe/Paris". May be empty.
    public var localZone: String
    /// The local zone's UTC offset now, in seconds east of UTC. Used only when the attached zone
    /// data lacks the local zone.
    public var localOffsetSeconds: Int
    public var decimalSeparator: Unicode.Scalar
    /// Nil for no grouping.
    public var groupingSeparator: Unicode.Scalar?
    public var dateOrder: DateOrder
    public var hourCycle: HourCycle
    public var angleUnit: AngleUnit
    /// The currency a bare "$" and "dollars" mean, as an ISO 4217 code.
    public var dollarCurrency: String

    public init(
        localZone: String = "",
        localOffsetSeconds: Int = 0,
        decimalSeparator: Unicode.Scalar = ".",
        groupingSeparator: Unicode.Scalar? = ",",
        dateOrder: DateOrder = .dayMonthYear,
        hourCycle: HourCycle = .twelveHour,
        angleUnit: AngleUnit = .radians,
        dollarCurrency: String = "USD"
    ) {
        self.localZone = localZone
        self.localOffsetSeconds = localOffsetSeconds
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.dateOrder = dateOrder
        self.hourCycle = hourCycle
        self.angleUnit = angleUnit
        self.dollarCurrency = dollarCurrency
    }
}

/// Time zone rules for every zone the calculator names, read once from a compiled zoneinfo
/// folder. Immutable, so one value can be attached to many calculators.
public final class CalculatorTimeZones: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer
    /// The number of zones loaded.
    public let count: Int

    /// Reads the system's zoneinfo, plus `extraZones` such as the local zone when the calculator
    /// does not already name it. Reads about 260 small files: call it off the main thread.
    public convenience init(extraZones: [String] = []) throws(CoreError) {
        try self.init(directory: "", extraZones: extraZones)
    }

    /// Reads zones from a compiled zoneinfo folder. An empty `directory` means the system's.
    public init(directory: String, extraZones: [String]) throws(CoreError) {
        try RustCore.checkABI()
        var dir = directory
        var extra = extraZones.joined(separator: "\u{1F}")
        var loaded: OpaquePointer?
        let status = dir.withUTF8 { d in
            extra.withUTF8 { e in slick_calc_zones_load(d.baseAddress, d.count, e.baseAddress, e.count, &loaded) }
        }
        count = Int(try CoreError.check(status))
        guard let loaded else { throw .nullPointer }
        handle = loaded
    }

    deinit {
        slick_calc_zones_free(handle)
    }
}

/// Exchange rates against one base currency, with the time they were fetched. Immutable, so one
/// value can be attached to many calculators. Build it off the main thread when rates refresh.
public final class CurrencyRates: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer
    /// Currencies in the table, the base included.
    public let count: Int
    /// Codes that were refused: not 2 to 6 ASCII letters, or a rate that is not finite and positive.
    public let refused: [String]

    /// A table of how many units of each currency one unit of `base` buys, fetched at `fetchedAt`,
    /// Unix seconds. Throws `.invalidArgument` when `base` is not a currency code.
    public init(base: String, fetchedAt: Double, rates: [String: Double]) throws(CoreError) {
        try RustCore.checkABI()
        var base = base
        var created: OpaquePointer?
        let ms = Calculator.milliseconds(fetchedAt)
        try CoreError.check(base.withUTF8 { slick_calc_rates_new($0.baseAddress, $0.count, ms, &created) })
        guard let created else { throw .nullPointer }
        var refused: [String] = []
        for (code, rate) in rates.sorted(by: { $0.key < $1.key }) {
            var code = code
            let status = code.withUTF8 { slick_calc_rates_insert(created, $0.baseAddress, $0.count, rate) }
            if status != 1 { refused.append(code) }
        }
        handle = created
        count = Int(max(0, slick_calc_rates_count(created)))
        self.refused = refused
    }

    deinit {
        slick_calc_rates_free(handle)
    }
}
