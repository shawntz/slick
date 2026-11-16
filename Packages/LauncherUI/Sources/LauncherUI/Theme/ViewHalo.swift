import AppKit

extension NSView {
    /// Gives what the view draws the theme's text halo as its shadow, or takes the shadow away for
    /// a theme without one. The shadow follows the view's drawing, so a text view's halo follows
    /// its glyphs and caret. AppKit owns the shadow of a view's layer, so the halo goes through
    /// `NSView.shadow`: a shadow set on the layer itself did not show.
    func applyTextHalo(_ theme: ResolvedTheme) {
        guard let halo = theme.textHalo else {
            if shadow != nil { shadow = nil }
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(cgColor: halo)
        shadow.shadowBlurRadius = CGFloat(theme.palette.textHaloRadius)
        shadow.shadowOffset = .zero
        self.shadow = shadow
    }
}
