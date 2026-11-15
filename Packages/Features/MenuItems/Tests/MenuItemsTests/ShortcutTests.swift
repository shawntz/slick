import Kit
import Testing

@testable import MenuItems

/// The pure function from shortcut attributes to a Kit key combination.
@Suite("Shortcut attributes", .timeLimit(.minutes(1)))
struct ShortcutTests {
    func combo(
        _ character: String? = nil, virtualKey: Int? = nil, glyph: Int? = nil, modifiers: Int? = nil
    ) -> KeyCombo? {
        MenuShortcut.combo(
            ShortcutAttributes(character: character, virtualKey: virtualKey, glyph: glyph, modifiers: modifiers))
    }

    @Test func aLetterWithNoMaskIsCommandAndTheLetter() {
        #expect(combo("S", modifiers: 0) == KeyCombo(.s, .command))
        #expect(combo("S", modifiers: 0)?.displayString == "⌘S")
        #expect(combo("s", modifiers: 0) == KeyCombo(.s, .command), "case means nothing; the mask says Shift")
        #expect(combo("S") == KeyCombo(.s, .command), "a missing mask is Command alone")
    }

    @Test func eachMaskBitAddsItsModifier() {
        #expect(MenuShortcut.modifiers(0) == [.command])
        #expect(MenuShortcut.modifiers(MenuShortcut.shiftBit) == [.shift, .command])
        #expect(MenuShortcut.modifiers(MenuShortcut.optionBit) == [.option, .command])
        #expect(MenuShortcut.modifiers(MenuShortcut.controlBit) == [.control, .command])
        #expect(MenuShortcut.modifiers(MenuShortcut.noCommandBit) == [])
        #expect(MenuShortcut.modifiers(MenuShortcut.functionBit) == [.function, .command])
        #expect(MenuShortcut.modifiers(0b0_0111) == [.shift, .option, .control, .command])
        #expect(MenuShortcut.modifiers(0b1_1111) == [.shift, .option, .control, .function])
        #expect(combo("Z", modifiers: MenuShortcut.shiftBit)?.displayString == "⇧⌘Z")
        #expect(combo("V", modifiers: MenuShortcut.optionBit | MenuShortcut.shiftBit)?.displayString == "⌥⇧⌘V")
        #expect(combo("Q", modifiers: MenuShortcut.controlBit)?.displayString == "⌃⌘Q")
    }

    @Test func itemsWithNoModifiersAtAll() {
        #expect(combo("A", modifiers: MenuShortcut.noCommandBit) == KeyCombo(.a))
        #expect(combo(glyph: 0x73, modifiers: MenuShortcut.noCommandBit) == KeyCombo(Key(code: 0x60)), "F5 alone")
        #expect(combo(glyph: 0x73, modifiers: MenuShortcut.noCommandBit)?.displayString == "F5")
        #expect(combo(glyph: 0x17, modifiers: MenuShortcut.noCommandBit) == KeyCombo(.delete), "Delete alone")
        #expect(combo("\u{1B}", modifiers: MenuShortcut.noCommandBit) == KeyCombo(.escape))
    }

    @Test func theFunctionKey() {
        let fullScreen = combo("F", modifiers: MenuShortcut.functionBit | MenuShortcut.noCommandBit)
        #expect(fullScreen == KeyCombo(.f, .function))
        #expect(fullScreen?.displayString == "fnF")
        let tile = combo(
            glyph: 0x64, modifiers: MenuShortcut.functionBit | MenuShortcut.controlBit | MenuShortcut.noCommandBit)
        #expect(tile == KeyCombo(.leftArrow, [.function, .control]))
        #expect(combo("E", modifiers: MenuShortcut.functionBit) == KeyCombo(.e, [.function, .command]))
        #expect(
            combo(glyph: 0x6F, modifiers: MenuShortcut.noCommandBit) == KeyCombo(Key(code: 0x7A)),
            "an F key alone gets no Function modifier of its own")
    }

    @Test func glyphsForKeysWithoutACharacter() {
        let cases: [(glyph: Int, key: Key)] = [
            (0x02, .tab), (0x04, Key(code: 0x4C)), (0x09, .space), (0x0A, .forwardDelete), (0x0B, .return),
            (0x0D, .return), (0x17, .delete), (0x1B, .escape), (0x62, Key(code: 0x74)), (0x6B, Key(code: 0x79)),
            (0x64, .leftArrow), (0x65, .rightArrow), (0x68, .upArrow), (0x6A, .downArrow), (0x66, Key(code: 0x73)),
            (0x69, Key(code: 0x77)), (0x6F, Key(code: 0x7A)), (0x7A, Key(code: 0x6F)), (0x87, Key(code: 0x69)),
            (0x89, Key(code: 0x71)), (0x8F, Key(code: 0x6A)), (0x92, Key(code: 0x50)),
        ]
        for (glyph, key) in cases {
            #expect(combo(glyph: glyph, modifiers: 0) == KeyCombo(key, .command), "glyph \(glyph)")
        }
        #expect(combo(glyph: 0x6F, modifiers: 0)?.displayString == "⌘F1")
        #expect(combo(glyph: 0x7A, modifiers: 0)?.displayString == "⌘F12")
        #expect(combo(glyph: 0x92, modifiers: 0)?.displayString == "⌘F19")
        #expect(
            combo(glyph: 0x64, modifiers: MenuShortcut.controlBit | MenuShortcut.optionBit)?.displayString == "⌃⌥⌘←")
    }

    @Test func theGlyphWinsOverTheCharacter() {
        #expect(combo("x", glyph: 0x68, modifiers: 0) == KeyCombo(.upArrow, .command))
        #expect(combo("E", glyph: 0x8C, modifiers: 0) == KeyCombo(.e, .command), "an unknown glyph falls back")
        #expect(combo(glyph: 0x8C, modifiers: 0) == nil, "the Eject glyph has no key")
        #expect(combo(glyph: 0, modifiers: 0) == nil)
    }

    @Test func shiftedSymbolsBecomeTheirKeyWithShift() {
        #expect(combo("?", modifiers: 0) == KeyCombo(Key(name: "/")!, [.shift, .command]))
        #expect(combo("?", modifiers: 0)?.displayString == "⇧⌘/")
        #expect(combo("+", modifiers: 0) == KeyCombo(Key(name: "=")!, [.shift, .command]))
        #expect(
            combo("{", modifiers: MenuShortcut.optionBit) == KeyCombo(Key(name: "[")!, [.shift, .option, .command]))
        #expect(combo("!", modifiers: 0) == KeyCombo(Key(name: "1")!, [.shift, .command]))
        #expect(combo("+", modifiers: MenuShortcut.shiftBit) == KeyCombo(Key(name: "=")!, [.shift, .command]))
    }

    @Test func plainSymbolsAndDigits() {
        #expect(combo(",", modifiers: 0) == KeyCombo(.comma, .command))
        #expect(combo("-", modifiers: 0) == KeyCombo(Key(name: "-")!, .command))
        #expect(combo("=", modifiers: 0) == KeyCombo(Key(name: "=")!, .command))
        #expect(combo("`", modifiers: 0) == KeyCombo(Key(name: "`")!, .command))
        #expect(combo("[", modifiers: MenuShortcut.shiftBit) == KeyCombo(Key(name: "[")!, [.shift, .command]))
        #expect(combo("0", modifiers: 0) == KeyCombo(Key(name: "0")!, .command))
        #expect(combo("9", modifiers: MenuShortcut.optionBit) == KeyCombo(Key(name: "9")!, [.option, .command]))
        #expect(combo(" ", modifiers: MenuShortcut.controlBit) == KeyCombo(.space, [.control, .command]))
    }

    @Test func controlAndFunctionKeyCharacters() {
        #expect(combo("\r", modifiers: 0) == KeyCombo(.return, .command))
        #expect(combo("\u{3}", modifiers: 0) == KeyCombo(Key(code: 0x4C), .command))
        #expect(combo("\t", modifiers: MenuShortcut.controlBit) == KeyCombo(.tab, [.control, .command]))
        #expect(combo("\u{7F}", modifiers: 0) == KeyCombo(.delete, .command))
        #expect(combo("\u{8}", modifiers: 0) == KeyCombo(.delete, .command))
        #expect(combo("\u{F700}", modifiers: 0) == KeyCombo(.upArrow, .command))
        #expect(combo("\u{F703}", modifiers: 0) == KeyCombo(.rightArrow, .command))
        #expect(combo("\u{F704}", modifiers: MenuShortcut.noCommandBit) == KeyCombo(Key(code: 0x7A)))
        #expect(combo("\u{F717}", modifiers: MenuShortcut.noCommandBit)?.displayString == "F20")
        #expect(combo("\u{F728}", modifiers: 0) == KeyCombo(.forwardDelete, .command))
        #expect(combo("\u{F729}", modifiers: 0) == KeyCombo(Key(code: 0x73), .command))
    }

    @Test func keycapSymbolsAndNamesSomeAppsReport() {
        #expect(combo("↩", modifiers: 0) == KeyCombo(.return, .command))
        #expect(combo("⌫", modifiers: 0) == KeyCombo(.delete, .command))
        #expect(combo("F5", modifiers: MenuShortcut.noCommandBit) == KeyCombo(Key(code: 0x60)))
    }

    @Test func theVirtualKeyFillsInWhatTheCharacterCannot() {
        #expect(combo(virtualKey: 0x31, modifiers: 0) == KeyCombo(.space, .command))
        #expect(combo(virtualKey: 0x7A, modifiers: MenuShortcut.noCommandBit) == KeyCombo(Key(code: 0x7A)))
        #expect(combo(virtualKey: 0, modifiers: 0) == nil, "no character and code 0: no shortcut")
        #expect(combo("ß", virtualKey: 0x1B, modifiers: 0) == KeyCombo(Key(name: "-")!, .command))
        #expect(combo("ß", virtualKey: 0, modifiers: 0) == KeyCombo(.a, .command), "with a character, 0 is A")
        #expect(combo("ß", modifiers: 0) == nil, "a character the US layout cannot place")
        #expect(combo(virtualKey: 0x47, modifiers: 0) == nil, "a code Kit cannot draw")
        #expect(combo(virtualKey: 400, modifiers: 0) == nil)
        #expect(combo("K", virtualKey: 0x00, modifiers: 0) == KeyCombo(.k, .command), "the character wins")
    }

    @Test func noShortcut() {
        #expect(combo() == nil)
        #expect(combo(modifiers: 0) == nil, "a mask alone is no shortcut")
        #expect(combo("", modifiers: 0) == nil)
        #expect(combo("", glyph: 0, modifiers: MenuShortcut.noCommandBit) == nil)
        #expect(combo("é", modifiers: 0) == nil)
        #expect(combo("😀", modifiers: 0) == nil)
        #expect(combo("AB", modifiers: 0) == nil)
    }
}
