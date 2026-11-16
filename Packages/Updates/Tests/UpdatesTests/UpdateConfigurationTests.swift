import Foundation
import Testing

@testable import Updates

/// What an Info.plist must carry before the live launcher gets an updater.
@Suite(.timeLimit(.minutes(1))) struct UpdateConfigurationTests {
    private static let key = UpdatesFactoryTests.publicKey
    private static let feed = UpdatesFactoryTests.feed

    @Test func readsAnHTTPSFeedAndAThirtyTwoBytePublicKey() throws {
        let configuration = try #require(
            UpdateConfiguration(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key]))
        #expect(configuration.feed.absoluteString == Self.feed)
        #expect(configuration.publicKey == Self.key)
    }

    @Test func usesSparklesOwnInfoPlistKeys() {
        #expect(UpdateConfiguration.feedKey == "SUFeedURL")
        #expect(UpdateConfiguration.publicKeyKey == "SUPublicEDKey")
    }

    @Test(arguments: [
        "http://example.com/appcast.xml",
        "file:///tmp/appcast.xml",
        "https://",
        "not a link",
        "",
    ])
    func refusesAFeedThatIsNotHTTPS(feed: String) {
        #expect(UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": Self.key]) == nil)
    }

    @Test func refusesAMissingEmptyOrMalformedKey() {
        let short = Data(repeating: 1, count: 31).base64EncodedString()
        let long = Data(repeating: 1, count: 64).base64EncodedString()
        for key in ["", "not base64!", short, long] {
            #expect(UpdateConfiguration(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": key]) == nil, "\(key)")
        }
        #expect(UpdateConfiguration(info: ["SUFeedURL": Self.feed]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": 32]) == nil)
    }
}
