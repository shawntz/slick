import KitHosting

/// A login item switch in memory. Nothing is registered with the system.
@MainActor public final class FakeLoginItem: LoginItemControl {
    public private(set) var isEnabled: Bool
    /// When set, ``setEnabled(_:)`` throws it and changes nothing.
    public var failure: (any Error)?
    /// Every value passed to ``setEnabled(_:)``, in order, including refused ones.
    public private(set) var requests: [Bool] = []

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if let failure { throw failure }
        isEnabled = enabled
    }
}
