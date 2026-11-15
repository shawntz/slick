import Foundation
import Testing

@testable import Define

@Suite("Input", .timeLimit(.minutes(1)))
struct InputTests {
    @Test func termsAreTrimmedAndKeptOnOneLine() throws {
        let term = try LookupTerm.read("  ice \t\n cream \r\n").get()
        #expect(term.text == "ice cream")
        #expect(term.wordCount == 2)
        #expect(!term.isSingleWord)
        #expect(try LookupTerm.read("lantern").get().isSingleWord)
    }

    @Test func emptyAndBlankTextIsRefused() {
        #expect(LookupTerm.read("") == .failure(.empty))
        #expect(LookupTerm.read("   \n\t ") == .failure(.empty))
        #expect(LookupTerm.read("\u{0}\u{202E}\u{2066}") == .failure(.empty))
    }

    @Test func controlAndDirectionCharactersAreRemoved() throws {
        #expect(try LookupTerm.read("lan\u{202E}tern").get().text == "lantern")
        #expect(try LookupTerm.read("ice\u{0}cream").get().text == "ice cream")
        #expect(try LookupTerm.read("\u{2067}naïve\u{2069}").get().text == "naïve")
    }

    @Test func eightyCharactersAreAllowedAndEightyOneAreNot() {
        let longest = String(repeating: "a", count: LookupTerm.maximumLength)
        #expect((try? LookupTerm.read(longest).get())?.text == longest)
        #expect(LookupTerm.read(longest + "a") == .failure(.tooLong))
    }

    /// A pasted paragraph or a huge selection is refused after a few hundred characters, so it
    /// costs the same as a short one.
    @Test(arguments: [
        String(repeating: "word ", count: 200_000), String(repeating: " ", count: 1_000_000) + "word",
        "word" + String(repeating: " ", count: 1_000_000), String(repeating: "\u{0}", count: 500_000),
    ])
    func veryLongTextIsRefusedQuickly(text: String) {
        let clock = ContinuousClock()
        var result: Result<LookupTerm, LookupTerm.Problem>?
        let elapsed = clock.measure { result = LookupTerm.read(text) }
        #expect(result == .failure(.tooLong))
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    @Test(arguments: ["猫", "日本語", "привет", "naïve", "café au lait", "שלום", "مرحبا", "😀", "e-mail", "don't"])
    func otherScriptsAndMarksAreKept(text: String) throws {
        #expect(try LookupTerm.read(text).get().text == text)
    }

    @Test func dictionaryLinksArePercentEncoded() {
        #expect(DictionaryPages.dictionaryURL(for: "lantern")?.absoluteString == "dict://lantern")
        #expect(DictionaryPages.dictionaryURL(for: " ice  cream ")?.absoluteString == "dict://ice%20cream")
        #expect(DictionaryPages.dictionaryURL(for: "naïve")?.absoluteString == "dict://na%C3%AFve")
        #expect(DictionaryPages.dictionaryURL(for: "猫")?.absoluteString == "dict://%E7%8C%AB")
        #expect(DictionaryPages.dictionaryURL(for: "a/b?c#d")?.absoluteString == "dict://a%2Fb%3Fc%23d")
        #expect(DictionaryPages.dictionaryURL(for: "  ") == nil)
    }

    @Test func guessesAreCleaned() {
        let guesses =
            ["receive", "recieve", "receive", " relieve ", "", String(repeating: "x", count: 100)]
            + (1...20).map { "word\($0)" }
        let cleaned = Lookup.cleaned(guesses, for: "recieve")
        #expect(cleaned.prefix(2) == ["receive", "relieve"])
        #expect(cleaned.count == Lookup.maximumGuesses)
        #expect(!cleaned.contains("recieve"))
    }

    @Test func spellingVerdictsFollowTheDetectedLanguage() {
        let available = ["en", "en_GB", "fr", "ru", "pt_BR"]
        #expect(SharedSpellChecker.verdict(misspelled: true, detected: "en", available: available) == .misspelled)
        #expect(SharedSpellChecker.verdict(misspelled: false, detected: "und", available: available) == .correct)
        #expect(SharedSpellChecker.verdict(misspelled: false, detected: nil, available: available) == .correct)
        #expect(SharedSpellChecker.verdict(misspelled: false, detected: "ru", available: available) == .correct)
        #expect(SharedSpellChecker.verdict(misspelled: false, detected: "pt-PT", available: available) == .correct)
        #expect(SharedSpellChecker.verdict(misspelled: false, detected: "ja", available: available) == .unchecked)
        #expect(SharedSpellChecker.baseLanguage("en_GB") == "en")
        #expect(SharedSpellChecker.baseLanguage("") == nil)
    }
}

@Suite("Root queries", .timeLimit(.minutes(1)))
struct RootQueryTests {
    @Test func keywordsNeedASpaceAndText() {
        #expect(RootQuery.keyword(in: "define lantern") == .define("lantern"))
        #expect(RootQuery.keyword(in: "DEFINE Lantern") == .define("Lantern"))
        #expect(RootQuery.keyword(in: "Define   ice cream ") == .define("  ice cream "))
        #expect(RootQuery.keyword(in: "spell recieve") == .spell("recieve"))
        #expect(RootQuery.keyword(in: "Spell 猫") == .spell("猫"))
        #expect(RootQuery.keyword(in: "define") == nil)
        #expect(RootQuery.keyword(in: "define ") == nil)
        #expect(RootQuery.keyword(in: "define    ") == nil)
        #expect(RootQuery.keyword(in: "definex lantern") == nil)
        #expect(RootQuery.keyword(in: "spellbook") == nil)
        #expect(RootQuery.keyword(in: "spel lantern") == nil)
    }

    @Test(arguments: [
        "safari", "", "~/Documents", "/usr", ":smile", "=1+1", "d", "s", "dfine x", "Ðefine x", "ßpell x",
    ])
    func otherQueriesAreTurnedAway(query: String) {
        #expect(RootQuery.keyword(in: query) == nil)
    }

    @Test func aPastedParagraphAfterAKeywordIsNotALookup() {
        #expect(RootQuery.keyword(in: "define " + String(repeating: "x", count: RootQuery.maximumBytes)) != nil)
        #expect(RootQuery.keyword(in: "define " + String(repeating: "x", count: RootQuery.maximumBytes + 1)) == nil)
    }

    @Test func singleWordsAreLettersWithInnerMarks() {
        #expect(RootQuery.singleWord("lantern")?.text == "lantern")
        #expect(RootQuery.singleWord("naïve")?.text == "naïve")
        #expect(RootQuery.singleWord("don't")?.text == "don't")
        #expect(RootQuery.singleWord("well-being")?.text == "well-being")
        #expect(RootQuery.singleWord("привет")?.text == "привет")
        for query in [
            "ab", "ice cream", "safari 2", "x2", "-ab", "abc-", "~/x", "😀😀😀", String(repeating: "a", count: 41),
        ] {
            #expect(RootQuery.singleWord(query) == nil, "\(query)")
        }
    }
}
