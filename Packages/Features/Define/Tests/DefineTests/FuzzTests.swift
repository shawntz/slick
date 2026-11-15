import Foundation
import Kit
import KitTesting
import Testing

@testable import Define

/// Text a dictionary, a damaged dictionary or another language could return, made from pieces
/// of the shapes the parser looks for. Seeded, so a failure repeats.
@Suite("Parser under odd text", .timeLimit(.minutes(1)))
struct FuzzTests {
    static let pieces = [
        "|", " | ", "1", "2", "3", " 1 ", "•", " • ", "noun", "verb", "adjective", "ORIGIN", "PHRASES", "DERIVATIVES",
        ":", "(", ")", "[", "]", "lantern", "lan·tern", "ˈlan(t)ərn", "a lamp", ".", ",", " ", "  ", "\n", "\r\n",
        "\t", "\u{0}", "\u{202E}", "\u{2066}", "\u{2028}", "\u{2029}", "\u{200B}", "猫", "مرحبا", "😀", "e\u{301}",
        "…", "‘", "’", "\"", "*", "_", "#", "`", "-", "—", "\\", "<", ">", "!", "[link](x)",
    ]

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func everyTextGivesAnEntryWithAVisibleOneLineTitle() {
        var random = Seeded(state: 42)
        for _ in 0..<5_000 {
            let count = Int.random(in: 0..<40, using: &random)
            let text = (0..<count).map { _ in Self.pieces.randomElement(using: &random) ?? "" }.joined()
            // A lookup always passes a cleaned term, as LookupTerm makes it.
            guard let term = LookupTerm.make(Self.pieces.randomElement(using: &random) ?? "x")?.text else {
                continue
            }
            let definition = DefinitionParser.parse(text, term: term)
            let row = WordRows.definition(definition)
            let titleBreaks = row.title.contains { $0.isNewline }
            let titleControls = row.title.unicodeScalars.contains { $0.properties.generalCategory == .control }
            let titleVisible = row.title.unicodeScalars.contains {
                !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint
            }
            let subtitleBreaks = (row.subtitle ?? "").contains { $0.isNewline }
            #expect(titleVisible, "\(text.debugDescription) for \(term.debugDescription)")
            #expect(!titleBreaks, "\(text.debugDescription)")
            #expect(!titleControls, "\(text.debugDescription)")
            #expect(!subtitleBreaks, "\(text.debugDescription)")
        }
    }

    @Test func termsWithNothingVisibleAreRefused() {
        for text in ["\u{200B}", "\u{200B}\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{200D}"] {
            #expect(LookupTerm.read(text) == .failure(.empty), "\(text.debugDescription)")
        }
        #expect(LookupTerm.make("co\u{00AD}operate")?.text == "cooperate")
        #expect(LookupTerm.make("👨‍👩‍👧")?.text == "👨‍👩‍👧", "a joined emoji keeps its joiners")
        #expect(LookupTerm.make("\u{200B}lantern\u{200B}")?.text == "lantern")
    }
}

@Suite("Hardening", .timeLimit(.minutes(1)))
struct DefineHardeningTests {
    @Test func deepLinksOnlyOpenPagesAndNoRuleIsPending() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        await harness.activate()
        #expect(try await harness.run("define", arguments: ["word": "lantern"], launch: .deeplink).kind == .push)
        harness.pop()
        #expect(try await harness.run("spell", arguments: ["word": "recieve"], launch: .deeplink).kind == .push)
        #expect(harness.fakes.pasteboard.copiedTexts.isEmpty)
        #expect(harness.fakes.pasteboard.pastedTexts.isEmpty)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func aKeywordWithNothingVisibleLooksNothingUp() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        for query in ["define \u{200B}", "spell \u{00AD}\u{200D}", "define \u{FEFF}"] {
            #expect(try await harness.asyncSections(for: query).flatMap(\.rows).isEmpty, "\(query.debugDescription)")
        }
        #expect(lookup.recorded.isEmpty)
    }
}
