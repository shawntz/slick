import Foundation
import Kit
import KitStorage

/// Where exchange rates come from. The feature decides when to ask; see ``RateKeeper``.
nonisolated protocol ExchangeRateService: Sendable {
    /// The table the last successful download saved, or nil when there is none or it cannot be
    /// used. Reads only the feature's own folder.
    @concurrent func savedTable() async -> RateTable?

    /// Downloads the current table, saves it and returns it. Throws ``ExchangeRateFailure``.
    @concurrent func download(at now: Date) async throws -> RateTable
}

/// Why a download gave no table.
nonisolated enum ExchangeRateFailure: Error, Hashable, Sendable {
    /// The request did not complete, as when the Mac is offline.
    case unreachable
    /// The server answered with a status other than 200.
    case status(Int)
    /// The body is not a usable rate table.
    case badTable
    /// The table's day is in the future, or more than a month old.
    case wrongDay
}

/// The rate service for each kind of run.
nonisolated enum ExchangeRateServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ExchangeRateService {
        ReferenceRates(http: context.http, file: context.storage.dataFile(ReferenceRates.fileName))
    }

    static func isolated(_ context: FeatureContext) -> any ExchangeRateService {
        SampleRates()
    }
}

/// The European Central Bank's daily reference rates, downloaded through Kit's HTTP service from
/// the bank's one host and saved in the feature's data folder.
///
/// The request is a plain GET of a fixed address. It carries no query and nothing the user typed,
/// and Kit's live HTTP service keeps no cookies. The bank publishes once a working day, around
/// 16:00 Central European Time.
nonisolated final class ReferenceRates: ExchangeRateService {
    /// The only address the feature ever requests.
    static let address = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")
    /// The saved table's file name in the feature's data folder.
    static let fileName = "rates.json"
    /// A larger body is not the bank's daily file, which is about 1.5 KB.
    static let maximumBodySize = 256 * 1024
    /// A table older than this is not today's, whatever the server says.
    static let oldestDay: TimeInterval = 31 * 24 * 3600

    private let http: any HTTPService
    private let store: JSONFileStore<RateTable>

    init(http: any HTTPService, file: URL) {
        self.http = http
        self.store = JSONFileStore(url: file)
    }

    func savedTable() async -> RateTable? {
        guard let table = try? await store.load() else { return nil }
        do {
            try table.validate()
        } catch {
            return nil
        }
        return table.cleaned
    }

    func download(at now: Date) async throws -> RateTable {
        guard let address = Self.address else { throw ExchangeRateFailure.unreachable }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(address, timeout: .seconds(20)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExchangeRateFailure.unreachable
        }
        guard response.status == 200 else { throw ExchangeRateFailure.status(response.status) }
        guard response.body.count <= Self.maximumBodySize else { throw ExchangeRateFailure.badTable }
        let table: RateTable
        do {
            table = try ReferenceRatesXML.parse(response.body, downloadedAt: now)
        } catch {
            throw ExchangeRateFailure.badTable
        }
        guard let day = RateTable.instant(ofDay: table.day), day <= now.addingTimeInterval(24 * 3600),
            day >= now.addingTimeInterval(-Self.oldestDay)
        else { throw ExchangeRateFailure.wrongDay }
        // A table that cannot be saved still answers this session.
        try? await store.save(table)
        return table
    }
}

/// Made-up rates for scenarios, self-tests and benchmarks. Nothing is downloaded or saved.
nonisolated final class SampleRates: ExchangeRateService {
    /// Rough, invented values in the bank's shape, so scenarios can show a conversion.
    static let rates: [String: Double] = [
        "USD": 1.08, "JPY": 165, "GBP": 0.86, "CHF": 0.94, "CAD": 1.5, "AUD": 1.65, "NZD": 1.8, "SEK": 11.5,
        "NOK": 11.7, "DKK": 7.46, "PLN": 4.3, "CZK": 25, "HUF": 390, "CNY": 7.8, "HKD": 8.4, "SGD": 1.45,
        "INR": 90, "KRW": 1450, "MXN": 19, "BRL": 5.9, "ZAR": 20,
    ]

    func savedTable() async -> RateTable? {
        nil
    }

    func download(at now: Date) async throws -> RateTable {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        return RateTable(base: "EUR", day: day, downloadedAt: now, rates: Self.rates)
    }
}
