import CoreBridge
import Foundation

/// One day's exchange rates: how many units of each currency one euro buys, as the European
/// Central Bank publishes them, with the day they are for and when they were downloaded.
nonisolated struct RateTable: Codable, Hashable, Sendable {
    /// The currency the rates are against. Always "EUR" for the bank's table.
    var base: String
    /// The day the rates are for, as the bank writes it: `yyyy-MM-dd`.
    var day: String
    /// When the table was downloaded. The next download waits a day from here.
    var downloadedAt: Date
    /// Units of each currency per unit of ``base``.
    var rates: [String: Double]

    /// A table needs at least this many rates to be believed. The bank publishes about 30.
    static let minimumCount = 10

    /// Why a table cannot be used.
    enum Problem: Error, Hashable, Sendable {
        case badDay
        case tooFewRates
        case missingDollar
    }

    /// Checks the table's shape: a real day, enough rates, US dollars among them, and every rate a
    /// finite positive number for a three-letter code. The bank always lists US dollars, so a table
    /// without them is not the bank's.
    func validate() throws(Problem) {
        guard Self.instant(ofDay: day) != nil else { throw .badDay }
        let valid = rates.filter { Self.isCode($0.key) && $0.value.isFinite && $0.value > 0 }
        guard valid.count >= Self.minimumCount else { throw .tooFewRates }
        guard valid["USD"] != nil else { throw .missingDollar }
    }

    /// The table with only usable rates.
    var cleaned: RateTable {
        var copy = self
        copy.rates = rates.filter { Self.isCode($0.key) && $0.value.isFinite && $0.value > 0 }
        return copy
    }

    /// The moment the rates are for: 15:00 UTC on their day, about when the bank publishes. The
    /// engine writes this moment's UTC date in its note, so the row shows the bank's day.
    var publishedAt: Date? {
        Self.instant(ofDay: day).map { $0.addingTimeInterval(15 * 3600) }
    }

    /// The table in the engine's form. Builds off the main thread, as the engine asks.
    @concurrent func engineRates() async -> CurrencyRates? {
        guard let publishedAt else { return nil }
        return try? CurrencyRates(base: base, fetchedAt: publishedAt.timeIntervalSince1970, rates: rates)
    }

    /// Midnight UTC of a `yyyy-MM-dd` day, or nil when it is not a real day.
    static func instant(ofDay text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date
    }

    /// True for three uppercase ASCII letters, the form of an ISO 4217 code.
    static func isCode(_ text: String) -> Bool {
        text.utf8.count == 3 && text.utf8.allSatisfy { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }
    }
}
