import KitTemplates
import Testing

@Suite("Template parsing")
struct TemplateParsingTests {
    @Test(arguments: [
        "function f() { return 1 }",
        "{\"key\": \"value\"}",
        "{foo} and {Date}",
        "{date\n}",
        "a { b",
        "{argument name=\"unclosed}",
        "}{",
        "",
    ])
    func leavesNonPlaceholdersAsText(source: String) {
        let template = Template(source)
        #expect(template.placeholders.isEmpty)
        #expect(template.issues.isEmpty)
        #expect(template.segments == (source.isEmpty ? [] : [.text(source)]))
    }

    @Test func parsesEveryPlaceholder() {
        let template = Template(
            "{clipboard}{clipboard offset=2}{selection}{date}{time}{datetime}{day}{uuid}{cursor}{argument}{snippet name=\"sig\"}"
        )
        #expect(
            template.placeholders.map(\.kind) == [
                .clipboard(offset: 0), .clipboard(offset: 2), .selection, .date(.date, DateOptions()),
                .date(.time, DateOptions()),
                .date(.datetime, DateOptions()), .date(.day, DateOptions()), .uuid, .cursor,
                .argument(TemplateArgument(key: "#1")), .snippet(name: "sig"),
            ])
        #expect(template.issues.isEmpty)
    }

    @Test func parsesAttributesAndModifiers() throws {
        let template = Template(#"{date offset="+2y +5M -3d" format="yyyy-MM-dd" | uppercase | trim}"#)
        let placeholder = try #require(template.placeholders.first)
        #expect(
            placeholder.kind
                == .date(
                    .date,
                    DateOptions(
                        offsets: [DateOffset(2, .year), DateOffset(5, .month), DateOffset(-3, .day)],
                        format: "yyyy-MM-dd")))
        #expect(placeholder.modifiers == [.uppercase, .trim])
    }

    @Test func quotedValuesMayHoldBracesPipesAndEscapedQuotes() throws {
        let template = Template(#"{argument name="say \"hi\" | {now}" default="a}b"}"#)
        let argument = TemplateArgument(key: #"say "hi" | {now}"#, name: #"say "hi" | {now}"#, defaultValue: "a}b")
        #expect(template.placeholders.map(\.kind) == [.argument(argument)])
    }

    @Test func collectsDistinctArgumentsInOrder() {
        let template = Template(
            #"{argument name="query"} {argument name="lang" default="en" options="en, fr ,de"} {argument name="query"} {argument} {argument}"#
        )
        #expect(
            template.arguments == [
                TemplateArgument(key: "query", name: "query"),
                TemplateArgument(key: "lang", name: "lang", defaultValue: "en", options: ["en", "fr", "de"]),
                TemplateArgument(key: "#1"),
            ])
        // The fifth placeholder would be a fourth argument.
        #expect(template.issues.map(\.message) == ["a template takes at most 3 arguments"])
    }

    @Test(arguments: [
        ("{clipboard | shout}", "unknown modifier \"shout\""),
        ("{clipboard offset=-1}", "offset must be a whole number from 0"),
        ("{date offset=\"+2 d\"}", "offset must look like \"+2d -3h\", with units s m h d w M y"),
        ("{date offset=\"2d\"}", "offset must look like \"+2d -3h\", with units s m h d w M y"),
        ("{date format=\"yyyy\" locale=\"fr\"}", "format and locale cannot be used together"),
        ("{uuid size=4}", "{uuid} has no attribute \"size\""),
        ("{snippet}", "{snippet} needs a name"),
        ("{argument name=a name=b}", "name is given twice"),
        ("{clipboard | trim offset=1}", "attributes must come before modifiers"),
    ])
    func reportsMistakesAndKeepsTheTextAsTyped(source: String, message: String) {
        let template = Template(source)
        #expect(template.issues.map(\.message) == [message])
        #expect(template.placeholders.isEmpty)
        #expect(template.segments == [.text(source)])
    }

    @Test func rangesAreUTF16OffsetsIntoTheSource() {
        let template = Template("😀 {date} and {uuid | lowercase}")
        #expect(template.placeholderRanges == [3..<9, 14..<32])
    }

    @Test func knowsWhenItReadsUserContent() {
        #expect(Template("{selection}").readsUserContent)
        #expect(Template("{snippet name=x}").readsUserContent)
        #expect(!Template("{date} {uuid} {argument}").readsUserContent)
    }
}
