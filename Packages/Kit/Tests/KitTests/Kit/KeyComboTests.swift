import Foundation
import Kit
import Testing

@Suite("KeyCombo")
struct KeyComboTests {
    @Test(
        arguments: [
            ("cmd+shift+k", "shift+cmd+k"),
            ("Command-Shift-K", "shift+cmd+k"),
            ("ctrl opt space", "ctrl+opt+space"),
            ("⌘⇧K", "shift+cmd+k"),
            ("⌥↩", "opt+return"),
            ("cmd+-", "cmd+-"),
            ("cmd--", "cmd+-"),
            ("alt+F5", "opt+f5"),
            ("fn+ctrl+left", "fn+ctrl+left"),
            ("hyper", nil),
            ("cmd+", nil),
            ("cmd+shift", nil),
            ("", nil),
        ] as [(String, String?)])
    func parsesTheFormsPeopleWrite(text: String, canonical: String?) {
        #expect(KeyCombo(parsing: text)?.description == canonical)
    }

    @Test func displaysLikeAMenu() {
        #expect(KeyCombo(.k, [.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘K")
        #expect(KeyCombo(.return, .command).displayString == "⌘↩")
        #expect(KeyCombo(.space, .option).displayString == "⌥Space")
    }

    @Test func modifierBitsMatchAppKit() {
        // NSEvent.ModifierFlags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20, function 1<<23.
        #expect(KeyModifiers.shift.rawValue == 131_072)
        #expect(KeyModifiers.control.rawValue == 262_144)
        #expect(KeyModifiers.option.rawValue == 524_288)
        #expect(KeyModifiers.command.rawValue == 1_048_576)
        #expect(KeyModifiers.function.rawValue == 8_388_608)
    }

    @Test func keyCodesAreVirtualKeyCodes() {
        #expect(Key.a.code == 0x00)
        #expect(Key.return.code == 0x24)
        #expect(Key(name: "f18")?.code == 0x4F)
        #expect(Key(name: "esc") == .escape)
        #expect(Key(code: 0xFF).name == "key255")
    }

    @Test func codesAsCanonicalText() throws {
        let combo = KeyCombo(.space, [.option, .command])
        let data = try JSONEncoder().encode([combo])
        #expect(String(decoding: data, as: UTF8.self) == "[\"opt+cmd+space\"]")
        #expect(try JSONDecoder().decode([KeyCombo].self, from: data) == [combo])
    }

    @Test func roundTripsEveryNamedKey() throws {
        for code in UInt16(0)...0x7F {
            let key = Key(code: code)
            guard !key.name.hasPrefix("key") else { continue }
            let combo = KeyCombo(key, [.control, .shift])
            #expect(KeyCombo(parsing: combo.description) == combo, "\(combo)")
        }
    }
}
