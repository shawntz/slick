import CoreGraphics

/// Where the panel's window and glass go on a screen. Pure arithmetic, in AppKit screen
/// coordinates (origin bottom left, y up).
///
/// The window has a fixed size: the tallest glass plus transparent shadow insets. The top of the
/// glass sits `topFraction` of the way down the visible frame, so the query row stays put while
/// the glass grows downward. On a screen too short for the tallest glass, the glass moves up just
/// enough to fit.
///
/// In the split layout "the glass" is the whole stack: the query row's piece, the gap and the
/// results container. `fieldFrame` and `resultsFrame(height:)` give the pieces.
nonisolated public struct PanelGeometry: Sendable, Equatable {
    /// The window frame.
    public let windowFrame: CGRect
    /// The glass at its tallest, in window coordinates with a flipped (top-left) origin.
    public let glassFrame: CGRect
    /// The query row: in the split layout its own piece of glass.
    public let fieldFrame: CGRect
    /// Where the results container starts in the split layout, below the query row and the gap.
    public let resultsTop: Double

    public init(theme: Theme, visibleFrame: CGRect) {
        let panel = theme.panel
        let insets = panel.shadowInsets
        let width = panel.width
        let height = theme.maxGlassHeight
        let glassX = (visibleFrame.midX - width / 2).rounded()
        var glassTop = (visibleFrame.maxY - visibleFrame.height * panel.topFraction).rounded()
        let lowestBottom = visibleFrame.minY + panel.minimumScreenMargin
        if glassTop - height < lowestBottom {
            glassTop = min(visibleFrame.maxY - panel.minimumScreenMargin, lowestBottom + height)
        }
        windowFrame = CGRect(
            x: glassX - insets.left,
            y: glassTop - height - insets.bottom,
            width: width + insets.left + insets.right,
            height: height + insets.top + insets.bottom
        )
        glassFrame = CGRect(x: insets.left, y: insets.top, width: width, height: height)
        fieldFrame = CGRect(x: insets.left, y: insets.top, width: width, height: theme.queryRow.height)
        resultsTop = insets.top + theme.queryRow.height + theme.resultsOffset
    }

    /// The glass at `height`, top-anchored, in flipped window coordinates.
    public func glassFrame(height: Double) -> CGRect {
        CGRect(x: glassFrame.minX, y: glassFrame.minY, width: glassFrame.width, height: height)
    }

    /// The results container of the split layout at `height`, top-anchored below the gap.
    public func resultsFrame(height: Double) -> CGRect {
        CGRect(x: glassFrame.minX, y: resultsTop, width: glassFrame.width, height: height)
    }
}
