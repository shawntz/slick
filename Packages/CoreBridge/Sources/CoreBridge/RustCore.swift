import SlickCoreC

/// The parts of the Rust core's C ABI that belong to no single area.
public enum RustCore {
    /// The ABI version of the C header this package was compiled against.
    public static let expectedABIVersion = UInt32(SLICK_ABI_VERSION)

    /// The ABI version of the static library that is actually linked. When it differs from
    /// `expectedABIVersion`, the library is stale: run `make core`.
    public static var abiVersion: UInt32 { slick_abi_version() }

    /// Throws `CoreError.abiMismatch` when the linked library does not match the header.
    public static func checkABI() throws(CoreError) {
        let linked = abiVersion
        guard linked == expectedABIVersion else {
            throw .abiMismatch(expected: expectedABIVersion, linked: linked)
        }
    }

    /// Calls the Rust no-op. It proves that the static library is linked and callable.
    public static func noop() throws(CoreError) {
        try CoreError.check(slick_noop())
    }
}
