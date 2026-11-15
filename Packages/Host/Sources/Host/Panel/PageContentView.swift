import AppKit
import LauncherUI

/// The content area of one page: a container for the page's list, grid, form or empty state that
/// keeps the panel's height rules, with an optional banner above it.
///
/// With fixed sizing, the default, it reports one height whatever it shows, so typing never
/// resizes the glass. With fit-content sizing it reports its child's height, and calls
/// ``onHeightChange`` when that changes, so the controller can snap the glass in the same frame
/// instead of animating it. Only navigation and overlays animate the height.
public final class PageContentView: NSView, LauncherContentView {
    /// How tall the content area is.
    public enum Sizing: Equatable, Sendable {
        /// Always this tall: the full list.
        case fixed(CGFloat)
        /// As tall as what it shows.
        case fitContent
    }

    public var sizing: Sizing = .fitContent {
        didSet {
            guard sizing != oldValue else { return }
            layoutChild()
            onHeightChange?()
        }
    }

    /// What the page shows now.
    public private(set) var child: (any LauncherContentView)?
    /// The view above the child, such as a notice banner, and its height.
    public private(set) var banner: NSView?
    public private(set) var bannerHeight: CGFloat = 0
    public weak var selectionLens: SelectionLens? {
        didSet { child?.selectionLens = selectionLens }
    }
    /// Set by the surface. The container never calls it: height changes go through
    /// ``onHeightChange``, which snaps instead of animating.
    public var contentHeightDidChange: (() -> Void)?
    /// Called when the reported height changed under fit-content sizing.
    public var onHeightChange: (() -> Void)?
    /// Called when the theme changes, for page parts that are not the child, such as a banner.
    var onThemeChange: ((ResolvedTheme) -> Void)?

    private(set) var theme: ResolvedTheme?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }

    /// Shows a view, such as the list or the empty state, in place of the current one.
    public func show(_ view: (any LauncherContentView)?) {
        guard view !== child else { return }
        if let child {
            child.selectionLens = nil
            child.contentHeightDidChange = nil
            child.removeFromSuperview()
        }
        selectionLens?.isHidden = true
        child = view
        if let view {
            addSubview(view)
            if let theme { view.apply(theme) }
            layoutChild()
            view.contentHeightDidChange = { [weak self] in self?.childHeightDidChange() }
            view.selectionLens = selectionLens
        }
        if sizing == .fitContent { onHeightChange?() }
    }

    /// Shows a view above the child, or none. The child moves down by `height`.
    func setBanner(_ view: NSView?, height: CGFloat) {
        let newHeight = view == nil ? 0 : height
        guard view !== banner || newHeight != bannerHeight else { return }
        if banner !== view {
            banner?.removeFromSuperview()
            if let view { addSubview(view) }
        }
        banner = view
        bannerHeight = newHeight
        layoutChild()
        if sizing == .fitContent { onHeightChange?() }
    }

    public func preferredContentHeight(limit: CGFloat) -> CGFloat {
        switch sizing {
        case .fixed(let height): min(limit, height)
        case .fitContent:
            min(limit, (child?.preferredContentHeight(limit: max(0, limit - bannerHeight)) ?? 0) + bannerHeight)
        }
    }

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        child?.apply(theme)
        onThemeChange?(theme)
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { layoutChild() }
    }

    private func layoutChild() {
        let height: CGFloat
        switch sizing {
        case .fixed(let fixed): height = min(fixed, bounds.height)
        case .fitContent: height = bounds.height
        }
        if let banner {
            let frame = CGRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
            if banner.frame != frame { banner.frame = frame }
        }
        guard let child else { return }
        let frame = CGRect(x: 0, y: bannerHeight, width: bounds.width, height: max(0, height - bannerHeight))
        if child.frame != frame { child.frame = frame }
    }

    private func childHeightDidChange() {
        if sizing == .fitContent { onHeightChange?() }
    }
}
