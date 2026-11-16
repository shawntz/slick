import Foundation
import Kit
import Testing

@testable import TranslateCommands

@Suite("Languages", .timeLimit(.minutes(1)))
struct CatalogTests {
    @Test func tagsNameTheSameLanguageHoweverItIsWritten() {
        #expect(LanguageTag("fr") == LanguageTag("fr-FR"))
        #expect(LanguageTag("fr_FR") == LanguageTag("fr-Latn-FR"))
        #expect(LanguageTag("fr").identifier == "fr-Latn-FR")
        #expect(LanguageTag("zh-Hans").identifier == "zh-Hans-CN")
        #expect(LanguageTag("en-GB").isSameLanguage(as: LanguageTag("en-US")))
        #expect(!LanguageTag("zh-Hans").isSameLanguage(as: LanguageTag("zh-Hant")))
        #expect(!LanguageTag("fr").isSameLanguage(as: LanguageTag("es")))
    }

    @Test func titlesNameEachLanguageAndTellVariantsApart() {
        let catalog = simulatedCatalog(supported: ["en-US", "en-GB", "fr-FR", "zh-Hans", "zh-Hant", "de"])
        #expect(
            catalog.entries.map(\.title) == [
                "Chinese, Simplified", "Chinese, Traditional", "English (United Kingdom)",
                "English (United States)", "French", "German",
            ])
        #expect(catalog.title(of: .tag("fr")) == "French")
        #expect(catalog.title(of: .tag("is")) == "Icelandic", "a language the engine lacks still has a name")
        #expect(catalog.title(ofRecognized: "zh-Hant") == "Chinese, Traditional")
    }

    @Test func repeatedLanguagesAppearOnce() {
        let catalog = LanguageCatalog.make(
            supported: [.tag("fr"), .tag("fr-FR"), .tag("de")], preferred: [], display: Locale(identifier: "en"))
        #expect(catalog.entries.map(\.tag) == [.tag("fr"), .tag("de")])
    }

    @Test func namesAreMatchedInEnglishAndInTheUsersLanguage() {
        let catalog = simulatedCatalog(preferred: ["de-DE", "en-US"])
        #expect(catalog.language(named: "french") == .tag("fr"))
        #expect(catalog.language(named: "FRENCH") == .tag("fr"))
        #expect(catalog.language(named: "Französisch") == .tag("fr"))
        #expect(catalog.language(named: "franzosisch") == .tag("fr"), "accents do not matter")
        #expect(catalog.language(named: "  Japanese ") == .tag("ja"))
        #expect(catalog.language(named: "Japanisch") == .tag("ja"))
        #expect(catalog.language(named: "Spanisch") == .tag("es"))
        #expect(catalog.language(named: "Klingon") == nil)
        #expect(catalog.language(named: "") == nil)
        #expect(catalog.language(named: String(repeating: "french ", count: 20)) == nil)
    }

    @Test func aBareNameMeansTheVariantTheUserPrefers() {
        let american = simulatedCatalog(preferred: ["en-US"])
        #expect(american.language(named: "english") == .tag("en-US"))
        #expect(american.language(named: "english united kingdom") == .tag("en-GB"))
        #expect(american.language(named: "English (United Kingdom)") == .tag("en-GB"))
        let british = simulatedCatalog(preferred: ["en-GB"])
        #expect(british.language(named: "english") == .tag("en-GB"))
        #expect(british.automaticTarget == .tag("en-GB"))
        let chinese = simulatedCatalog(supported: ["zh-Hans", "zh-Hant", "en"], preferred: ["en"])
        #expect(chinese.language(named: "chinese simplified") == .tag("zh-Hans"))
        #expect(chinese.language(named: "Chinese, Traditional") == .tag("zh-Hant"))
        #expect(chinese.language(named: "chinese") == .tag("zh-Hans"), "Foundation's default script")
    }

    @Test func automaticIsTheFirstPreferredLanguageTheMacOffers() {
        #expect(simulatedCatalog(preferred: ["de-DE"]).automaticTarget == .tag("de"))
        #expect(simulatedCatalog(preferred: ["is-IS", "fr-CA"]).automaticTarget == .tag("fr"))
        #expect(simulatedCatalog(preferred: ["is-IS"]).automaticTarget == .tag("en-US"), "else English")
        #expect(simulatedCatalog(supported: ["ja", "fr"], preferred: ["is"]).automaticTarget == .tag("fr"))
        #expect(simulatedCatalog(supported: [], preferred: ["en"]).automaticTarget == nil)
    }

    @Test func storedSettingsResolveAgainstTheList() {
        let catalog = simulatedCatalog()
        #expect(catalog.resolve("") == .tag("en-US"))
        #expect(catalog.resolve("fr-Latn-FR") == .tag("fr"))
        #expect(catalog.resolve("fr") == .tag("fr"), "a short identifier still names the language")
        #expect(catalog.resolve("is-Latn-IS") == .tag("en-US"), "a language no longer offered falls back to Automatic")
        #expect(catalog.resolveOptional("") == nil)
        #expect(catalog.resolveOptional("es-Latn-ES") == .tag("es"))
        #expect(catalog.resolveOptional("is") == nil)
    }

    @Test func guessesBecomeASourceLanguage() {
        let catalog = simulatedCatalog()
        #expect(catalog.source(from: []) == .unknown)
        #expect(catalog.source(from: [LanguageGuess("fr", probability: 0.9)]) == .supported(.tag("fr")))
        #expect(catalog.source(from: [LanguageGuess("en", probability: 0.9)]) == .supported(.tag("en-US")))
        #expect(catalog.source(from: [LanguageGuess("is", probability: 0.9)]) == .unsupported("is"))
        // A close second guess that can be translated wins over a first one that cannot.
        let close = [LanguageGuess("is", probability: 0.5), LanguageGuess("de", probability: 0.4)]
        #expect(catalog.source(from: close) == .supported(.tag("de")))
        let far = [LanguageGuess("is", probability: 0.9), LanguageGuess("de", probability: 0.05)]
        #expect(catalog.source(from: far) == .unsupported("is"))
        let britishUser = simulatedCatalog(preferred: ["en-GB"])
        #expect(britishUser.source(from: [LanguageGuess("en", probability: 1)]) == .supported(.tag("en-GB")))
    }

    @Test func namesFoldCaseAccentsWidthAndPunctuation() {
        #expect(LanguageCatalog.folded("Chinese, Simplified") == "chinese simplified")
        #expect(LanguageCatalog.folded("  English (United Kingdom) ") == "english united kingdom")
        #expect(LanguageCatalog.folded("ＦＲＥＮＣＨ") == "french")
        #expect(LanguageCatalog.folded("Español") == "espanol")
        #expect(LanguageCatalog.folded("フランス語") == "フランス語")
    }

    @Test func aJapaneseUserFindsLanguagesInJapanese() {
        let catalog = simulatedCatalog(preferred: ["ja-JP"])
        let french = Locale(identifier: "ja-JP").localizedString(forLanguageCode: "fr") ?? ""
        #expect(!french.isEmpty)
        #expect(catalog.language(named: french) == .tag("fr"))
        #expect(catalog.automaticTarget == .tag("ja"))
    }
}
