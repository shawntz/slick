import Foundation
import Kit
import KitTemplates
import KitTesting
import Testing

@testable import Snippets

/// Every placeholder, rendered through the feature with the fake clock (Saturday 14 November 2026,
/// 09:30 UTC, en_US_POSIX), the fake pasteboard and the fake selection.
@Suite("Placeholders", .timeLimit(.minutes(1)))
struct PlaceholderTests {
    /// Renders one snippet's text the way Paste does.
    private func render(
        _ text: String, arguments: [String: String] = [:], others: [Snippet] = [], fakes: FakeServices = FakeServices()
    ) async throws -> RenderedTemplate {
        let harness = try await FeatureHarness.loaded(others + [Fixture.snippet("Under Test", text)], fakes: fakes)
        return try await harness.feature.render(id: "id-under-test", arguments: arguments)
    }

    @Test func datesAndTimesUseTheFeaturesClock() async throws {
        #expect(try await render("{date}").text == "Nov 14, 2026")
        #expect(try await render("{time}").text == "9:30\u{202F}AM")
        #expect(try await render("{datetime}").text == "Nov 14, 2026 at 9:30\u{202F}AM")
        #expect(try await render("{day}").text == "Saturday")
    }

    @Test func dateFormatsOffsetsAndLocales() async throws {
        #expect(try await render(#"{date format="yyyy-MM-dd"}"#).text == "2026-11-14")
        #expect(try await render(#"{date offset="+1d" format="EEEE d MMMM"}"#).text == "Sunday 15 November")
        #expect(try await render(#"{date offset="+2y -3d" format="yyyy-MM-dd"}"#).text == "2028-11-11")
        #expect(try await render(#"{date offset="-1M +1w" format="yyyy-MM-dd"}"#).text == "2026-10-21")
        #expect(try await render(#"{time offset="+90m" format="HH:mm"}"#).text == "11:00")
        #expect(try await render(#"{date locale="fr-FR"}"#).text == "14 nov. 2026")
        #expect(try await render(#"{date format="'Week' w"}"#).text == "Week 46")
    }

    @Test func eachPasteReadsTheClockAgain() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.snippet("Stamp", #"{date format="HH:mm"}"#)])
        #expect(try await harness.feature.render(id: "id-stamp").text == "09:30")
        harness.fakes.clock.advance(by: .seconds(3600))
        #expect(try await harness.feature.render(id: "id-stamp").text == "10:30")
    }

    @Test func clipboardAndEarlierClipboardEntries() async throws {
        let fakes = FakeServices()
        fakes.pasteboard.simulateCopy("first copy")
        fakes.pasteboard.simulateCopy("second copy")
        fakes.pasteboard.simulateCopy("  latest copy  ")
        let rendered = try await render(
            "[{clipboard}] [{clipboard offset=1}] [{clipboard offset=2}] [{clipboard offset=9}] [{clipboard | trim | uppercase}]",
            fakes: fakes)
        #expect(rendered.text == "[  latest copy  ] [second copy] [first copy] [] [LATEST COPY]")
    }

    @Test func cursorSetsWhereTheInsertionPointGoes() async throws {
        let rendered = try await render("Dear {cursor},\nThanks")
        #expect(rendered.text == "Dear ,\nThanks")
        #expect(rendered.charactersAfterCursor == 8)
        #expect(rendered.expansion == Expansion("Dear ,\nThanks", charactersAfterCursor: 8))
        #expect(try await render("No cursor").charactersAfterCursor == 0)
    }

    @Test func uuidIsNewEachTime() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.snippet("Id", "{uuid}|{uuid | lowercase}")])
        let first = try await harness.feature.render(id: "id-id").text
        let second = try await harness.feature.render(id: "id-id").text
        let parts = first.split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(parts[1] == parts[1].lowercased())
        #expect(first != second)
    }

    @Test func anotherSnippetByNameOneLevelDeep() async throws {
        let inner = Fixture.snippet("Signature", "The Team, {date format=\"yyyy\"}")
        let deepest = Fixture.snippet("Footer", "Footer {snippet name=\"Signature\"}")
        #expect(try await render("Hi\n{snippet name=\"Signature\"}", others: [inner]).text == "Hi\nThe Team, 2026")
        // Snippets nest one level: the footer's own include renders as nothing.
        #expect(try await render("[{snippet name=\"Footer\"}]", others: [inner, deepest]).text == "[Footer ]")
        #expect(try await render("[{snippet name=\"Missing\"}]").text == "[]")
    }

    @Test func selectionComesFromTheFrontmostApp() async throws {
        let fakes = FakeServices()
        fakes.selection.selection = .text("selected words")
        #expect(try await render("> {selection}", fakes: fakes).text == "> selected words")
    }

    @Test func argumentsWithDefaultsAndOptions() async throws {
        let text =
            #"{argument name="who"} / {argument name="tone" options="warm, formal" default="warm"} / {argument name="who"}"#
        #expect(try await render(text, arguments: ["who": "Sam"]).text == "Sam / warm / Sam")
        #expect(try await render(text, arguments: ["who": "Sam", "tone": "formal"]).text == "Sam / formal / Sam")
    }

    @Test func modifiersApplyLeftToRight() async throws {
        let fakes = FakeServices()
        fakes.pasteboard.simulateCopy(" Mixed Case ")
        #expect(try await render("{clipboard | trim | lowercase}", fakes: fakes).text == "mixed case")
        #expect(try await render("{clipboard | json-stringify}", fakes: fakes).text == "\" Mixed Case \"")
        #expect(try await render("{clipboard | trim | percent-encode}", fakes: fakes).text == "Mixed%20Case")
    }

    @Test func textThatIsNotAPlaceholderStaysAsTyped() async throws {
        let code = "func f() { return {\"a\": 1} }\n{unknown}"
        #expect(try await render(code).text == code)
        // A known placeholder with a mistake stays as typed too.
        #expect(try await render(#"{date offset="soon"}"#).text == #"{date offset="soon"}"#)
    }
}
