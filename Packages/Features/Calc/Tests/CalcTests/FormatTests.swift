import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// Settings and the region change how answers read.
@Suite("Formats, region and time zone", .timeLimit(.minutes(1)))
struct FormatTests {
    @Test func decimalPlacesRoundNumbersPercentagesAndUnitsButNotMoney() async throws {
        let harness = await readyHarness(rates: ScriptedRates(saved: sampleTable()))
        #expect(harness.answerRow("1/3")?.title == "0.333333333333")
        harness.context.settings[CalcSettings.decimalPlaces] = .two
        try await harness.settle()
        #expect(harness.answerRow("1/3")?.title == "0.33")
        #expect(try harness.payload("1/3").plainNumber == "0.33")
        #expect(harness.answerRow("10 kg in lbs")?.title == "22.05 lb")
        #expect(harness.answerRow("200 is what % of 300")?.title == "66.67%")
        #expect(harness.answerRow("2/3 * 3000000")?.title == "2,000,000")
        #expect(harness.answerRow("99.999 + 0")?.title == "100")
        #expect(harness.answerRow("13 usd in eur")?.title == "10.40 EUR", "money keeps its cents")
        #expect(harness.answerRow("2^100")?.title == "1.26765060023 × 10³⁰", "scientific notation stays")
        #expect(harness.answerRow("today + 1 day")?.title == "Sunday, November 15, 2026")
        harness.context.settings[CalcSettings.decimalPlaces] = .zero
        #expect(harness.answerRow("2.5 + 0")?.title == "3", "half rounds away from zero")
        #expect(harness.answerRow("-2.5 + 0")?.title == "-3")
        #expect(harness.answerRow("-0.4 + 0")?.title == "0")
    }

    @Test func groupingDecimalMarkDatesClockAnglesAndDollarsFollowSettings() async throws {
        let harness = await readyHarness(rates: ScriptedRates(saved: sampleTable()))
        let settings = harness.context.settings
        settings[CalcSettings.grouping] = .none
        try await harness.settle()
        #expect(harness.answerRow("1234567 * 2")?.title == "2469134")
        settings[CalcSettings.decimalMark] = .comma
        settings[CalcSettings.grouping] = .period
        try await harness.settle()
        #expect(harness.answerRow("0,1 + 0,2")?.title == "0,3")
        #expect(harness.answerRow("1234567 * 2")?.title == "2.469.134")
        settings[CalcSettings.grouping] = .comma
        try await harness.settle()
        #expect(harness.answerRow("1234567 * 2")?.title == "2469134", "a comma cannot group with a decimal comma")
        settings[CalcSettings.dateOrder] = .dayMonthYear
        settings[CalcSettings.clock] = .twentyFourHour
        try await harness.settle()
        #expect(harness.answerRow("today + 3 weeks")?.title == "Saturday, 5 December 2026")
        #expect(harness.answerRow("time in tokyo")?.title == "18:30, Sat 14 Nov")
        settings[CalcSettings.angles] = .degrees
        try await harness.settle()
        #expect(harness.answerRow("sin(30)")?.title == "0,5")
        settings[CalcSettings.dollar] = .cad
        try await harness.settle()
        #expect(harness.answerRow("$150 in eur")?.title == "100 EUR")
    }

    @Test func theRegionDecidesTheDefaults() async throws {
        let german = await readyHarness(region: TestRegion(locale: "de_DE", timeZone: "Europe/Berlin"))
        #expect(german.answerRow("0,1 + 0,2")?.title == "0,3")
        #expect(german.answerRow("1234567 * 2")?.title == "2.469.134")
        #expect(german.answerRow("time in tokyo")?.title == "18:30, Sat 14 Nov")
        #expect(german.answerRow("in 90 minutes")?.subtitle == "Time · Local time, CET, UTC+1")

        let canadian = await readyHarness(
            region: TestRegion(locale: "en_CA", timeZone: "America/Toronto"),
            rates: ScriptedRates(saved: sampleTable()))
        #expect(canadian.answerRow("$150 in eur")?.title == "100 EUR", "a Canadian's dollar is the Canadian dollar")

        let french = await readyHarness(region: TestRegion(locale: "fr_FR", timeZone: "Europe/Paris"))
        #expect(french.answerRow("1234567 * 2")?.title == "2\u{202F}469\u{202F}134")
    }

    @Test func aRegionChangeReachesTheNextKeystroke() async throws {
        let region = TestRegion()
        let harness = await readyHarness(region: region)
        #expect(region.subscriberCount == 1)
        let before = harness.feature.engine.finishedRefreshes
        #expect(harness.answerRow("in 90 minutes")?.subtitle == "Time · Local time, EST, UTC-5")
        region.change(locale: "de_DE", timeZone: "Asia/Tokyo")
        await harness.feature.engine.waitForRefreshes(before + 1)
        #expect(harness.answerRow("in 90 minutes")?.subtitle == "Time · Local time, JST, UTC+9")
        #expect(harness.answerRow("in 90 minutes")?.title == "20:00, Sat 14 Nov")
        #expect(harness.answerRow("0,5 * 3")?.title == "1,5")
    }

    @Test func turningTheFeatureOffAndOnKeepsOneListener() async throws {
        let region = TestRegion()
        let harness = await readyHarness(region: region)
        await harness.deactivate()
        await harness.activate()
        await harness.activate()
        await harness.feature.waitUntilReady()
        await Task.yield()
        let before = harness.feature.engine.finishedRefreshes
        region.change(timeZone: "Europe/London")
        await harness.feature.engine.waitForRefreshes(before + 1)
        #expect(harness.answerRow("in 90 minutes")?.subtitle == "Time · Local time, GMT, UTC+0")
        #expect(harness.feature.engine.finishedRefreshes == before + 1, "one listener refreshed once")
    }

    @Test func theContextBuilderReadsTheRegion() {
        let us = RegionSnapshot(
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Chicago") ?? .gmt)
        let context = CalcContextBuilder.context(region: us, choices: FormatChoices(), now: fakeStart)
        #expect(context.localZone == "America/Chicago")
        #expect(context.localOffsetSeconds == -6 * 3600)
        #expect(context.decimalSeparator == "." && context.groupingSeparator == ",")
        #expect(context.dateOrder == .monthDayYear && context.hourCycle == .twelveHour)
        #expect(context.dollarCurrency == "USD")
        let japan = RegionSnapshot(
            locale: Locale(identifier: "ja_JP"), timeZone: TimeZone(identifier: "Asia/Tokyo") ?? .gmt)
        let japanese = CalcContextBuilder.context(region: japan, choices: FormatChoices(), now: fakeStart)
        #expect(japanese.dateOrder == .yearMonthDay && japanese.hourCycle == .twentyFourHour)
        #expect(japanese.dollarCurrency == "USD", "yen are not dollars")
        let british = RegionSnapshot(locale: Locale(identifier: "en_GB"), timeZone: .gmt)
        #expect(
            CalcContextBuilder.context(region: british, choices: FormatChoices(), now: fakeStart).dateOrder
                == .dayMonthYear)
    }
}

/// The text rounding behind the decimal places setting.
@Suite("Rounding", .timeLimit(.minutes(1)))
struct RoundingTests {
    @Test(arguments: [
        ("3.14159", 2, "3.14"),
        ("2.675", 2, "2.68"),
        ("9.995 mi", 2, "10 mi"),
        ("999.96", 1, "1,000"),
        ("1,234.5678", 0, "1,235"),
        ("-0.004", 2, "0"),
        ("−1.25 °C", 1, "-1.3 °C"),
        ("12.5%", 0, "13%"),
        ("7/4", 0, "7/4"),
        ("0xFF", 0, "0xFF"),
        ("1.5", 3, "1.5"),
        ("1.2 × 10²²", 0, "1.2 × 10²²"),
        ("1.26765060022823e30", 2, "1.26765060022823e30"),
        ("Friday", 2, "Friday"),
        ("", 2, ""),
    ])
    func roundsTheLeadingNumber(text: String, places: Int, expected: String) {
        #expect(NumberRounding.round(text, places: places, decimal: ".", grouping: ",") == expected)
    }

    @Test func roundsWithOtherSeparators() {
        #expect(NumberRounding.round("1.234,5678", places: 2, decimal: ",", grouping: ".") == "1.234,57")
        #expect(NumberRounding.round("999,99", places: 1, decimal: ",", grouping: "\u{202F}") == "1\u{202F}000")
        #expect(NumberRounding.round("999.99", places: 1, decimal: ".", grouping: nil) == "1000")
    }
}
