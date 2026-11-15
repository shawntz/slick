// The calculator through CoreBridge: the reject path against 1 µs at p50, any answer against
// 100 µs at p99, and zero allocations on the reject path.
import BenchSupport
import CoreBridge
import Foundation

/// Words and app names: the queries the calculator sees most and must reject fastest.
let calculatorRejects = [
    "safari", "terminal", "Visual Studio Code", "system settings", "activity monitor", "dark mode", "new tab",
    "hello world", "time machine", "s", "te", "term", "google chrome", "calendar",
]
/// Words with digits, which reach the lexer before they are rejected.
let calculatorRejectsWithDigits = ["notes 2024", "1password", "iphone 15 pro", "7zip", "42", "v2", "2024 notes"]
let calculatorAnswers = [
    "2 + 2", "12 * 7 - 3", "sqrt(2)", "15% of 80", "15% tip on $80", "100 usd in eur", "50 euros in yen",
    "5 km in miles", "10 kg in lbs", "72 f in c", "time in tokyo", "3pm london in tokyo", "today + 3 weeks",
    "days until christmas", "1234 in words", "0xff", "255 in hex", "2h 30m + 45m", "unix 1700000000",
    "180 cm in feet and inches",
]

/// A calculator in New York on 15 November 2026 with the system's zones and made-up rates.
func benchCalculator() throws -> (Calculator, Double) {
    Calculator.prepare()
    let calculator = try Calculator()
    try calculator.setContext(CalculatorContext(localZone: "America/New_York", localOffsetSeconds: -5 * 3600))
    calculator.setTimeZones(try CalculatorTimeZones(extraZones: ["America/New_York"]))
    calculator.setRates(
        try CurrencyRates(
            base: "USD", fetchedAt: 1_794_744_000, rates: ["EUR": 0.92, "GBP": 0.80, "JPY": 155, "CAD": 1.40]))
    return (calculator, 1_794_753_000)
}

/// Returns false when a budget is blown.
func measureCalculator(sink: inout Int) throws -> Bool {
    let (calculator, now) = try benchCalculator()
    var ok = true
    // Rejects sit near the clock's resolution, so they are timed in batches of 256 calls.
    for (label, list) in [("words", calculatorRejects), ("words with digits", calculatorRejectsWithDigits)] {
        var samples = Samples(name: "calculator reject, \(label), per call", budget: nil)
        for _ in 0..<(reps * 10) {
            for q in list {
                var n = 0
                samples.time {
                    var i = 0
                    while i < 256 {
                        if calculator.evaluate(q, at: now) == nil { n += 1 }
                        i += 1
                    }
                }
                sink &+= n
            }
        }
        samples.micros = samples.micros.map { $0 / 256 }
        _ = samples.report()
        let p50 = samples.quantile(0.5)
        if p50 >= 1 {
            print("calculator reject p50 \(p50) µs is over 1 µs")
            ok = false
        }
    }
    var answers = Samples(name: "calculator answer, any, per call", budget: 100)
    var simple = Samples(name: "calculator answer, 2 + 2, per call", budget: 100)
    for _ in 0..<reps {
        for q in calculatorAnswers {
            if let a = answers.time({ calculator.evaluate(q, at: now) }) { sink &+= a.main.utf8.count }
        }
        for _ in 0..<20 {
            if let a = simple.time({ calculator.evaluate("2 + 2", at: now) }) { sink &+= a.main.utf8.count }
        }
    }
    ok = answers.report() && ok
    ok = simple.report() && ok
    for q in calculatorAnswers where calculator.evaluate(q, at: now) == nil {
        print("calculator bench: \(q) was rejected")
        ok = false
    }
    // Allocations on the reject path, String to UTF-8 included.
    let bridged = NSMutableString(string: "visual ")
    bridged.append("studio")
    let inputs = [calculatorRejects[0], bridged as String, "crème brûlée", "notes 2024"]
    for q in inputs { _ = calculator.evaluate(q, at: now) }
    bench_alloc_count_begin()
    var round = 0
    while round < 1_000 {
        for q in inputs where calculator.evaluate(q, at: now) == nil { sink &+= 1 }
        round += 1
    }
    let allocations = bench_alloc_count_end()
    print("calculator allocations per rejected query: \(String(format: "%.2f", Double(allocations) / 4_000))")
    return ok && allocations == 0
}
