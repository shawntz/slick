import Foundation
import Testing

@testable import Define

/// Entries written by hand in the shape Dictionary Services gives: one line, the head and the
/// pronunciation between bars, then parts of speech, sense numbers, bullets and capitalized
/// section labels.
nonisolated enum Entries {
    /// One part of speech without numbers, a bullet and an origin.
    static let quill =
        "quill | kwil | noun a large feather from the wing or tail of a bird. • a pen made from such a feather. ORIGIN late Middle English, of uncertain origin."

    /// A homograph number in the head, two parts of speech with numbered senses.
    static let pitch =
        "pitch 1 | piCH | noun 1 the quality of a sound that makes it high or low. • a standard for tuning instruments. 2 the playing field for some outdoor games: the ball rolled off the pitch. verb [with object] 1 set (a tent) up and fix it in place. 2 throw (a ball) toward a batter: he pitched a fast ball. ORIGIN Middle English."

    /// A note before the part of speech and a grammar note before the first sense.
    static let an =
        "an | an, ən | (the form of a used before a vowel sound) determiner [called the indefinite article] 1 used for one thing not named before: an hour ago. 2 used for each or per: twice an hour."

    /// Inflections with bars inside parentheses, a number in an example that is not a sense,
    /// and sections, one of which holds a part of speech.
    static let walk =
        "walk | wôk | verb (walks) (, walking | ˈwôkiNG |) (past; walked | wôkt |) 1 [no object] move on foot at an ordinary pace: she walked 12 miles on Sunday. • go on foot for pleasure: we walk most evenings. 2 [with object] go with (someone) on foot: he walked her home. noun 1 a trip on foot: a walk in the park. 2 a path for walking. PHRASAL VERBS walk out leave suddenly: she walked out of the meeting. DERIVATIVES walkable adjective ORIGIN Old English."

    /// An exclamation, then a noun after "!.".
    static let ahoy =
        "ahoy | əˈhoi | exclamation a call used by sailors to greet another boat: ship ahoy!. noun a shout of “ahoy”: we heard an ahoy from the deck. ORIGIN mid 18th century."

    /// A phrase headword whose syllables span two words.
    static let faitAccompli =
        "fait accompli fait ac·com·pli | ˌfet əkämˈplē | noun a thing already done that cannot be undone: the plan was presented as a fait accompli. ORIGIN French, ‘accomplished fact’."

    /// Phrases and usage sections.
    static let lark =
        "lark | lärk | noun a small songbird with a fine song. PHRASES be up with the lark get up very early. USAGE Often heard in the phrase up with the lark."

    /// No pronunciation: the entry starts with the term, then its syllables.
    static let nightfall = "nightfall night·fall noun the start of night; dusk: we reached camp before nightfall."

    /// Bars inside the examples but no pronunciation.
    static let note = "note noun a short written record: buy milk | call home | pay the rent."

    /// Lines, as a dictionary with its own layout gives them.
    static let lines = "Kyoto\nA city in Japan.\nIt was the capital for a thousand years."

    static let structured = [
        quill, pitch, an, walk, ahoy, faitAccompli, lark, FixtureLookup.harbor, FixtureLookup.naive,
    ]
}

@Suite("Parser", .timeLimit(.minutes(1)))
struct ParserTests {
    @Test func oneSenseWithABulletAndAnOrigin() {
        let definition = DefinitionParser.parse(Entries.quill, term: "quill")
        #expect(definition.headword == "quill")
        #expect(definition.syllables == nil)
        #expect(definition.pronunciation == "kwil")
        #expect(definition.isStructured)
        #expect(
            definition.paragraphs == [
                .partOfSpeech("noun", note: nil), .text("a large feather from the wing or tail of a bird."),
                .subsense("a pen made from such a feather."),
                .section("Origin", "late Middle English, of uncertain origin."),
            ])
    }

    @Test func syllablesAVariantNoteAndTwoPartsOfSpeech() {
        let definition = DefinitionParser.parse(FixtureLookup.harbor, term: "harbor")
        #expect(definition.headword == "harbor")
        #expect(definition.syllables == "har·bor")
        #expect(definition.pronunciation == "ˈhärbər")
        #expect(
            definition.paragraphs == [
                .text("(British English harbour)"), .partOfSpeech("noun", note: nil),
                .text(
                    "a sheltered stretch of water where ships can stay safely: the boats sat out the winter in the harbor."
                ),
                .partOfSpeech("verb", note: "[with object]"),
                .sense(1, "keep (a thought or feeling) in mind for a long time: he harbored a wish to sail."),
                .sense(2, "give shelter to: the cove harbored a few small boats."),
                .section("Origin", "Old English, in the sense ‘shelter’."),
            ])
    }

    @Test func aHomographNumberIsDroppedAndNumberingRestartsForEachPartOfSpeech() {
        let definition = DefinitionParser.parse(Entries.pitch, term: "pitch")
        #expect(definition.headword == "pitch")
        #expect(
            definition.paragraphs == [
                .partOfSpeech("noun", note: nil), .sense(1, "the quality of a sound that makes it high or low."),
                .subsense("a standard for tuning instruments."),
                .sense(2, "the playing field for some outdoor games: the ball rolled off the pitch."),
                .partOfSpeech("verb", note: "[with object]"), .sense(1, "set (a tent) up and fix it in place."),
                .sense(2, "throw (a ball) toward a batter: he pitched a fast ball."),
                .section("Origin", "Middle English."),
            ])
    }

    @Test func aLeadingNoteAndAGrammarNote() {
        let definition = DefinitionParser.parse(Entries.an, term: "an")
        #expect(definition.pronunciation == "an, ən")
        #expect(
            definition.paragraphs == [
                .text("(the form of a used before a vowel sound)"),
                .partOfSpeech("determiner", note: "[called the indefinite article]"),
                .sense(1, "used for one thing not named before: an hour ago."),
                .sense(2, "used for each or per: twice an hour."),
            ])
    }

    @Test func inflectionsWithBarsNumbersInExamplesAndSections() {
        let definition = DefinitionParser.parse(Entries.walk, term: "walked")
        #expect(definition.headword == "walk")
        #expect(definition.term == "walked")
        #expect(definition.pronunciation == "wôk")
        #expect(
            definition.paragraphs == [
                .partOfSpeech("verb", note: "(walks) (, walking | ˈwôkiNG |) (past; walked | wôkt |)"),
                .sense(1, "[no object] move on foot at an ordinary pace: she walked 12 miles on Sunday."),
                .subsense("go on foot for pleasure: we walk most evenings."),
                .sense(2, "[with object] go with (someone) on foot: he walked her home."),
                .partOfSpeech("noun", note: nil), .sense(1, "a trip on foot: a walk in the park."),
                .sense(2, "a path for walking."),
                .section("Phrasal Verbs", "walk out leave suddenly: she walked out of the meeting."),
                .section("Derivatives", "walkable adjective"), .section("Origin", "Old English."),
            ])
    }

    @Test func aPartOfSpeechAfterAnExclamationMark() {
        let definition = DefinitionParser.parse(Entries.ahoy, term: "ahoy")
        #expect(
            definition.paragraphs == [
                .partOfSpeech("exclamation", note: nil),
                .text("a call used by sailors to greet another boat: ship ahoy!."), .partOfSpeech("noun", note: nil),
                .text("a shout of “ahoy”: we heard an ahoy from the deck."), .section("Origin", "mid 18th century."),
            ])
    }

    @Test func aPhraseWhoseSyllablesSpanTwoWords() {
        let definition = DefinitionParser.parse(Entries.faitAccompli, term: "fait accompli")
        #expect(definition.headword == "fait accompli")
        #expect(definition.syllables == "fait ac·com·pli")
        #expect(definition.pronunciation == "ˌfet əkämˈplē")
    }

    @Test func phrasesAndUsageSections() {
        let definition = DefinitionParser.parse(Entries.lark, term: "lark")
        #expect(
            definition.paragraphs == [
                .partOfSpeech("noun", note: nil), .text("a small songbird with a fine song."),
                .section("Phrases", "be up with the lark get up very early."),
                .section("Usage", "Often heard in the phrase up with the lark."),
            ])
    }

    @Test func aVariantNoteThenSectionsThatHoldAPartOfSpeech() {
        let definition = DefinitionParser.parse(FixtureLookup.naive, term: "naïve")
        #expect(definition.headword == "naive")
        #expect(definition.syllables == "na·ive")
        #expect(definition.paragraphs.first == .text("(also naïve)"))
        #expect(definition.paragraphs[1] == .partOfSpeech("adjective", note: nil))
        #expect(definition.paragraphs.contains(.section("Derivatives", "naively adverb")))
        #expect(definition.summary == "lacking experience of the world and trusting too easily")
    }

    @Test func noPronunciationButTheTermAndItsSyllables() {
        let definition = DefinitionParser.parse(Entries.nightfall, term: "nightfall")
        #expect(definition.headword == "nightfall")
        #expect(definition.syllables == "night·fall")
        #expect(definition.pronunciation == nil)
        #expect(definition.isStructured)
        #expect(
            definition.paragraphs == [
                .partOfSpeech("noun", note: nil), .text("the start of night; dusk: we reached camp before nightfall."),
            ])
    }

    @Test func barsInExamplesAreNotAPronunciation() {
        let definition = DefinitionParser.parse(Entries.note, term: "note")
        #expect(definition.pronunciation == nil)
        #expect(definition.headword == "note")
        #expect(
            definition.paragraphs == [
                .partOfSpeech("noun", note: nil), .text("a short written record: buy milk | call home | pay the rent."),
            ])
    }

    @Test func textInAnotherScriptWithNoMarksIsShownWhole() {
        let definition = DefinitionParser.parse(FixtureLookup.cat, term: "猫")
        #expect(!definition.isStructured)
        #expect(definition.headword == "猫")
        #expect(definition.paragraphs == [.text(FixtureLookup.cat)])
        #expect(definition.summary == "ねこ【猫】 ネコ科の小形の哺乳類。古くから人に飼われ、ねずみを捕る。")
        #expect(definition.markdown.contains("ネコ科"))
    }

    @Test func linesOfAnUnknownLayoutStayLines() {
        let definition = DefinitionParser.parse(Entries.lines, term: "Kyoto")
        #expect(!definition.isStructured)
        #expect(
            definition.paragraphs == [
                .text("Kyoto"), .text("A city in Japan."), .text("It was the capital for a thousand years."),
            ])
    }

    @Test func emptyOrBlankTextHasNoParagraphs() {
        #expect(DefinitionParser.parse("", term: "x").paragraphs.isEmpty)
        #expect(DefinitionParser.parse(" \n\t \u{0} ", term: "x").paragraphs.isEmpty)
    }

    /// Every word of every entry reaches the copied text, so a missed cut never hides text.
    @Test(arguments: Entries.structured)
    func noWordIsLost(entry: String) {
        let definition = DefinitionParser.parse(entry, term: "x")
        let copied = definition.plainText
        let words = entry.split { !$0.isLetter }.filter { $0.count > 2 && $0.uppercased() != String($0) }
        for word in words {
            #expect(copied.contains(word), "\(word) is missing")
        }
    }

    @Test func controlAndDirectionCharactersAreCleaned() {
        let raw = "lan\u{202E}tern | ˈlantərn | noun a lamp\u{0}in a case\u{2067}.\r\n"
        let definition = DefinitionParser.parse(raw, term: "lantern")
        #expect(definition.headword == "lantern")
        #expect(definition.paragraphs == [.partOfSpeech("noun", note: nil), .text("a lamp in a case.")])
    }

    @Test func aVeryLongEntryIsCutAndStillParses() throws {
        let sense = "a sense that goes on and on, with an example: it went on. "
        let raw = "long | lông | noun " + String(repeating: sense, count: 3_000)
        let clock = ContinuousClock()
        var definition: Definition?
        let elapsed = clock.measure { definition = DefinitionParser.parse(raw, term: "long") }
        let parsed = try #require(definition)
        #expect(parsed.isStructured)
        #expect(parsed.plainText.hasSuffix("…"))
        #expect(parsed.plainText.count < DefinitionParser.maximumLength + 200)
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }
}

@Suite("Definition text", .timeLimit(.minutes(1)))
struct DefinitionTextTests {
    @Test func plainTextHasTheHeadThenOneBlockPerPartOfSpeechAndSection() {
        let definition = DefinitionParser.parse(Entries.quill, term: "quill")
        #expect(
            definition.plainText == """
                quill
                | kwil |

                noun
                a large feather from the wing or tail of a bird.
                • a pen made from such a feather.

                Origin
                late Middle English, of uncertain origin.
                """)
    }

    @Test func markdownHasTheWordItsSoundsAndParagraphs() {
        let definition = DefinitionParser.parse(FixtureLookup.harbor, term: "harbor")
        let blocks = definition.markdown.components(separatedBy: "\n\n")
        #expect(
            blocks == [
                "# harbor", "har·bor  \\| ˈhärbər \\|", "(British English harbour)", "### noun",
                "a sheltered stretch of water where ships can stay safely: the boats sat out the winter in the harbor.",
                "### verb", "\\[with object\\]",
                "1. keep (a thought or feeling) in mind for a long time: he harbored a wish to sail.",
                "2. give shelter to: the cove harbored a few small boats.", "### Origin",
                "Old English, in the sense ‘shelter’.",
            ])
    }

    @Test func subsensesNestUnderTheirSense() {
        let markdown = DefinitionParser.parse(Entries.pitch, term: "pitch").markdown
        #expect(markdown.contains("1. the quality of a sound that makes it high or low.\n\n  - a standard for tuning"))
        let quill = DefinitionParser.parse(Entries.quill, term: "quill").markdown
        #expect(quill.contains("\n\n- a pen made from such a feather."))
    }

    @Test func theDictionarysTextCannotBecomeMarkdown() {
        #expect(
            DefinitionText.escaped("*bold* _it_ [link](x) `code` <b> # | ~ \\")
                == "\\*bold\\* \\_it\\_ \\[link\\](x) \\`code\\` \\<b\\> \\# \\| \\~ \\\\")
        #expect(DefinitionText.escapedParagraph("1990. a year") == "1990\\. a year")
        #expect(DefinitionText.escapedParagraph("3) third") == "3\\) third")
        #expect(DefinitionText.escapedParagraph("- dash") == "\\- dash")
        #expect(DefinitionText.escapedParagraph("+ plus") == "\\+ plus")
        #expect(DefinitionText.escapedParagraph("=== rule") == "\\=== rule")
        #expect(DefinitionText.escapedParagraph("1990 was a year") == "1990 was a year")
        let raw = "star | stär | noun a bright body. ORIGIN 1990. a *bright* body [see] `sun` # 5"
        let markdown = DefinitionParser.parse(raw, term: "star").markdown
        #expect(markdown.contains("1990\\. a \\*bright\\* body \\[see\\] \\`sun\\` \\# 5"))
    }

    @Test func theSummaryIsTheFirstMeaningWithoutGrammarOrExamples() {
        #expect(DefinitionParser.parse(Entries.walk, term: "walk").summary == "move on foot at an ordinary pace")
        #expect(
            DefinitionParser.parse(Entries.ahoy, term: "ahoy").summary == "a call used by sailors to greet another boat"
        )
        #expect(DefinitionText.withoutExamplesOrGrammar("[no object] go fast. Also: run") == "go fast")
        #expect(DefinitionText.withoutExamplesOrGrammar("one | two") == "one")
        let long = String(repeating: "word ", count: 60)
        let summary = DefinitionText.shortened(long)
        #expect(summary.hasSuffix("…"))
        #expect(summary.count <= DefinitionText.summaryLimit + 1)
    }
}
