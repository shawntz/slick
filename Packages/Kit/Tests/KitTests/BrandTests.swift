import Kit
import Testing

/// Guards a rename: each value must keep the shape the build, macOS and URL handling rely on. The
/// tests never repeat the values themselves, so renaming the product does not touch them.
@Suite("Brand")
struct BrandTests {
    @Test func nameIsOneWord() {
        // make and the scripts use the name in file paths and target names.
        #expect(!Brand.name.isEmpty)
        #expect(!Brand.name.contains { $0.isWhitespace })
        #expect(!Brand.name.contains("/"))
    }

    @Test func bundleIDIsReverseDNS() {
        let parts = Brand.bundleID.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count >= 3)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        for part in parts {
            #expect(!part.isEmpty)
            #expect(
                part.allSatisfy { allowed.contains($0) }, "bundle ID part \"\(part)\" has a character macOS rejects")
        }
    }

    @Test func dataDirectoryIsOneFolder() {
        #expect(!Brand.dataDirectoryName.isEmpty)
        #expect(!Brand.dataDirectoryName.contains("/"))
        #expect(!Brand.dataDirectoryName.hasPrefix("."))
    }

    @Test func urlSchemeIsValid() {
        // RFC 3986: a letter, then letters, digits, "+", "-" or ".". Lowercase avoids surprises in
        // case-sensitive comparisons.
        let scheme = Brand.urlScheme
        let first = scheme.first
        #expect(first?.isLetter == true && first?.isASCII == true)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789+-.")
        #expect(scheme.allSatisfy { allowed.contains($0) })
    }
}
