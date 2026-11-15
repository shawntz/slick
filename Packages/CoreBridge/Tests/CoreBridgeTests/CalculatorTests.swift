import Foundation
import SlickCoreC
import Testing

@testable import CoreBridge

/// Sunday 15 November 2026, 14:30 UTC, the fixed moment of the slick-calc suite.
let calcNow = 1_794_753_000.0

/// A calculator in New York with the system's zones and made-up rates.
func fixedCalculator(rates: Bool = true, zones: Bool = true) throws -> Calculator {
    let calculator = try Calculator()
    try calculator.setContext(CalculatorContext(localZone: "America/New_York", localOffsetSeconds: -5 * 3600))
    if zones { calculator.setTimeZones(try CalculatorTimeZones(extraZones: ["America/New_York"])) }
    if rates {
        let table = try CurrencyRates(
            base: "USD", fetchedAt: 1_794_744_000, rates: ["EUR": 0.92, "GBP": 0.80, "JPY": 155, "CAD": 1.40])
        calculator.setRates(table)
    }
    return calculator
}

@Suite("Calculator")
struct CalculatorTests {
    @Test func theSwiftEnumsMatchTheHeader() {
        #expect(CalculatorKind.number.rawValue == UInt8(SLICK_CALC_KIND_NUMBER))
        #expect(CalculatorKind.error.rawValue == UInt8(SLICK_CALC_KIND_ERROR))
        #expect(CalculatorKind(rawValue: UInt8(SLICK_CALC_KIND_NONE)) == nil)
        #expect(CalculatorProblem.divisionByZero.rawValue == UInt8(SLICK_CALC_PROBLEM_DIVISION_BY_ZERO))
        #expect(CalculatorProblem.unsupported.rawValue == UInt8(SLICK_CALC_PROBLEM_UNSUPPORTED))
        #expect(CalculatorContext.DateOrder.yearMonthDay.rawValue == UInt8(SLICK_CALC_DATE_YEAR_MONTH_DAY))
        #expect(CalculatorContext.HourCycle.twentyFourHour.rawValue == UInt8(SLICK_CALC_HOURS_24))
        #expect(CalculatorContext.AngleUnit.degrees.rawValue == UInt8(SLICK_CALC_ANGLE_DEGREES))
        #expect(Calculator.claimsTopConfidence == 80)
    }

    @Test(arguments: [
        ("2 + 2", CalculatorKind.number, "4"),
        ("30 is what % of 120", .percent, "25%"),
        ("10 kg in lbs", .quantity, "22.0462 lb"),
        ("2h 30m + 45m", .duration, "3 h 15 min"),
        ("100 usd in eur", .currency, "92 EUR"),
        ("today + 3 weeks", .date, "Sunday, 6 December 2026"),
        ("time in tokyo", .time, "11:30 PM, Sun 15 Nov"),
        ("1234 in words", .text, "one thousand two hundred thirty-four"),
        ("1/0", .error, "Division by zero"),
    ])
    func everyKindOfAnswer(query: String, kind: CalculatorKind, main: String) throws {
        Calculator.prepare()
        let calculator = try fixedCalculator()
        let answer = try #require(calculator.evaluate(query, at: calcNow))
        #expect(answer.kind == kind)
        #expect(answer.main == main)
        #expect((1...100).contains(answer.confidence))
        #expect((answer.problem != nil) == (kind == .error))
    }

    @Test func copyNoteAlternatesAndTheTop() throws {
        let calculator = try fixedCalculator()
        let money = try #require(calculator.evaluate("100 usd in eur", at: calcNow))
        #expect(money.copy == "92")
        #expect(money.note.contains("Rates"))
        let hex = try #require(calculator.evaluate("0xff", at: calcNow))
        #expect(hex.main == "255")
        #expect(!hex.alternates.isEmpty && hex.alternates.allSatisfy { !$0.label.isEmpty && !$0.text.isEmpty })
        #expect(try #require(calculator.evaluate("15% tip on $80", at: calcNow)).claimsTop)
        #expect(try #require(calculator.evaluate("3m", at: calcNow)).claimsTop == false)
    }

    @Test func errorsNameTheirProblem() throws {
        let bare = try fixedCalculator(rates: false, zones: false)
        let noRates = try #require(bare.evaluate("100 usd in eur", at: calcNow))
        #expect(noRates.kind == .error && noRates.problem == .noRates)
        #expect(noRates.main == "Exchange rates are not loaded")
        #expect(bare.evaluate("time in tokyo", at: calcNow)?.problem == .noTimeZones)
        let calculator = try fixedCalculator()
        #expect(calculator.evaluate("5 km in kg", at: calcNow)?.problem == .incompatibleUnits)
        #expect(calculator.evaluate("100 chf in eur", at: calcNow)?.problem == .noRate)
        calculator.setRates(nil)
        #expect(calculator.evaluate("100 usd in eur", at: calcNow)?.problem == .noRates)
    }

    @Test func queriesThatAreNotMathComeBackNil() throws {
        let calculator = try fixedCalculator()
        for query in ["safari", "Visual Studio Code", "42", "", "   ", "1password", "notes 2024", "hello world"] {
            #expect(calculator.evaluate(query, at: calcNow) == nil, "\(query)")
        }
        #expect(calculator.evaluate(String(repeating: "1+", count: 400), at: calcNow) == nil)
        #expect(calculator.evaluate("2 + 2", at: .nan)?.main == "4", "a bad clock still answers arithmetic")
        #expect(calculator.evaluate("now", at: .infinity) != nil)
    }

    @Test func theContextSetsFormats() throws {
        let calculator = try fixedCalculator()
        try calculator.setContext(CalculatorContext(decimalSeparator: ",", groupingSeparator: "."))
        #expect(calculator.evaluate("0,1 + 0,2", at: calcNow)?.main == "0,3")
        try calculator.setContext(
            CalculatorContext(localZone: "America/New_York", hourCycle: .twentyFourHour, angleUnit: .degrees))
        #expect(calculator.evaluate("time in tokyo", at: calcNow)?.main == "23:30, Sun 15 Nov")
        #expect(calculator.evaluate("sin(30)", at: calcNow)?.main == "0.5")
        try calculator.setContext(CalculatorContext(dollarCurrency: "cad"))
        #expect(calculator.evaluate("$140 in usd", at: calcNow)?.main == "100 USD")
        #expect(throws: CoreError.invalidArgument) {
            try calculator.setContext(CalculatorContext(dollarCurrency: "dollars"))
        }
        #expect(throws: CoreError.invalidArgument) {
            try calculator.setContext(CalculatorContext(decimalSeparator: ",", groupingSeparator: ","))
        }
        #expect(calculator.evaluate("$140 in usd", at: calcNow)?.main == "100 USD", "a refused context changes nothing")
    }

    @Test func ratesAndZonesAreValidatedAndShared() throws {
        #expect(throws: CoreError.invalidArgument) { try CurrencyRates(base: "U", fetchedAt: 0, rates: [:]) }
        let rates = try CurrencyRates(
            base: "usd", fetchedAt: 1_794_744_000, rates: ["EUR": 0.92, "X1": 2, "GBP": .nan, "JPY": -1, "CHF": 0.88])
        #expect(rates.count == 3)
        #expect(rates.refused == ["GBP", "JPY", "X1"])
        let zones = try CalculatorTimeZones()
        #expect(zones.count > 200)
        let empty = try CalculatorTimeZones(directory: "/nonexistent-zoneinfo", extraZones: [])
        #expect(empty.count == 0)
        let a = try Calculator()
        let b = try Calculator()
        for c in [a, b] {
            c.setRates(rates)
            c.setTimeZones(zones)
        }
        #expect(a.evaluate("100 chf in eur", at: calcNow)?.kind == .currency)
        #expect(b.evaluate("time in london", at: calcNow)?.kind == .time)
        b.setTimeZones(empty)
        #expect(b.evaluate("time in london", at: calcNow)?.problem == .unknownZone)
    }

    @Test func bridgedAndNonASCIIQueries() throws {
        let calculator = try fixedCalculator()
        let bridged = NSMutableString(string: "12 ")
        bridged.append("* 7")
        #expect(calculator.evaluate(bridged as String, at: calcNow)?.main == "84")
        #expect(calculator.evaluate("€50 in $", at: calcNow)?.main == "54.35 USD")
        #expect(calculator.evaluate("time in são paulo", at: calcNow)?.main == "11:30 AM, Sun 15 Nov")
    }

    @Test func oneCalculatorServesManyTasks() async throws {
        let calculator = try fixedCalculator()
        let rates = try CurrencyRates(base: "USD", fetchedAt: calcNow, rates: ["EUR": 0.5])
        await withTaskGroup(of: Int.self) { group in
            for task in 0..<8 {
                group.addTask {
                    var answered = 0
                    for i in 0..<200 {
                        if task == 0, i % 50 == 0 { calculator.setRates(rates) }
                        if calculator.evaluate("\(i) * \(task) + 1", at: calcNow) != nil { answered += 1 }
                        if calculator.evaluate("safari", at: calcNow) == nil { answered += 1 }
                    }
                    return answered
                }
            }
            var total = 0
            for await n in group { total += n }
            #expect(total == 8 * 400)
        }
    }

    @Test func hostileArgumentsAtTheCBoundary() throws {
        var result = SlickCalcResult()
        #expect(slick_calc_evaluate(nil, nil, 0, 0, &result) == SLICK_STATUS_NULL_POINTER.rawValue)
        var handle: OpaquePointer?
        #expect(slick_calc_new(&handle) == 0)
        defer { slick_calc_free(handle) }
        let invalid: [UInt8] = [0x31, 0x2B, 0xFF]
        let status = invalid.withUnsafeBufferPointer {
            slick_calc_evaluate(handle, $0.baseAddress, $0.count, 0, &result)
        }
        #expect(status == SLICK_STATUS_INVALID_UTF8.rawValue)
        #expect(slick_calc_evaluate(handle, nil, 5, 0, &result) == SLICK_STATUS_NULL_POINTER.rawValue)
        #expect(slick_calc_text(handle, 99, 0, nil, 0) == SLICK_STATUS_INVALID_ARGUMENT.rawValue)
        #expect(slick_calc_set_context(handle, nil, nil, 0, nil, 0) == SLICK_STATUS_NULL_POINTER.rawValue)
        #expect(slick_calc_rates_free(nil) == 0 && slick_calc_zones_free(nil) == 0)
    }
}
