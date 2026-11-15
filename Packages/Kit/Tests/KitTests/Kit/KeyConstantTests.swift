import Kit
import Testing

@Suite("Key constants", .timeLimit(.minutes(1)))
struct KeyConstantTests {
    /// The codes are `kVK_ANSI_0` to `kVK_ANSI_9` from Carbon's Events.h.
    @Test func digitsAreTheirVirtualKeyCodes() {
        let digits: [Key] = [.zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
        #expect(digits.map(\.code) == [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19])
        #expect(digits.map(\.name) == (0...9).map(String.init))
    }

    @Test func minusAndEqualAreTheirVirtualKeyCodes() {
        #expect(Key.minus.code == 0x1B)
        #expect(Key.equal.code == 0x18)
        #expect(Key(name: "minus") == .minus)
        #expect(Key(name: "=") == .equal)
    }

    @Test func combinationsShowAsMenusDo() {
        #expect(KeyCombo(.minus, [.control, .option]).displayString == "⌃⌥-")
        #expect(KeyCombo(.equal, [.control, .option]).displayString == "⌃⌥=")
        #expect(KeyCombo(.one, .command).displayString == "⌘1")
        #expect(KeyCombo(parsing: "cmd+9") == KeyCombo(.nine, .command))
    }
}
