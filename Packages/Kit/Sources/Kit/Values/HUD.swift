/// A short message the host shows after the panel closes, such as "Copied to Clipboard".
///
/// A string literal makes an info HUD, so `.close(hud: "Copied \(name)")` reads naturally. Use the
/// failure style when something did not happen; a thrown error shows one by itself.
public struct HUD: Hashable, Sendable, ExpressibleByStringInterpolation {
    public var title: String
    public var style: Toast.Style

    public init(_ title: String, style: Toast.Style = .info) {
        self.title = title
        self.style = style
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// A HUD with a failure mark.
    public static func failure(_ title: String) -> HUD {
        HUD(title, style: .failure)
    }

    /// A HUD with a check mark.
    public static func success(_ title: String) -> HUD {
        HUD(title, style: .success)
    }
}
