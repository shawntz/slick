import Foundation
import Kit
import Testing

@testable import TranslateCommands

@Suite("Text", .timeLimit(.minutes(1)))
struct TextTests {
    @Test func textIsCleanedBeforeItIsTranslated() {
        #expect(TranslationText.cleaned("  Bonjour \n") == "Bonjour")
        #expect(TranslationText.cleaned("Bon\u{0}jour\u{7}") == "Bonjour")
        #expect(TranslationText.cleaned("one\ntwo\tthree") == "one\ntwo\tthree")
        #expect(TranslationText.cleaned("\u{200B}\u{2060} ") == "")
        #expect(TranslationText.cleaned("") == "")
    }

    @Test func countingStopsAtTheLimit() {
        #expect(!TranslationText.exceeds("abc", bytes: 3))
        #expect(TranslationText.exceeds("abcd", bytes: 3))
        #expect(TranslationText.exceeds("é", bytes: 1), "bytes, not characters")
        let book = String(repeating: "a", count: 5_000_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = TranslationText.exceeds(book, bytes: TranslationText.rootMaximumBytes) }
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
    }

    @Test func titlesAreOneLineAndCut() {
        #expect(TranslationText.title("a\nb\u{2028}c") == "a b c")
        #expect(TranslationText.title("x\u{202E}y") == "x\u{FFFD}y")
        let long = TranslationText.title(String(repeating: "word ", count: 100))
        #expect(long.count == TranslationText.titleLimit)
        #expect(long.hasSuffix("…"))
    }

    @Test func markdownSignsShowAsWritten() {
        #expect(
            TranslationText.escaped("*a* _b_ `c` [d](e) <f> #g") == "\\*a\\* \\_b\\_ \\`c\\` \\[d\\](e) \\<f\\> \\#g")
        #expect(TranslationText.escapedParagraph("- item") == "\\- item")
        #expect(TranslationText.escapedParagraph("12. item") == "12\\. item")
        #expect(TranslationText.paragraph("a\nb") == "a b")
    }

    @Test func detailsForEveryOutcomeHaveTextThatShows() {
        let catalog = simulatedCatalog()
        let outcomes: [TranslationOutcome] = [
            .translated(source: .tag("fr"), target: .tag("en-US"), text: "Good morning"),
            .needsDownload(source: .tag("fr"), target: .tag("de"), missing: [.tag("de")]),
            .needsDownload(source: .tag("fr"), target: .tag("de"), missing: [.tag("fr"), .tag("de")]),
            .unsupportedLanguage("is"), .unsupportedPair(source: .tag("ja"), target: .tag("es")),
            .alreadyIn(.tag("en-US")), .notRecognized, .tooLong, .unavailable,
            .failed("The model is busy.\nTry later."),
        ]
        for outcome in outcomes {
            for place in [RowPlace.page, .root] {
                let row = TranslationRows.row(
                    outcome, original: "Bonjour", requested: nil, catalog: catalog, id: TranslationRows.rootRowID,
                    place: place)
                #expect(!row.title.isEmpty && !row.title.contains("\n") && !row.title.hasSuffix("."), "\(outcome)")
                #expect(row.subtitle?.hasSuffix(".") ?? false || outcome.translation != nil, "\(outcome)")
                #expect(row.memory == .never)
            }
            guard case .markdown(let text) = TranslationRows.detail(outcome, catalog: catalog).body else {
                Issue.record("no Markdown for \(outcome)")
                continue
            }
            #expect(!text.isEmpty)
        }
        let both = TranslationRows.row(
            .needsDownload(source: .tag("fr"), target: .tag("de"), missing: [.tag("fr"), .tag("de")]),
            original: "Bonjour", requested: nil, catalog: catalog, id: TranslationRows.rootRowID, place: .root)
        #expect(both.title == "Download French and German to Translate")
        #expect(both.subtitle == "French and German are not installed on this Mac. Download them in System Settings.")
    }

    @Test func listsReadAsSentences() {
        #expect(TranslateStrings.list([]) == "")
        #expect(TranslateStrings.list(["French"]) == "French")
        #expect(TranslateStrings.list(["French", "German"]) == "French and German")
        #expect(TranslateStrings.list(["French", "German", "Spanish"]) == "French, German and Spanish")
    }

    @Test func userFacingTitlesUseTitleCaseWithoutAStop() {
        let titles = [
            TranslateStrings.translateCommand, TranslateStrings.selectionCommand, TranslateStrings.dropdownTitle,
            TranslateStrings.typeTextTitle, TranslateStrings.tooLongTitle, TranslateStrings.unavailableTitle,
            TranslateStrings.noSelectionTitle, TranslateStrings.selectionTooLongTitle, TranslateStrings.copyTranslation,
            TranslateStrings.copiedTranslation, TranslateStrings.pasteTranslation, TranslateStrings.swapLanguages,
            TranslateStrings.copyOriginal, TranslateStrings.copiedOriginal, TranslateStrings.openInTranslate,
            TranslateStrings.openLanguageSettings, TranslateStrings.notRecognizedTitle, TranslateStrings.failedTitle,
            TranslateStrings.languagesSection, TranslateStrings.rootSearchSection, TranslateStrings.downloadsSection,
            TranslateStrings.permissionsSection, TranslateStrings.privacySection, TranslateStrings.unavailableStatus,
        ]
        let small: Set = ["to", "in", "and", "the", "a", "of"]
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            for word in title.split(separator: " ") where !small.contains(String(word)) {
                #expect(word.first?.isUppercase == true, "\(title)")
            }
        }
        let sentences = [
            TranslateStrings.summary, TranslateStrings.accessibilityReason, TranslateStrings.typeTextMessage,
            TranslateStrings.tooLongMessage, TranslateStrings.rootTooLongMessage, TranslateStrings.unavailableMessage,
            TranslateStrings.noSelectionMessage, TranslateStrings.alreadyInMessage,
            TranslateStrings.notRecognizedMessage,
            TranslateStrings.emptyTranslation, TranslateStrings.downloadSteps, TranslateStrings.targetInfo,
            TranslateStrings.secondInfo, TranslateStrings.keywordsInfo, TranslateStrings.downloadsNote,
            TranslateStrings.openLanguageSettingsInfo, TranslateStrings.accessibilityInfo, TranslateStrings.privacyNote,
        ]
        for sentence in sentences {
            #expect(sentence.hasSuffix(".") && sentence.first?.isUppercase == true, "\(sentence)")
        }
    }
}

/// The NaturalLanguage recognizer the live engine uses. It reads only the text it is given and the
/// model that ships with macOS, so it runs in tests; the sentences are made up.
@Suite("Recognizer", .timeLimit(.minutes(1)))
struct RecognizerTests {
    @Test func clearSentencesAreRecognized() {
        let cases = [
            ("The old lighthouse keeper paints the boats every spring before the season starts.", "en"),
            ("Le vieux gardien du phare peint les bateaux chaque printemps avant le début de la saison.", "fr"),
            ("El viejo farero pinta los barcos cada primavera antes de que empiece la temporada.", "es"),
            ("Der alte Leuchtturmwärter streicht jeden Frühling die Boote, bevor die Saison beginnt.", "de"),
            ("年老いた灯台守は、シーズンが始まる前に毎年春になると船を塗り直します。", "ja"),
        ]
        for (text, expected) in cases {
            let guesses = LanguageRecognizer.guesses(for: text, hint: nil)
            #expect(guesses.first?.identifier == expected, "\(text)")
            #expect(guesses.count <= LanguageRecognizer.maximumGuesses)
        }
        let catalog = simulatedCatalog()
        let french = LanguageRecognizer.guesses(for: "Le chat dort sur le canapé depuis ce matin.", hint: nil)
        #expect(catalog.source(from: french) == .supported(.tag("fr")))
    }

    @Test func nothingToReadGivesNoGuess() {
        #expect(LanguageRecognizer.guesses(for: "", hint: nil).isEmpty)
        #expect(LanguageRecognizer.guesses(for: "1234 5678", hint: nil).allSatisfy { $0.identifier != "und" })
    }

    @Test func chineseIsNamedByScript() {
        #expect(LanguageRecognizer.recognizerCode(for: .tag("zh-Hant")) == "zh-Hant")
        #expect(LanguageRecognizer.recognizerCode(for: .tag("zh")) == "zh-Hans")
        #expect(LanguageRecognizer.recognizerCode(for: .tag("pt-BR")) == "pt")
    }

    @Test func guessesSortTheSameWayEveryTime() {
        let sorted = LanguageRecognizer.sorted([
            LanguageGuess("fr", probability: 0.2), LanguageGuess("de", probability: 0.2),
            LanguageGuess("es", probability: 0.6),
        ])
        #expect(sorted.map(\.identifier) == ["es", "de", "fr"])
    }
}
