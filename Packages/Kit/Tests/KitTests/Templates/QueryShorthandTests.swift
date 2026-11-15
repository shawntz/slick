import Foundation
import Kit
import KitTemplates
import Testing

@Suite("Query shorthand", .timeLimit(.minutes(1)))
struct QueryShorthandTests {
    private let query = TemplateArgument(key: "Query", name: "Query")

    @Test func isPlainTextUnlessAsked() {
        let source = "const {query} = request"
        let template = Template(source)
        #expect(template.placeholders.isEmpty)
        #expect(template.issues.isEmpty)
        #expect(template.segments == [.text(source)])
        #expect(Template(source, shorthands: []) == template)
    }

    @Test func standsForTheQueryArgument() throws {
        let template = Template("https://example.com/search?q={query}", shorthands: .query)
        #expect(template.arguments == [query])
        #expect(template.commandArguments.map(\.name) == ["Query"])
        #expect(template.issues.isEmpty)
        // The range covers the braces as typed, so a form field colors exactly them.
        #expect(template.placeholderRanges == [29..<36])
    }

    @Test func sharesItsValueWithTheLongForm() async {
        let template = Template(#"{query} and {argument name="Query"}"#, shorthands: .query)
        #expect(template.arguments == [query])
        let rendered = await template.render(in: TemplateEnvironment(arguments: ["Query": "a b"]), style: .url)
        #expect(rendered.text == "a%20b and a%20b")
    }

    @Test func takesDefaultOptionsAndModifiers() async throws {
        let template = Template(#"{query default="kit" options="kit, core" | uppercase}"#, shorthands: .query)
        let argument = TemplateArgument(key: "Query", name: "Query", defaultValue: "kit", options: ["kit", "core"])
        #expect(template.arguments == [argument])
        #expect(try #require(template.placeholders.first).modifiers == [.uppercase])
        #expect(await template.render(in: TemplateEnvironment()).text == "KIT")
    }

    @Test func reportsANameItCannotTake() {
        let template = Template(#"{query name="other"}"#, shorthands: .query)
        #expect(template.issues.map(\.message) == [#"{query} has no attribute "name""#])
        #expect(template.issues.map(\.range) == [0..<20])
    }

    @Test func countsTowardTheThreeArguments() {
        let template = Template("{argument name=a}{argument name=b}{argument name=c}{query}", shorthands: .query)
        #expect(template.issues.map(\.message) == ["a template takes at most 3 arguments"])
    }
}
