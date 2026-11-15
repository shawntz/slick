import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("The web address detector", .timeLimit(.minutes(1)))
struct AddressDetectorTests {
    /// Text that is an address, and the link it opens.
    nonisolated static let addresses: [(String, String)] = [
        ("example.com", "https://example.com"),
        ("Example.COM", "https://example.com"),
        ("www.example.com", "https://www.example.com"),
        ("docs.example.co.uk/guide?x=1#top", "https://docs.example.co.uk/guide?x=1#top"),
        ("example.org/", "https://example.org/"),
        ("example.io", "https://example.io"),
        ("example.dev", "https://example.dev"),
        ("example.ai", "https://example.ai"),
        ("xn--bcher-kva.de", "https://xn--bcher-kva.de"),
        ("sub-domain.example.de/a%20b", "https://sub-domain.example.de/a%20b"),
        ("  example.com  ", "https://example.com"),
        ("example.com:8080", "http://example.com:8080"),
        ("example.com:443/x", "https://example.com:443/x"),
        ("https://example.com", "https://example.com"),
        ("HTTP://Example.com/Path", "http://example.com/Path"),
        ("https://intranet/wiki", "https://intranet/wiki"),
        ("https://hello.world", "https://hello.world"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost/admin", "http://localhost/admin"),
        ("http://localhost", "http://localhost"),
        ("printer.local", "http://printer.local"),
        ("app.localhost:5173", "http://app.localhost:5173"),
        ("127.0.0.1", "http://127.0.0.1"),
        ("192.168.1.20:8080/status", "http://192.168.1.20:8080/status"),
        ("10.0.0.1", "http://10.0.0.1"),
        ("172.20.1.1", "http://172.20.1.1"),
        ("8.8.8.8/", "http://8.8.8.8/"),
        ("www.notes.md", "https://www.notes.md"),
        ("notes.md/today", "https://notes.md/today"),
        ("tool.app:8000", "http://tool.app:8000"),
    ]

    /// Text that is not an address: words, files, versions, times, e-mail and other schemes.
    nonisolated static let notAddresses: [String] = [
        "", " ", "safari", "calculator", "hello world", "example", "localhost",
        "README.md", "setup.py", "main.rs", "install.sh", "Safari.app", "Makefile.am", "notes.pl",
        "node.js", "vue.js", "hello.world", "user.name", "photo.jpeg", "archive.zip", "movie.mov",
        "1.5", "3.14", "1.2.3.4.5", "v1.2.3", "2026.11.15", "999.1.1.1", "8.8.8.8", "01.2.3.4",
        "10:30", "12:00pm", "3:2", "e.g.", "i.e.", "U.S.A", "a.b", "Ph.D",
        "example.com.", ".example.com", "example..com", "-example.com", "example-.com", "exa_mple.com",
        "example.com/a b", "example.com/<script>", "example.com/%zz", "example.com/%2",
        "bücher.de", "例え.jp", "user@example.com", "https://bank.example@evil.example",
        "mailto:a@example.com", "javascript:alert(1)", "file:///etc/hosts", "ftp://example.com",
        "x-example-app://open", "data:text/html,hi", "localhost:0", "localhost:99999", "localhost:abc",
        "https://", "http://[::1]:8080", "cmd:apps.running", "=1+2", "2 + 2 = 4",
        String(repeating: "a", count: 3000) + ".com",
    ]

    @Test("Addresses open the right link", arguments: addresses)
    func address(text: String, link: String) throws {
        let address = try #require(AddressDetector.detect(text), "\(text) should be an address")
        #expect(address.url.absoluteString == link)
    }

    @Test("Words, files, versions and other schemes are not addresses", arguments: notAddresses)
    func notAddress(text: String) {
        #expect(AddressDetector.detect(text) == nil, "\(text.prefix(40)) should not be an address")
    }

    @Test func theHostIsLowercasedForTheIcon() throws {
        #expect(try #require(AddressDetector.detect("Docs.Example.COM/Page")).host == "docs.example.com")
    }

    @MainActor
    @Test func theProviderClaimsTheTopWithOneRowThatRootDoesNotKeep() async throws {
        let quicklinks = try await QuicklinksHarness()
        let answers = quicklinks.harness.instantAnswers(for: "docs.example.com/guide")
        let answer = try #require(answers.first)
        #expect(answer.claimsTop)
        let row = try #require(answer.rows.first)
        #expect(row.id.rawValue == "web-address:https://docs.example.com/guide")
        #expect(row.title == "Open docs.example.com/guide")
        #expect(row.icon == .favicon(domain: "docs.example.com"))
        #expect(row.memory == .never)
        #expect(row.represents == .url(try #require(URL(string: "https://docs.example.com/guide"))))
        #expect(quicklinks.harness.instantAnswers(for: "documents").isEmpty)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @MainActor
    @Test func turningTheSettingOffRemovesTheProvider() async throws {
        let quicklinks = try await QuicklinksHarness()
        let signal = quicklinks.feature.changes.generation
        quicklinks.harness.context.settings[QuicklinksSettings.detectsAddresses] = false
        try await quicklinks.harness.settle()
        #expect(quicklinks.feature.changes.generation > signal, "the host reads the declarations again")
        #expect(quicklinks.feature.liveProviders.isEmpty)
        #expect(quicklinks.harness.instantAnswers(for: "example.com").isEmpty)
    }
}
