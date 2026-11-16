import CoreGraphics

extension CGContext {
    /// Clears one point at two opposite corners of `bounds`, so a view's drawing always spans its
    /// bounds.
    ///
    /// AppKit sizes a view's backing to what the view draws. A list draws as far down as its rows
    /// reach, so its drawn height changes with its content. On screen, after another page had made
    /// the glass short, AppKit placed a taller drawing against the backing's older, shorter size,
    /// and every row showed a header height too high while the lens sat where it belonged. With
    /// both corners touched, the backing is always the size of the view. Off screen AppKit builds
    /// no such backing, so `make ui-components` is where this shows.
    func touchCorners(of bounds: CGRect) {
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        clear(CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1))
        clear(CGRect(x: bounds.maxX - 1, y: bounds.maxY - 1, width: 1, height: 1))
    }
}
