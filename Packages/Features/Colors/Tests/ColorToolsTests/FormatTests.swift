import Testing

@testable import ColorTools

/// Every format the feature writes.
@Suite("Formats", .timeLimit(.minutes(1)))
struct FormatTests {
    @Test func rebeccaPurpleInEveryFormat() throws {
        let purple = try color("#663399")
        let formatter = ColorFormatter()
        let expected: [ColorFormat: String] = [
            .hex: "#663399",
            .rgb: "rgb(102 51 153)",
            .hsl: "hsl(270 50% 40%)",
            .hsb: "hsb(270 66.7% 60%)",
            .hwb: "hwb(270 20% 40%)",
            .oklch: "oklch(44.03% 0.1603 303.37)",
            .swiftUI: "Color(red: 0.4, green: 0.2, blue: 0.6)",
            .appKit: "NSColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 1)",
            .cssVariable: "--color-663399: #663399;",
        ]
        for format in ColorFormat.allCases {
            #expect(formatter.string(purple, as: format) == expected[format], "\(format)")
        }
        #expect(ColorFormat.allCases.count == expected.count)
    }

    @Test func alphaInEveryFormat() throws {
        let half = try color("#66339980")
        let formatter = ColorFormatter(hexCase: .lowercase)
        #expect(formatter.string(half, as: .hex) == "#66339980")
        #expect(formatter.string(half, as: .rgb) == "rgb(102 51 153 / 0.502)")
        #expect(formatter.string(half, as: .hsl) == "hsl(270 50% 40% / 0.502)")
        #expect(formatter.string(half, as: .oklch) == "oklch(44.03% 0.1603 303.37 / 0.502)")
        #expect(formatter.string(half, as: .swiftUI) == "Color(red: 0.4, green: 0.2, blue: 0.6, opacity: 0.502)")
        #expect(formatter.string(half, as: .appKit) == "NSColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 0.502)")
        #expect(formatter.string(half, as: .cssVariable) == "--color-66339980: #66339980;")
    }

    @Test func hexCaseFollowsTheSetting() throws {
        let mint = try color("#66cc99")
        #expect(ColorFormatter(hexCase: .uppercase).hex(mint) == "#66CC99")
        #expect(ColorFormatter(hexCase: .lowercase).hex(mint) == "#66cc99")
    }

    @Test func cssVariableNamesAreSafeInAnyStyleSheet() throws {
        let purple = try color("#663399")
        let formatter = ColorFormatter()
        #expect(formatter.string(purple, as: .cssVariable, name: "Brand Purple") == "--brand-purple: #663399;")
        #expect(ColorFormatter.variableName(for: purple, name: "  Héllo, World!! ") == "h-llo-world")
        #expect(ColorFormatter.variableName(for: purple, name: "2024 Accent") == "color-2024-accent")
        #expect(ColorFormatter.variableName(for: purple, name: "日本") == "color-663399", "nothing ASCII is kept")
        #expect(ColorFormatter.variableName(for: purple, name: "a\u{202E}b; } body { x") == "a-b-body-x")
        let long = ColorFormatter.variableName(for: purple, name: String(repeating: "word ", count: 40))
        #expect(long.utf8.count <= 41 && !long.hasSuffix("-"))
    }

    @Test func colorsOutsideSRGBShowTheNearestSRGBColor() {
        let p3Red = ColorSpaces.fromDisplayP3(red: 1, green: 0, blue: 0)
        let formatter = ColorFormatter()
        #expect(formatter.string(p3Red, as: .rgb) == "rgb(255 0 0)")
        #expect(formatter.string(p3Red, as: .swiftUI) == "Color(red: 1, green: 0, blue: 0)")
        #expect(formatter.string(p3Red, as: .oklch) == "oklch(62.8% 0.2577 29.23)")
    }

    @Test func aHueThatRoundsTo360ReadsAsZero() {
        let almostRed = ColorValue(red: 1, green: 0, blue: 0.0001)
        #expect(ColorFormatter().string(almostRed, as: .hsl) == "hsl(0 100% 50%)")
    }
}
