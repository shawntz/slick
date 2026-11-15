import AppKit

/// The system display settings that change how the launcher draws: Reduce Transparency, Increase
/// Contrast and Reduce Motion.
nonisolated public struct DisplayAccessibility: Sendable, Equatable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var reduceMotion: Bool

    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }

    /// The settings as the system reports them now.
    @MainActor public static var current: DisplayAccessibility {
        let workspace = NSWorkspace.shared
        return DisplayAccessibility(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }
}

/// Calls back on the main thread whenever the system display accessibility settings change.
/// The observation ends when this object is released.
public final class DisplayAccessibilityObserver {
    private var token: (any NSObjectProtocol)?

    public init(onChange: @escaping @MainActor (DisplayAccessibility) -> Void) {
        // The change arrives on the workspace notification center, not the default one.
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange(.current) }
        }
    }

    isolated deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
