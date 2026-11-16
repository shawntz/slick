import AppKit

/// Cards and menus over the content: presenting, placing, dimming and handing focus back.
extension LauncherSurface {
    /// Shows a card or menu over the content and gives it keyboard focus. Replaces any overlay
    /// already showing. The glass grows when the content is too short to hold it.
    ///
    /// Present the same card again rather than a new one where you can: a dismissed overlay stays
    /// in the glass, hidden, so showing it again skips building and first-rendering its glass.
    public func present(_ overlay: any PanelOverlay) {
        if self.overlay != nil { dismissOverlay(restoringFocus: false) } else { focusBeforeOverlay = currentFocus }
        self.overlay = overlay
        if overlay !== parkedOverlay || !(parkedOverlayTheme.map { $0.isSameStyle(as: resolvedTheme) } ?? false) {
            overlay.apply(resolvedTheme)
        }
        overlay.overlaySizeDidChange = { [weak self] in
            self?.updateHeight(animated: true)
            self?.layoutOverlay(hostHeight: self?.currentHostHeight ?? 0)
        }
        if let parked = parkedOverlay, parked !== overlay { parked.removeFromSuperview() }
        parkedOverlay = nil
        let host = contentHost
        if overlay.superview === host {
            // A parked overlay is still on top; the shield goes just under it.
            host.addSubview(shield, positioned: .below, relativeTo: overlay)
        } else {
            host.addSubview(shield)
            host.addSubview(overlay)
        }
        if layout == .split {
            glassContent.addSubview(fieldShield)
            fieldShield.frame = glassContent.bounds
        }
        overlay.isHidden = false
        shield.frame = CGRect(x: 0, y: 0, width: CGFloat(theme.panel.width), height: currentHostHeight)
        updateHeight(animated: true)
        layoutOverlay(hostHeight: currentHostHeight)
        let fade = resolvedTheme.motion.cardFade
        overlay.alphaValue = fade > 0 ? 0 : 1
        if fade > 0 { animate(fade) { overlay.animator().alphaValue = 1 } }
        setDimmed(overlay.dimsBehind)
        // Size the overlay's fields before focusing one: resizing a field mid-edit ends editing.
        overlay.prepareToShow()
        if let focus = overlay.focusView { panel.makeFirstResponder(focus) }
    }

    /// Builds and renders `overlay` once while hidden, so its first `present(_:)` costs what later
    /// ones do. Call at launch with the card the host reuses, such as its action card.
    public func prewarm(_ overlay: any PanelOverlay) {
        guard self.overlay == nil else { return }
        if let parked = parkedOverlay, parked !== overlay { parked.removeFromSuperview() }
        overlay.apply(resolvedTheme)
        overlay.frame = CGRect(origin: .zero, size: overlay.overlaySize(maximum: overlayMaximumSize))
        overlay.isHidden = false
        overlay.alphaValue = 0
        contentHost.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        overlay.isHidden = true
        overlay.alphaValue = 1
        parkedOverlay = overlay
        parkedOverlayTheme = resolvedTheme
    }

    /// Removes the overlay, undims the content and gives keyboard focus back to whoever had it.
    public func dismissOverlay() {
        dismissOverlay(restoringFocus: true)
    }

    func dismissOverlay(restoringFocus: Bool) {
        guard let overlay else { return }
        self.overlay = nil
        overlay.overlaySizeDidChange = nil
        // Kept in the glass, hidden, so presenting it again is cheap.
        overlay.isHidden = true
        if let parked = parkedOverlay, parked !== overlay { parked.removeFromSuperview() }
        parkedOverlay = overlay
        parkedOverlayTheme = resolvedTheme
        shield.removeFromSuperview()
        fieldShield.removeFromSuperview()
        setDimmed(false)
        if restoringFocus {
            if let previous = focusBeforeOverlay as? NSView, previous.window === panel,
                previous !== queryField.textField
            {
                panel.makeFirstResponder(previous)
            } else {
                queryField.installEditor()
            }
            focusBeforeOverlay = nil
        }
        overlay.overlayDidDismiss()
        updateHeight(animated: true)
    }

    /// The content height an overlay needs to fit with its margins.
    var overlayRequiredHeight: CGFloat {
        guard let overlay else { return 0 }
        let margin = CGFloat(theme.card.margin)
        let size = overlay.overlaySize(maximum: overlayMaximumSize)
        switch overlay.placement {
        case .bottomTrailing, .center:
            return size.height + margin * 2
        case .below(let anchor, _):
            return anchorBottom(anchor) + margin + size.height + margin - contentTop
        }
    }

    /// The anchor's bottom edge as a menu below it sees it. In the split layout a chip in the query
    /// row lies above the results container, so its menu starts at the container's top margin.
    private func anchorBottom(_ anchor: CGRect) -> CGFloat {
        layout == .split ? max(anchor.maxY, CGFloat(theme.card.margin) / 2) : anchor.maxY
    }

    private var overlayMaximumSize: CGSize {
        let margin = CGFloat(theme.card.margin)
        return CGSize(
            width: CGFloat(theme.panel.width) - margin * 2, height: CGFloat(theme.panel.maxContentHeight) - margin * 2)
    }

    /// Places the overlay for a content-side piece of `hostHeight`: the slab, or the results
    /// container. Bottom-anchored cards ride its bottom edge while its height animates.
    func layoutOverlay(hostHeight: CGFloat) {
        guard let overlay else { return }
        let margin = CGFloat(theme.card.margin)
        let width = CGFloat(theme.panel.width)
        let top = contentTop
        let bottom = hostHeight - actionBarRoom
        var size = overlay.overlaySize(maximum: overlayMaximumSize)
        var origin: CGPoint
        switch overlay.placement {
        case .bottomTrailing:
            origin = CGPoint(x: width - margin - size.width, y: bottom - margin - size.height)
        case .center:
            origin = CGPoint(
                x: ((width - size.width) / 2).rounded(), y: (top + (bottom - top - size.height) / 2).rounded())
        case .below(let anchor, let trailingAligned):
            let x = trailingAligned ? anchor.maxX - size.width : anchor.minX
            origin = CGPoint(x: min(max(margin, x), width - margin - size.width), y: anchorBottom(anchor) + margin / 2)
            let roomBelow = bottom - margin - origin.y
            if size.height > roomBelow {
                let roomAbove = anchor.minY - margin / 2 - (top + margin)
                if roomAbove > roomBelow, anchor.minY > top {
                    size.height = min(size.height, roomAbove)
                    origin.y = anchor.minY - margin / 2 - size.height
                } else {
                    size.height = max(0, roomBelow)
                }
            }
        }
        overlay.frame = CGRect(origin: origin, size: size)
    }

    /// Dims or undims the content, the lens and the query row behind an overlay.
    private func setDimmed(_ dimmed: Bool) {
        let alpha = dimmed ? CGFloat(theme.card.dimAlpha) : 1
        var views: [NSView] = [lens.view, queryField]
        if let content { views.append(content) }
        let fade = resolvedTheme.motion.dimFade
        guard fade > 0 else {
            for view in views { view.alphaValue = alpha }
            return
        }
        animate(fade) { for view in views { view.animator().alphaValue = alpha } }
    }

    private func animate(_ duration: Double, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = duration
                changes()
            }, completionHandler: nil)
    }
}
