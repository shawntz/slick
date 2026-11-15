import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// The bank's rate service against a fake HTTP service and a temporary folder. Nothing reaches the
/// network.
@Suite("Reference rate service", .timeLimit(.minutes(1)))
struct RateServiceTests {
    let fakes = FakeServices()
    var address: URL { ReferenceRates.address ?? URL(fileURLWithPath: "/") }
    var file: URL { fakes.storage.dataDirectory(for: "calculator").appending(path: ReferenceRates.fileName) }
    var service: ReferenceRates { ReferenceRates(http: fakes.http, file: file) }

    private func stub(_ body: String, status: Int = 200) {
        fakes.http.stub(address, response: HTTPResponse(status: status, body: Data(body.utf8)))
    }

    @Test func downloadsReadsAndSavesTheBanksTable() async throws {
        stub(referenceXML())
        let table = try await service.download(at: fakeStart)
        #expect(table.base == "EUR" && table.day == "2026-11-13")
        #expect(table.rates == sampleRates)
        #expect(table.downloadedAt == fakeStart)
        let request = try #require(fakes.http.requests.first)
        #expect(fakes.http.requests.count == 1)
        #expect(request.url.host() == "www.ecb.europa.eu" && request.url.scheme == "https")
        #expect(request.method == "GET" && request.body == nil && request.headers.isEmpty)
        #expect(request.url.query() == nil, "the request carries nothing")
        #expect(await service.savedTable() == table)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func onlyTheFirstDayIsReadAndBadRatesAreLeftOut() async throws {
        var rates = sampleRates.sorted { $0.key < $1.key }.map { ($0.key, String($0.value)) }
        rates += [("XX1", "2"), ("ABC", "-1"), ("DEF", "abc"), ("GHI", "nan"), ("JKL", "0")]
        let first = referenceXML(day: "2026-11-13", rates: rates)
        let twoDays = first.replacingOccurrences(
            of: "\t</Cube>\n</gesmes:Envelope>",
            with: "\t\t<Cube time='2026-11-12'><Cube currency='USD' rate='9'/></Cube>\n\t</Cube>\n</gesmes:Envelope>")
        #expect(twoDays != first)
        stub(twoDays)
        let table = try await service.download(at: fakeStart)
        #expect(table.day == "2026-11-13")
        #expect(table.rates == sampleRates)
    }

    @Test(arguments: [
        ("<html><body>Service unavailable</body></html>", "an error page"),
        (String(referenceXML().prefix(400)), "a cut-off file"),
        (referenceXML().replacingOccurrences(of: " time='2026-11-13'", with: ""), "no day"),
        (referenceXML(day: "2026-02-30"), "a day that does not exist"),
        (referenceXML(rates: [("USD", "1.08"), ("JPY", "160")]), "too few rates"),
        (referenceXML(rates: sampleRates.filter { $0.key != "USD" }.map { ($0.key, String($0.value)) }), "no dollar"),
        (referenceXML(rates: sampleRates.map { ($0.key, "-\($0.value)") }), "negative rates"),
        ("", "an empty body"),
    ])
    func aBadTableIsRefusedAndNothingIsSaved(body: String, why: String) async throws {
        stub(body)
        await #expect(throws: ExchangeRateFailure.badTable, "\(why)") {
            try await service.download(at: fakeStart)
        }
        #expect(await service.savedTable() == nil)
    }

    @Test func aTableForTheWrongDayIsRefused() async throws {
        stub(referenceXML(day: "2026-09-01"))
        await #expect(throws: ExchangeRateFailure.wrongDay) { try await service.download(at: fakeStart) }
        stub(referenceXML(day: "2026-11-20"))
        await #expect(throws: ExchangeRateFailure.wrongDay) { try await service.download(at: fakeStart) }
    }

    @Test func noNetworkAServerErrorAndAHugeBodyGiveNoTable() async throws {
        fakes.http.stub(address) { _ in .failure(URLError(.notConnectedToInternet)) }
        await #expect(throws: ExchangeRateFailure.unreachable) { try await service.download(at: fakeStart) }
        stub("Server error", status: 500)
        await #expect(throws: ExchangeRateFailure.status(500)) { try await service.download(at: fakeStart) }
        stub(referenceXML() + String(repeating: " ", count: ReferenceRates.maximumBodySize))
        await #expect(throws: ExchangeRateFailure.badTable) { try await service.download(at: fakeStart) }
        #expect(await service.savedTable() == nil)
    }

    @Test func aSavedOldTableStillLoadsAndADamagedOneDoesNot() async throws {
        let old = sampleTable(day: "2026-09-01", downloadedAt: fakeStart.addingTimeInterval(-70 * 24 * 3600))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(old).write(to: file)
        #expect(await service.savedTable()?.day == "2026-09-01", "an old table is shown with its date")
        try Data("{ not json".utf8).write(to: file)
        #expect(await service.savedTable() == nil)
        try encoder.encode(RateTable(base: "EUR", day: "2026-11-13", downloadedAt: fakeStart, rates: ["USD": 1]))
            .write(to: file)
        #expect(await service.savedTable() == nil, "a saved table with too few rates is not used")
    }

    @Test func theIsolatedServiceDownloadsNothing() async throws {
        let sample = SampleRates()
        #expect(await sample.savedTable() == nil)
        let table = try await sample.download(at: fakeStart)
        #expect(table.day == "2026-11-14")
        try table.validate()
        #expect(fakes.http.requests.isEmpty)
    }
}
