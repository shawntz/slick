import Foundation
import Kit
import KitHosting
import Testing

@testable import Updates

/// When Sparkle's updater may exist. The step that would build it is passed in and only counts its
/// calls, so no Sparkle object is ever made here.
@Suite(.timeLimit(.minutes(1))) struct UpdatesFactoryTests {
    /// A made-up public key: base64 of 32 bytes.
    static let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
    static let feed = "https://example.com/owner/app/releases/latest/download/appcast.xml"
    static let releaseInfo: [String: Any] = [
        UpdateConfiguration.feedKey: feed, UpdateConfiguration.publicKeyKey: publicKey,
    ]

    /// Counts how often the factory asks for the real updater, and hands back a stand-in.
    final class Builder {
        private(set) var built: [UpdateConfiguration] = []

        func build(_ configuration: UpdateConfiguration) -> any UpdateControl {
            built.append(configuration)
            return StandIn()
        }
    }

    final class StandIn: UpdateControl {
        let changes = ChangeSignal()
        var isAvailable: Bool { true }
        var checksAutomatically: Bool { false }
        func setChecksAutomatically(_ enabled: Bool) {}
        var lastCheck: Date? { nil }
        var waitingVersion: String? { nil }
        var canCheckNow: Bool { true }
        func checkNow() {}
    }

    @Test(arguments: RunEnvironment.allCases.filter { $0 != .live })
    func noModeButTheLiveLauncherBuildsTheRealUpdater(environment: RunEnvironment) {
        let builder = Builder()
        let updates = Updates.make(environment: environment, info: Self.releaseInfo, build: builder.build)
        #expect(updates is NoUpdates)
        #expect(builder.built.isEmpty, "\(environment) must never build Sparkle's updater")
    }

    @Test func theLiveLauncherFromAReleaseBundleBuildsItOnce() {
        let builder = Builder()
        let updates = Updates.make(environment: .live, info: Self.releaseInfo, build: builder.build)
        #expect(updates is StandIn)
        #expect(builder.built.map(\.feed.absoluteString) == [Self.feed])
        #expect(builder.built.map(\.publicKey) == [Self.publicKey])
    }

    @Test func aBundleWithoutTheFeedGetsTheDoNothingUpdater() {
        let builder = Builder()
        var info = Self.releaseInfo
        info[UpdateConfiguration.feedKey] = nil
        #expect(Updates.make(environment: .live, info: info, build: builder.build) is NoUpdates)
        info = Self.releaseInfo
        info[UpdateConfiguration.publicKeyKey] = nil
        #expect(Updates.make(environment: .live, info: info, build: builder.build) is NoUpdates)
        #expect(Updates.make(environment: .live, info: [:], build: builder.build) is NoUpdates)
        #expect(builder.built.isEmpty)
    }

    /// The test runner's own bundle carries no feed, as a build from source does not, so the public
    /// entry point gives the do-nothing updater even when asked for the live launcher.
    @Test func theTestRunnersBundleGetsTheDoNothingUpdaterInEveryEnvironment() throws {
        // Stop before the loop if the runner ever carried a feed, so no Sparkle object can be made.
        try #require(UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) == nil)
        for environment in RunEnvironment.allCases {
            #expect(Updates.make(environment: environment, bundle: .main) { true } is NoUpdates)
        }
    }
}
