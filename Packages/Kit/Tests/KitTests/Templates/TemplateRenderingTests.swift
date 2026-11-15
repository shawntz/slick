import Foundation
import Kit
import KitTemplates
import KitTesting
import Testing

@Suite("Template rendering")
struct TemplateRenderingTests {
    /// Saturday 14 November 2026, 09:30 UTC, in a fixed locale.
    private func environment(
        arguments: [String: String] = [:], clipboard: [String] = ["copied text"], selection: String? = "selected text",
        snippets: [String: String] = [:]
    ) -> TemplateEnvironment {
        TemplateEnvironment(
            now: Date(timeIntervalSince1970: 1_794_648_600), timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            locale: Locale(identifier: "en_US_POSIX"), arguments: arguments,
            clipboard: { clipboard.indices.contains($0) ? clipboard[$0] : nil }, selection: { selection },
            snippet: { snippets[$0] }, makeUUID: { UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)) }
        )
    }

    private func render(_ source: String, style: TemplateStyle = .plain, in environment: TemplateEnvironment? = nil)
        async -> String
    {
        await Template.render(source, in: environment ?? self.environment(), style: style)
    }

    @Test(arguments: [
        ("{date}", "Nov 14, 2026"),
        ("{day}", "Saturday"),
        ("{day locale=\"fr-FR\"}", "samedi"),
        ("{date format=\"yyyy-MM-dd\"}", "2026-11-14"),
        ("{time format=\"HH:mm\"}", "09:30"),
        ("{datetime format=\"yyyy-MM-dd'T'HH:mm\"}", "2026-11-14T09:30"),
        ("{date offset=\"+1d\" format=\"EEEE d\"}", "Sunday 15"),
        ("{date offset=\"+2y +5M -3d\" format=\"yyyy-MM-dd\"}", "2029-04-11"),
        ("{time offset=\"+90m\" format=\"HH:mm\"}", "11:00"),
        ("{date offset=\"-1w +12h -30s\" format=\"yyyy-MM-dd HH:mm:ss\"}", "2026-11-07 21:29:30"),
    ])
    func formatsDates(source: String, expected: String) async {
        #expect(await render(source) == expected)
    }

    @Test func readsClipboardSelectionAndUUIDOnlyFromTheEnvironment() async {
        let environment = environment(clipboard: ["newest", "older", "oldest"])
        #expect(
            await render("{clipboard} / {clipboard offset=2} / {clipboard offset=9}.", in: environment)
                == "newest / oldest / .")
        #expect(await render("[{selection}]") == "[selected text]")
        #expect(await render("{uuid}") == "01020304-0506-0708-090A-0B0C0D0E0F10")
    }

    @Test func appliesModifiersLeftToRight() async {
        #expect(await render("{selection | uppercase}") == "SELECTED TEXT")
        let environment = environment(clipboard: ["  He said \"hi\"/\n "])
        #expect(await render("{clipboard | trim | json-stringify}", in: environment) == #""He said \"hi\"/""#)
        #expect(
            await render("{clipboard | trim | lowercase | percent-encode}", in: environment)
                == "he%20said%20%22hi%22%2F")
    }

    @Test func fillsArgumentsWithValuesThenDefaults() async {
        let source = #"{argument name="a"}-{argument name="b" default="B"}-{argument}-{argument name="a"}"#
        #expect(await render(source, in: environment(arguments: ["a": "1", "#1": "x"])) == "1-B-x-1")
        #expect(await render(source, in: environment(arguments: ["b": ""])) == "-B--")
    }

    @Test func urlStyleEncodesEveryValueOnce() async {
        let source =
            #"https://example.com/?q={argument name="q"}&r={argument name="q" | raw}&p={argument name="q" | percent-encode}"#
        #expect(
            await render(source, style: .url, in: environment(arguments: ["q": "a b&c"]))
                == "https://example.com/?q=a%20b%26c&r=a b&c&p=a%20b%26c")
    }

    @Test func promptStyleQuotesUserContent() async {
        let source = "Summarize {selection} on {date format=\"yyyy\"} ({clipboard | raw})"
        #expect(await render(source, style: .prompt) == "Summarize \"\"\"selected text\"\"\" on 2026 (copied text)")
    }

    @Test func marksTheFirstCursorInPlainStyleOnly() async {
        let template = Template("Dear {cursor},\nThanks{cursor}")
        let plain = await template.render(in: environment())
        #expect(plain.text == "Dear ,\nThanks")
        #expect(plain.cursorOffset == 5)
        #expect(plain.charactersAfterCursor == 8)
        #expect(plain.expansion == Expansion("Dear ,\nThanks", charactersAfterCursor: 8))
        let url = await template.render(in: environment(), style: .url)
        #expect(url.cursorOffset == nil)
        #expect(url.charactersAfterCursor == 0)
    }

    @Test func embedsSnippetsOneLevelDeep() async {
        let environment = environment(snippets: [
            "sig": "Best,\n{argument name=\"who\" default=\"Kit\"}{cursor} {snippet name=\"inner\"}", "inner": "never",
        ])
        let rendered = await Template("Hi{cursor}\n{snippet name=\"sig\"}{snippet name=\"missing\"}").render(
            in: environment)
        #expect(rendered.text == "Hi\nBest,\nKit ")
        #expect(rendered.cursorOffset == 2)
    }

    @Test func keepsBrokenPlaceholdersAsTyped() async {
        #expect(
            await render("{date format=\"y\" locale=\"fr\"} {selection | nope} {selection}")
                == "{date format=\"y\" locale=\"fr\"} {selection | nope} selected text")
    }

    @Test func wiresAFeaturesServices() async {
        let fakes = FakeServices()
        fakes.pasteboard.simulateCopy("older")
        fakes.pasteboard.simulateCopy("newer")
        fakes.selection.selection = .text("chosen")
        let environment = TemplateEnvironment(context: fakes.context(featureID: "demo"), arguments: ["q": "x"])
        let text = await Template.render(
            "{clipboard offset=1} {selection} {argument name=\"q\"} {date format=\"yyyy\"}", in: environment)
        #expect(text == "older chosen x 2026")
        #expect(fakes.selection.reads == 1)
        _ = await Template.render("{date}", in: environment)
        #expect(fakes.selection.reads == 1, "the selection is read only when the template asks for it")
    }
}
