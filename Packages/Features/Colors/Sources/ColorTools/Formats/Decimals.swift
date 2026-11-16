/// Numbers as code writes them: a point for decimals whatever the region, no grouping, and no
/// trailing zeros. Integer arithmetic, so it is fast enough for the keystroke path and never prints
/// "-0".
nonisolated enum Decimals {
    private static let powers: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]

    /// `value` rounded to at most `places` decimals, from 0 to 6: 0.5 as "0.5", 40.0 as "40".
    static func string(_ value: Double, places: Int) -> String {
        let places = min(max(places, 0), powers.count - 1)
        guard value.isFinite else { return "0" }
        let scale = powers[places]
        let bounded = min(abs(value), 1e12)
        let scaled = Int64((bounded * Double(scale)).rounded())
        let whole = scaled / scale
        var fraction = scaled % scale
        var text = (value < 0 && scaled != 0 ? "-" : "") + String(whole)
        guard fraction != 0 else { return text }
        var digits = places
        while fraction % 10 == 0 {
            fraction /= 10
            digits -= 1
        }
        let fractionText = String(fraction)
        text += "." + String(repeating: "0", count: digits - fractionText.count) + fractionText
        return text
    }
}
