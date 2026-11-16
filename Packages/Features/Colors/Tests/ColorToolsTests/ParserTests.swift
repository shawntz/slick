import Testing

@testable import ColorTools

/// Reading colors as CSS writes them.
@Suite("Parser", .timeLimit(.minutes(1)))
struct ParserTests {
    private func hex(_ text: String, names: Bool = false) -> String? {
        ColorParser.parse(text, allowsNames: names).map { ColorFormatter().hex($0) }
    }

    @Test func hexWithThreeFourSixOrEightDigits() {
        #expect(hex("#639") == "#663399")
        #expect(hex("#6398") == "#66339988")
        #expect(hex("#663399") == "#663399")
        #expect(hex("#66339980") == "#66339980")
        #expect(hex("#abcDEF") == "#ABCDEF", "any case")
        #expect(hex("  #fff  ") == "#FFFFFF", "spaces at either end")
        for text in ["#", "#ff", "#fffff", "#fffffff", "#fffffffff", "#ggg", "#12 3", "fff", "#ff00ff;", "# fff"] {
            #expect(hex(text) == nil, "\(text)")
        }
    }

    @Test func rgbInTheCommaAndTheSpaceForms() {
        let forms = [
            "rgb(102, 51, 153)", "rgb(102 51 153)", "rgba(102, 51, 153, 1)", "rgb(102 51 153 / 1)",
            "RGB(102,51,153)", "rgb( 102 , 51 , 153 )", "rgb(40% 20% 60%)", "rgb(40%, 20%, 60%)", "rgba(102 51 153)",
            "rgb(1.02e2 51 153)",
        ]
        for form in forms {
            #expect(hex(form) == "#663399", "\(form)")
        }
        #expect(hex("rgba(102, 51, 153, 0.5)") == "#66339980")
        #expect(hex("rgb(102 51 153 / 50%)") == "#66339980")
        #expect(hex("rgb(300 -20 none)") == "#FF0000", "clamped as CSS clamps, none is 0")
    }

    @Test func hslAndHslaWithEveryAngleUnit() {
        for form in [
            "hsl(270, 50%, 40%)", "hsl(270 50% 40%)", "hsla(270, 50%, 40%, 1)", "hsl(270deg 50% 40%)",
            "hsl(0.75turn 50% 40%)", "hsl(300grad 50% 40%)", "hsl(4.71238898rad 50% 40%)", "hsl(-90 50% 40%)",
            "hsl(630 50% 40%)", "hsl(270 50 40)",
        ] {
            #expect(hex(form) == "#663399", "\(form)")
        }
        #expect(hex("hsla(270 50% 40% / 0.5)") == "#66339980")
    }

    @Test func hwbInBothForms() {
        #expect(hex("hwb(270 20% 40%)") == "#663399")
        #expect(hex("hwb(270, 20%, 40%)") == "#663399")
        #expect(hex("hwb(0 100% 100%)") == "#808080", "white and black past 100% make gray")
        #expect(hex("hwb(270 20% 40% / 25%)") == "#66339940")
    }

    @Test func oklchInBothForms() throws {
        for form in [
            "oklch(44.03% 0.1603 303.37)", "oklch(0.4403 0.1603 303.37)", "oklch(0.4403, 0.1603, 303.37)",
            "OKLCH(44.03% 40.075% 303.37deg)",
        ] {
            #expect(hex(form) == "#663399", "\(form)")
        }
        #expect(hex("oklch(62.8% 0.2577 29.23)") == "#FF0000")
        #expect(hex("oklch(1 0 0)") == "#FFFFFF")
        let vivid = try #require(ColorParser.parse("oklch(70% 0.4 30)", allowsNames: false))
        #expect(vivid.isOutsideSRGB, "a chroma no sRGB color has")
        let huge = try #require(ColorParser.parse("oklch(50% 9e9 30)", allowsNames: false))
        #expect(huge.isFinite, "chroma is capped")
    }

    @Test func namesOnlyWhereAllowed() {
        #expect(hex("rebeccapurple", names: true) == "#663399")
        #expect(hex("RebeccaPurple", names: true) == "#663399")
        #expect(hex("rebeccapurple") == nil)
        #expect(hex("grey", names: true) == "#808080" && hex("gray", names: true) == "#808080")
        #expect(hex("transparent", names: true) == "#00000000")
        #expect(hex("lightgoldenrodyellow", names: true) == "#FAFAD2")
        #expect(hex("notacolor", names: true) == nil)
        #expect(hex("red blue", names: true) == nil)
        #expect(CSSNames.table.count == 148)
        #expect(CSSNames.table.map(\.name) == CSSNames.table.map(\.name).sorted(), "the search needs it sorted")
    }

    @Test func refusesWhatIsNotOneColor() {
        let refused = [
            "", "rgb()", "rgb(1 2)", "rgb(1 2 3 4)", "rgb(1, 2 3)", "rgb(1 2, 3)", "rgb(1 2 3 / )", "rgb(1 2 3 /0.5 1)",
            "rgb(1 2 3) red", "rgb(1 2 3", "rgb 1 2 3)", "rgb (1 2 3)", "rgb((1 2 3))", "rgb(1deg 2 3)",
            "hsl(270% 50% 40%)", "rgb(1e400 0 0)", "rgb(nan 0 0)", "rgb(inf 0 0)", "rgb(1.2.3 0 0)", "rgb(. 0 0)",
            "rgb(1px 0 0)", "rgb(1 2 3,)", "rgb(,1 2 3)", "cmyk(1 2 3)", "lab(50 20 30)", "rgb(1\u{0} 2 3)",
            "rgb(١ 2 3)", "#fff\u{202E}",
        ]
        for text in refused {
            #expect(ColorParser.parse(text, allowsNames: true) == nil, "\(text.debugDescription)")
        }
        #expect(ColorParser.parse("rgb(" + String(repeating: " ", count: 500) + "1 2 3)", allowsNames: false) == nil)
    }
}
