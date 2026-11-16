import Testing

@testable import TranslateCommands

/// The AI feature's Translate with AI starts with the long keyword too. While a query can still
/// grow into that title, it is a search for the command, not text to translate.
@Suite("Another feature's title", .timeLimit(.minutes(1)))
struct AnotherFeaturesTitleTests {
    @Test func typingTranslateWithAITranslatesNothing() {
        for query in ["translate w", "translate wi", "translate with", "translate with a", "Translate with AI"] {
            #expect(RootKeyword.text(in: query) == nil, "\(query)")
        }
        #expect(RootKeyword.text(in: "translate with care") == "with care")
        #expect(RootKeyword.text(in: "translate water") == "water")
        #expect(RootKeyword.text(in: "tr with ai") == "with ai")
    }
}
