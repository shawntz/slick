import Foundation
import Kit
import Testing

@Suite("ItemID")
struct ItemIDTests {
    /// Shared with the Rust core: slick-engine must produce exactly these keys for these strings.
    nonisolated static let vectors: [(input: String, key: UInt64)] = [
        ("", 0xcbf2_9ce4_8422_2325),
        ("a", 0xaf63_dc4c_8601_ec8c),
        ("foobar", 0x8594_4171_f739_67e8),
        ("app:com.apple.Safari", 0xf82a_fb44_2d1d_fb25),
        ("cmd:clipboard.history", 0x9f29_1e7a_a76b_7161),
        ("file:/tmp/example.txt", 0x2766_23fb_da38_72be),
        ("emoji:😀", 0x505d_6c3e_8fb1_44a8),
        ("cmd:window-management.left-half", 0x04b2_47fb_f261_7b9a),
    ]

    @Test(arguments: zip(vectors.map(\.input), vectors.map(\.key)))
    func fnv1aMatchesTheSharedVectors(input: String, key: UInt64) {
        #expect(FNV1a.hash64(input) == key)
        #expect(FNV1a.hash64(bytes: Array(input.utf8)) == key)
    }

    @Test func engineKeyIsTheHashOfTheRawValue() {
        let id = ItemID("app", "com.apple.Safari")
        #expect(id.rawValue == "app:com.apple.Safari")
        #expect(id.engineKey == 0xf82a_fb44_2d1d_fb25)
    }

    @Test func splitsAtTheFirstColon() throws {
        let id = try #require(ItemID(rawValue: "file:/tmp/a:b.txt"))
        #expect(id.namespace == "file")
        #expect(id.key == "/tmp/a:b.txt")
        #expect(id == ItemID("file", "/tmp/a:b.txt"))
    }

    @Test(arguments: ["no-colon", ":key", "App:x", "1app:x", "na me:x", "\(String(repeating: "a", count: 33)):x"])
    func rejectsInvalidNamespaces(raw: String) {
        #expect(ItemID(rawValue: raw) == nil)
    }

    @Test func acceptsNamespacesWithDigitsDotsAndHyphens() {
        #expect(ItemID(rawValue: "my-feature.v2:item") != nil)
        #expect(ItemID.isValidNamespace("a"))
        #expect(!ItemID.isValidNamespace(""))
    }

    @Test func codesAsAPlainString() throws {
        let id = ItemID("emoji", "😀")
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"emoji:😀\"]")
        #expect(try JSONDecoder().decode([ItemID].self, from: data) == [id])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([ItemID].self, from: Data("[\"nope\"]".utf8)) }
    }

    @Test func commandIDsFollowTheRootConvention() {
        #expect(ItemID.command(feature: "clipboard", command: "history").rawValue == "cmd:clipboard.history")
    }
}
