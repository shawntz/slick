import CoreText
import Foundation
import Testing

@testable import Emoji

@Suite("Generated data", .timeLimit(.minutes(1)))
struct DataTests {
    let entries = bundledCatalog.entries

    @Test func everyLineParsesIntoTheExpectedGroups() throws {
        let catalog = try EmojiCatalog.parse(EmojiData.text)
        let emoji = catalog.entries.filter(\.group.isEmoji)
        let symbols = catalog.entries.filter { !$0.group.isEmoji }
        #expect((1_850...2_000).contains(emoji.count), "about 1,900 emoji without skin tone variants")
        #expect((500...800).contains(symbols.count), "a smaller set of symbols")
        for group in EmojiGroup.allCases {
            #expect(catalog.entries.contains { $0.group == group }, "group \(group) is empty")
        }
        let groups = catalog.entries.map(\.group.rawValue)
        #expect(groups == groups.sorted(), "entries come in the order of the grid")
    }

    @Test func keysAreUniqueAndIgnoreVariationSelectors() throws {
        #expect(Set(entries.map(\.key)).count == entries.count)
        #expect(try entry("👍").key == "1f44d")
        #expect(try entry("❤️").key == "2764")
        #expect(try entry("🧑‍💻").key == "1f9d1-200d-1f4bb")
        #expect(try entry("#️⃣").key == "23-20e3")
    }

    @Test func nothingIsNewerThanWhatMacOS26Draws() throws {
        #expect(EmojiData.newestEmojiVersion == "16.0")
        for entry in entries where entry.group.isEmoji {
            let parts = entry.version.split(separator: ".").compactMap { Int($0) }
            #expect(parts.count == 2, "\(entry.name) has version \(entry.version)")
            #expect((parts.first ?? 99, parts.last ?? 99) <= (16, 0), "\(entry.name) is from Emoji \(entry.version)")
        }
        #expect(try entry("🫩").version == "16.0", "Emoji 16.0 is in")
        #expect(bundledCatalog.entry(forKey: EmojiEntry.key(for: "🫪")) == nil, "Emoji 17.0 is out")
        #expect(entries.allSatisfy { $0.group.isEmoji || $0.version.isEmpty })
    }

    @Test func knownEmoji() throws {
        let grinning = try entry("😀")
        #expect(grinning.name == "Grinning Face")
        #expect(grinning.group == .smileys)
        #expect(grinning.version == "1.0")
        #expect(grinning.keywords.contains("smile"))
        #expect(grinning.skinTones == .none)

        let thumbs = try entry("👍")
        #expect(thumbs.name == "Thumbs Up")
        #expect(thumbs.group == .people)
        #expect(thumbs.variants == ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        #expect(thumbs.commonRank > 0)

        let flag = try entry("🇺🇸")
        #expect(flag.name == "Flag: United States")
        #expect(flag.group == .flags)

        #expect(try entry("😂").name == "Face with Tears of Joy")
        #expect(try entry("🧑‍💻").name == "Technologist")
        #expect(try entry("🧑‍💻").skinTones == .onePerson)
    }

    @Test func multiPersonEmojiCarryTwentyFiveVariants() throws {
        let holding = try entry("🧑‍🤝‍🧑")
        #expect(holding.skinTones == .twoPeople)
        #expect(holding.variants[0] == "🧑🏻‍🤝‍🧑🏻")
        #expect(holding.variants[12] == "🧑🏽‍🤝‍🧑🏽")
        #expect(holding.variants[4] == "🧑🏻‍🤝‍🧑🏿", "light then dark")

        // The uniform tones of these use the base code point with one modifier; the mixed ones are
        // other sequences.
        let handshake = try entry("🤝")
        #expect(handshake.skinTones == .twoPeople)
        #expect(handshake.variants[12] == "🤝🏽")
        #expect(handshake.variants[4] == "🫱🏻‍🫲🏿")
        let kiss = try entry("💏")
        #expect(kiss.variants[24] == "💏🏿")
        #expect(kiss.variants[1] == "🧑🏻‍❤️‍💋‍🧑🏼")
    }

    @Test func everyVariantCarriesItsTones() {
        let modifiers: [UInt32] = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
        for entry in entries {
            for (index, variant) in entry.variants.enumerated() {
                let found = variant.unicodeScalars.map(\.value).filter(modifiers.contains)
                switch entry.skinTones {
                case .onePerson:
                    #expect(found == [modifiers[index]], "\(entry.name) variant \(index)")
                case .twoPeople:
                    let first = modifiers[index / 5]
                    let second = modifiers[index % 5]
                    #expect(
                        found == [first, second] || (first == second && found == [first]), "\(entry.name) \(index)")
                case .none:
                    Issue.record("\(entry.name) has variants but no skin tones")
                }
            }
        }
    }

    @Test func knownSymbols() throws {
        #expect(try entry("→").group == .arrows)
        #expect(try entry("→").keywords.contains("rightwards arrow"))
        #expect(try entry("€").name == "Euro")
        #expect(try entry("€").group == .currency)
        #expect(try entry("⌘").name == "Command Key")
        #expect(try entry("⌘").group == .keyboard)
        #expect(try entry("⇧").group == .keyboard, "a keyboard symbol is not also an arrow")
        #expect(try entry("α").group == .greek)
        #expect(try entry("─").group == .boxDrawing)
        #expect(try entry("±").group == .math)
        #expect(try entry("…").group == .punctuation)
        #expect(try entry("★").group == .shapes)
    }

    @Test func symbolsAreSingleCharactersThatAreNotEmoji() {
        let emojiKeys = Set(entries.filter(\.group.isEmoji).map(\.key))
        for entry in entries where !entry.group.isEmoji {
            #expect(entry.glyph.unicodeScalars.count == 1, "\(entry.name)")
            #expect(!emojiKeys.contains(entry.key), "\(entry.name) is also an emoji")
            #expect(entry.variants.isEmpty)
        }
    }

    @Test func namesAndKeywordsAreClean() {
        for entry in entries {
            #expect(!entry.name.isEmpty && entry.name == entry.name.trimmingCharacters(in: .whitespaces))
            #expect(entry.name.first?.isLowercase != true, "\(entry.name) starts in lowercase")
            for keyword in entry.keywords {
                #expect(!keyword.isEmpty && keyword == keyword.lowercased(), "\(entry.name): \(keyword)")
                #expect(keyword != entry.name.lowercased(), "\(entry.name) repeats its name as a keyword")
            }
        }
    }

    @Test func malformedDataIsRejectedWithItsLine() {
        #expect(throws: EmojiDataError(line: 2)) {
            try EmojiCatalog.parse("😀;Grinning Face;0;1.0;0;smile;\n👍;Thumbs Up;99;0.6;0;;")
        }
        #expect(throws: EmojiDataError(line: 1)) { try EmojiCatalog.parse("👍;Thumbs Up;1;0.6;0;;👍🏻 👍🏼") }
    }

    /// Measures every emoji and every skin tone variant with the system font. One drawn glyph from
    /// Apple Color Emoji means the system has it; an unsupported sequence falls apart into several
    /// glyphs, and an unknown character falls back to the LastResort font.
    @Test func everyEmojiDrawsAsOneGlyphInTheSystemFont() {
        var checked = 0
        for entry in entries where entry.group.isEmoji {
            for glyph in [entry.glyph] + entry.variants {
                let drawn = Self.drawnGlyphs(glyph)
                #expect(drawn.count == 1 && drawn.fonts.allSatisfy { $0.contains("AppleColorEmoji") }, "\(entry.name)")
                checked += 1
            }
        }
        #expect(checked > 3_500)
    }

    @Test func everySymbolHasAFontThatDrawsIt() {
        for entry in entries where !entry.group.isEmoji {
            let drawn = Self.drawnGlyphs(entry.glyph)
            #expect(drawn.count == 1 && !drawn.fonts.contains("LastResort"), "\(entry.name) U+\(entry.key)")
        }
    }

    /// The glyphs with an advance that the system font draws for a string, and their fonts.
    static func drawnGlyphs(_ text: String) -> (count: Int, fonts: [String]) {
        guard let font = CTFontCreateUIFontForLanguage(.system, 16, nil) else { return (0, []) }
        let attributed = NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return (0, []) }
        var count = 0
        var fonts: [String] = []
        for run in runs {
            let glyphs = CTRunGetGlyphCount(run)
            var advances = [CGSize](repeating: .zero, count: glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: glyphs), &advances)
            count += advances.count { $0.width > 0.01 }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
                fonts.append(CTFontCopyPostScriptName(value as! CTFont) as String)
            }
        }
        return (count, fonts)
    }
}
