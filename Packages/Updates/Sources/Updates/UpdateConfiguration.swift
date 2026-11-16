import Foundation

/// What a bundle's Info.plist says about updates: the feed address and the public key.
///
/// `scripts/bundle.sh` writes the feed only when release packaging asks for it, and
/// `scripts/info-plist.sh` writes the key only when `support/brand.env` has one. A build from source
/// has neither, so it never offers to replace itself with a release.
nonisolated public struct UpdateConfiguration: Equatable, Sendable {
    /// Sparkle's Info.plist key for the address of the appcast.
    public static let feedKey = "SUFeedURL"
    /// Sparkle's Info.plist key for the public half of the EdDSA key that signs updates.
    public static let publicKeyKey = "SUPublicEDKey"
    /// The size of an Ed25519 public key in bytes.
    static let publicKeyLength = 32

    /// The address of the appcast, always https.
    public let feed: URL
    /// The public key, as base64 of its 32 bytes.
    public let publicKey: String

    /// Reads the two values from an Info.plist dictionary. Nil unless the feed is an https address
    /// with a host and the key is base64 of exactly 32 bytes.
    public init?(info: [String: Any]) {
        guard let feedText = info[Self.feedKey] as? String,
            let feed = URL(string: feedText.trimmingCharacters(in: .whitespaces)),
            feed.scheme == "https", let host = feed.host(), !host.isEmpty
        else { return nil }
        guard let publicKey = info[Self.publicKeyKey] as? String,
            let bytes = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespaces)),
            bytes.count == Self.publicKeyLength
        else { return nil }
        self.feed = feed
        self.publicKey = publicKey.trimmingCharacters(in: .whitespaces)
    }
}
