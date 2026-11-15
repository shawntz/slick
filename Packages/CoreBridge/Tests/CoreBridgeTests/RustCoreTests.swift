import SlickCoreC
import Testing

@testable import CoreBridge

@Suite("Rust core")
struct RustCoreTests {
    @Test func linkedLibraryMatchesTheHeader() throws {
        #expect(RustCore.abiVersion == RustCore.expectedABIVersion)
        try RustCore.checkABI()
    }

    @Test func noopSucceeds() throws {
        try RustCore.noop()
    }

    @Test func aRustPanicComesBackAsAStatus() {
        let status = slick_debug_panic()
        #expect(status == SLICK_STATUS_PANIC.rawValue)
        #expect(throws: CoreError.panic) { try CoreError.check(status) }
        // The process is still alive and the library still works.
        #expect(slick_noop() == SLICK_STATUS_OK.rawValue)
    }

    @Test(arguments: [0, 1, 42])
    func nonNegativeStatusIsReturned(status: Int32) throws {
        #expect(try CoreError.check(status) == status)
    }

    @Test(arguments: [
        (Int32(-1), CoreError.nullPointer),
        (-2, .invalidUTF8),
        (-3, .panic),
        (-4, .poisoned),
        (-5, .invalidArgument),
        (-6, .bufferTooSmall),
        (-7, .io),
        (-99, .unknown(-99)),
    ])
    func negativeStatusThrows(status: Int32, error: CoreError) {
        #expect(throws: error) { try CoreError.check(status) }
    }
}

@Suite("Item keys")
struct ItemKeyTests {
    @Test func theHeaderTestVectorHolds() {
        #expect(ItemKey(id: "app:com.example.Editor").rawValue == SLICK_KEY_TEST_VALUE)
        #expect(ItemKey(id: "").rawValue == 0xcbf2_9ce4_8422_2325)
        #expect(ItemKey(id: "a").rawValue == 0xaf63_dc4c_8601_ec8c)
    }
}
