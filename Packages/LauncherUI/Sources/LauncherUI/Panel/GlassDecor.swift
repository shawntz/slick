import AppKit
import QuartzCore

/// A piece of glass as the decoration sees it: its frame in the decoration's superview and its
/// corner radius.
public struct GlassShape: Equatable {
    public var frame: CGRect
    public var cornerRadius: CGFloat

    public init(frame: CGRect, cornerRadius: CGFloat) {
        self.frame = frame
        self.cornerRadius = cornerRadius
    }

    /// The outline, its radius clamped so a short piece draws as a capsule. A rounded rectangle
    /// whose corners do not fit is not a valid path.
    func path(in rect: CGRect) -> CGPath {
        let radius = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// A view that draws over or under the glass and never takes a click or an accessibility focus.
/// Its own coordinates are not flipped, so its layers keep Core Animation's usual y-up geometry.
/// The settings window's theme preview uses the same views as the panel.
public class GlassDecorView: NSView {
    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) { nil }

    override public var isOpaque: Bool { false }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A frame in the root view's flipped coordinates, in this view's.
    func local(_ rect: CGRect) -> CGRect {
        guard let superview else { return rect }
        return convert(rect, from: superview)
    }
}

/// A soft shadow under the pieces of glass, beyond the shadow the glass draws itself, like a
/// window's shadow: drawn from a path by the render server, and only outside the glass, so it
/// never darkens what shows through it.
public final class GlassShadowView: GlassDecorView {
    private let caster = CALayer()
    private let cutout = CAShapeLayer()
    private var shapes: [GlassShape] = []

    override public init(frame: NSRect) {
        super.init(frame: frame)
        cutout.fillRule = .evenOdd
        caster.mask = cutout
        layer?.addSublayer(caster)
    }

    public required init?(coder: NSCoder) { nil }

    /// Styles the caster. Nil colour or a zero radius draws none.
    public func apply(color: CGColor?, radius: CGFloat, offset: CGFloat) {
        shapes = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = color == nil || radius <= 0
        caster.shadowColor = color?.copy(alpha: 1)
        caster.shadowOpacity = Float(color?.alpha ?? 0)
        caster.shadowRadius = radius
        caster.shadowOffset = CGSize(width: 0, height: -offset)
        CATransaction.commit()
    }

    /// Follows the pieces. Runs on every tick of a height animation, so it only builds paths.
    public func update(_ shapes: [GlassShape]) {
        guard !isHidden, shapes != self.shapes else { return }
        self.shapes = shapes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caster.frame = bounds
        cutout.frame = bounds
        let outline = CGMutablePath()
        for shape in shapes { outline.addPath(shape.path(in: local(shape.frame))) }
        caster.shadowPath = outline
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(outline)
        cutout.path = mask
        CATransaction.commit()
    }
}

/// A bright line along the lower half of each piece's edge, strongest at the bottom and fading
/// out toward the middle of the sides.
public final class GlassRimView: GlassDecorView {
    private var rims: [CAGradientLayer] = []
    private var color: CGColor?
    private var width: CGFloat = 0
    private var shapes: [GlassShape] = []

    /// Styles the rim. Nil colour or a zero width draws none.
    public func apply(color: CGColor?, width: CGFloat) {
        self.color = color
        self.width = width
        isHidden = color == nil || width <= 0
        shapes = []
        for rim in rims { restyle(rim) }
    }

    /// Follows the pieces. Runs on every tick of a height animation, so it only sets frames and
    /// builds paths.
    public func update(_ shapes: [GlassShape]) {
        guard !isHidden, shapes != self.shapes else { return }
        self.shapes = shapes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while rims.count < shapes.count {
            let rim = CAGradientLayer()
            rim.mask = CAShapeLayer()
            restyle(rim)
            layer?.addSublayer(rim)
            rims.append(rim)
        }
        for (index, rim) in rims.enumerated() {
            guard shapes.indices.contains(index) else {
                rim.isHidden = true
                continue
            }
            let frame = local(shapes[index].frame)
            rim.isHidden = false
            rim.frame = frame
            guard let stroke = rim.mask as? CAShapeLayer else { continue }
            stroke.frame = rim.bounds
            var shape = shapes[index]
            shape.cornerRadius -= width / 2
            stroke.path = shape.path(in: rim.bounds.insetBy(dx: width / 2, dy: width / 2))
        }
        CATransaction.commit()
    }

    private func restyle(_ rim: CAGradientLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let full = color ?? CGColor(gray: 1, alpha: 0)
        let clear = full.copy(alpha: 0) ?? full
        // y up: the bottom edge is at 0. Clear above the middle, three quarters just below it.
        rim.colors = [full, full.copy(alpha: full.alpha * 0.75) ?? full, clear, clear]
        rim.locations = [0, 0.42, 0.5, 1]
        rim.startPoint = CGPoint(x: 0.5, y: 0)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        if let stroke = rim.mask as? CAShapeLayer {
            stroke.fillColor = nil
            stroke.strokeColor = CGColor(gray: 0, alpha: 1)
            stroke.lineWidth = width
        }
        CATransaction.commit()
    }
}

/// A shade over the query row's glass in the split layout: the theme's colour at the top edge,
/// fading to nothing at the bottom edge. It sits under the query field, inside the glass.
public final class FieldShadeView: GlassDecorView {
    private let gradient = CAGradientLayer()

    override public init(frame: NSRect) {
        super.init(frame: frame)
        gradient.masksToBounds = true
        gradient.cornerCurve = .circular
        layer?.addSublayer(gradient)
        isHidden = true
    }

    public required init?(coder: NSCoder) { nil }

    /// Nil hides the shade.
    public func apply(color: CGColor?, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = color == nil
        if let color {
            // Darkest at the top and easing out: at the middle it keeps 60% of its strength and at
            // 85% of the height a quarter, as the measured reference does, rather than what a
            // straight fade would keep.
            gradient.colors = [
                color, color.copy(alpha: color.alpha * 0.6) ?? color, color.copy(alpha: color.alpha * 0.25) ?? color,
                color.copy(alpha: 0) ?? color,
            ]
            gradient.locations = [0, 0.5, 0.85, 1]
            // y up: the top edge is at 1.
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        gradient.cornerRadius = cornerRadius
        CATransaction.commit()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
