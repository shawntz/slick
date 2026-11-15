import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// Every kind of answer through the real engine, in US English in New York, on the fake clock's
/// Saturday 14 November 2026, 09:30 UTC.
@Suite("Answers", .timeLimit(.minutes(1)))
struct AnswerTests {
    @Test(arguments: [
        ("2 + 2", "4", "Arithmetic"),
        ("30 is what % of 120", "25%", "Percentage"),
        ("10 kg in lbs", "22.0462 lb", "Units"),
        ("2h 30m + 45m", "3 h 15 min", "Duration"),
        ("100 usd in eur", "80 EUR", "Currency · Rates from 13 Nov 2026"),
        ("today + 3 weeks", "Saturday, December 5, 2026", "Date"),
        ("time in tokyo", "6:30 PM, Sat Nov 14", "Time · Tokyo, JST, UTC+9"),
        ("1234 in words", "one thousand two hundred thirty-four", "Text"),
    ])
    func everyKindOfAnswer(query: String, title: String, subtitle: String) async throws {
        let harness = await readyHarness(rates: ScriptedRates(saved: sampleTable()))
        let answer = try #require(harness.instantAnswers(for: query).first)
        #expect(answer.claimsTop)
        let row = try #require(answer.rows.first)
        #expect(row.title == title)
        #expect(row.subtitle == subtitle)
        #expect(row.id == ItemID("calculator", query))
        #expect(row.memory == .never, "an answer to one query is never remembered")
        #expect(row.completion != nil)
        #expect(harness.issues.isEmpty)
    }

    @Test func tabPutsTheEngineCopyValueInTheField() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("1234567.891 * 2"))
        #expect(row.title == "2,469,135.782")
        #expect(try await harness.pressTab("1234567.891 * 2", on: row) == "2469135.782")
    }

    @Test func aQuestionWithoutAnAnswerSaysWhy() async throws {
        let harness = await readyHarness()
        let division = try #require(harness.answerRow("1/0"))
        #expect(division.title == "Division by zero")
        #expect(division.subtitle == "A number cannot be divided by zero.")
        #expect(division.completion == nil)
        #expect(harness.feature.provider.actions(for: division).isEmpty, "Return does nothing on a problem")
        let units = try #require(harness.answerRow("5 km in kg"))
        #expect(units.subtitle == "These units measure different things, so one cannot become the other.")
    }

    @Test func lowConfidenceAnswersGoInTheirOwnSection() async throws {
        let harness = await readyHarness()
        let bare = try #require(harness.instantAnswers(for: "3m").first)
        #expect(!bare.claimsTop)
        #expect(bare.sectionTitle == "Calculator")
        let hex = try #require(harness.instantAnswers(for: "0xff").first)
        #expect(hex.rows.first?.title == "255")
        #expect(try harness.payload("0xff").forms.map(\.label) == ["Hex", "Binary"])
    }

    @Test(arguments: [
        "", " ", "safari", "Visual Studio Code", "1password", "notes 2024", "42", "-5", "hello world", "e", "km",
        "\u{0}", "👍", "2 + 2\u{0}", ":smile", "/usr", "~/Desktop", "=", "10%",
    ])
    func queriesThatAreNotMathAreRejected(query: String) async throws {
        let harness = await readyHarness()
        #expect(harness.instantAnswers(for: query).isEmpty, "\(query)")
    }

    @Test func pastedTextIsRejectedWhateverItHolds() async throws {
        let harness = await readyHarness()
        #expect(harness.instantAnswers(for: String(repeating: "1+", count: 600)).isEmpty)
        #expect(harness.instantAnswers(for: String(repeating: "word ", count: 20_000)).isEmpty)
        let bridged = NSMutableString(string: String(repeating: "é", count: 2_000))
        #expect(harness.instantAnswers(for: bridged as String).isEmpty)
    }

    @Test func nothingAnswersBeforeTheEngineIsReady() async throws {
        let fakes = FakeServices()
        fakes.override(RegionServiceKey.self, with: TestRegion())
        fakes.override(ExchangeRateServiceKey.self, with: ScriptedRates())
        let harness = FeatureHarness(CalculatorFeature.self, fakes: fakes)
        #expect(harness.instantAnswers(for: "2 + 2").isEmpty)
        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(harness.answerRow("2 + 2")?.title == "4")
    }

    @Test func surroundingSpacesAreTrimmedFromTheQuestion() async throws {
        let harness = await readyHarness()
        let payload = try harness.payload("  12 * 3  ")
        #expect(payload.question == "12 * 3")
        #expect(payload.answer == "36")
        #expect(payload.plainNumber == "36")
    }

    @Test func plainNumbersLeaveOutGroupingUnitsAndSigns() async throws {
        let harness = await readyHarness(rates: ScriptedRates(saved: sampleTable()))
        #expect(try harness.payload("1234567.891 * 1").plainNumber == "1234567.891")
        #expect(try harness.payload("30 is what % of 120").plainNumber == "25")
        #expect(try harness.payload("10 kg in lbs").plainNumber == "22.0462262184878")
        #expect(try harness.payload("1000 usd in eur").plainNumber == "800")
        #expect(try harness.payload("1.75 as fraction").plainNumber == nil, "7/4 is not one plain number")
        #expect(try harness.payload("today + 3 weeks").plainNumber == nil)
        #expect(try harness.payload("2h 30m + 45m").plainNumber == nil)
    }
}
