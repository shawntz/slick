/// A level of WCAG 2 contrast for one size of text.
nonisolated enum WCAGLevel: String, Hashable, Sendable, Codable, Comparable {
    case fail
    case aa
    case aaa

    static func < (lhs: WCAGLevel, rhs: WCAGLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .fail: 0
        case .aa: 1
        case .aaa: 2
        }
    }
}

/// The contrast between two colors and what WCAG 2 says about it.
nonisolated struct Contrast: Hashable, Sendable {
    /// From 1, the same luminance, to 21, black and white.
    let ratio: Double

    /// Normal text needs 4.5 for AA and 7 for AAA.
    var normalText: WCAGLevel {
        ratio >= 7 ? .aaa : ratio >= 4.5 ? .aa : .fail
    }

    /// Large text, 18 points or 14 points bold, needs 3 for AA and 4.5 for AAA.
    var largeText: WCAGLevel {
        ratio >= 4.5 ? .aaa : ratio >= 3 ? .aa : .fail
    }

    /// A contrast with this ratio.
    init(ratio: Double) {
        self.ratio = ratio
    }

    /// The contrast of text in `foreground` over `background`.
    ///
    /// A foreground with alpha is drawn over the background first. A background with alpha is drawn
    /// over white first, as a page is. Both are clipped to sRGB, as the formats are.
    init(foreground: ColorValue, background: ColorValue) {
        let back = background.clipped.composited(over: .white)
        let front = foreground.clipped.composited(over: back)
        let lighter = max(Self.luminance(front), Self.luminance(back))
        let darker = min(Self.luminance(front), Self.luminance(back))
        ratio = (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG 2's relative luminance of an opaque sRGB color, from 0 for black to 1 for white.
    static func luminance(_ color: ColorValue) -> Double {
        0.2126 * ColorSpaces.linear(color.red) + 0.7152 * ColorSpaces.linear(color.green) + 0.0722
            * ColorSpaces.linear(color.blue)
    }

    /// The ratio as people write it, such as "4.54:1", cut rather than rounded to two decimals, so a
    /// ratio of 4.499 never reads as 4.5 while it fails AA.
    var text: String {
        // The small margin keeps 21 from reading as 20.99 after the float's last bit.
        let hundredths = (ratio * 100 + 1e-9).rounded(.down)
        return Decimals.string(hundredths / 100, places: 2) + ":1"
    }
}
