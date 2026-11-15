import AppKit

/// The bar at the bottom of the glass.
///
/// The left region shows the current view's icon and name, or a toast that cross-fades in over
/// it. The right region shows the primary action with its Return keycap, a divider, and the entry
/// to the action panel with its Command-K keycap. Its text is vibrant `NSTextField` labels: the bar
/// changes per selection, not per row, so labels cost little here and keep the glass's vibrancy.
public final class ActionBar: NSView {
    /// Starts with nothing shown, so the first `apply(_:)` fills every part, the default
    /// "Actions" title included.
    public private(set) var content = ActionBarContent(viewTitle: "", actionsTitle: nil)
    public private(set) var toast: ActionBarToast?
    /// The toast's button was clicked or pressed through accessibility.
    public var onToastButton: (() -> Void)?

    private let viewRegion = FlippedView()
    private let viewIcon = NSImageView()
    private let viewTitle = FixedLabel()
    private let toastRegion = FlippedView()
    private let spinner = NSProgressIndicator()
    private let toastSymbol = NSImageView()
    private let toastText = FixedLabel()
    let toastButton = CardButton(title: "", key: "", role: .plain)
    private let primaryTitle = FixedLabel()
    private let primaryKeys = KeycapView()
    private let divider = NSView()
    let actionsTitle = FixedLabel()
    private let actionsKeys = KeycapView()
    private var metrics = Theme.standard.actionBar
    private var fadeDuration: Double = 0

    override public var isFlipped: Bool { true }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        for label in [viewTitle, toastText, primaryTitle, actionsTitle] {
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .secondaryLabelColor
        }
        primaryTitle.textColor = .labelColor
        viewIcon.imageScaling = .scaleProportionallyUpOrDown
        // Hidden until a view supplies an icon, so layout does not leave room for one at first.
        viewIcon.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        toastSymbol.imageScaling = .scaleProportionallyUpOrDown
        divider.wantsLayer = true
        viewRegion.addSubview(viewIcon)
        viewRegion.addSubview(viewTitle)
        toastButton.isHidden = true
        toastButton.onPress = { [weak self] in self?.onToastButton?() }
        for view in [spinner, toastSymbol, toastText, toastButton] as [NSView] { toastRegion.addSubview(view) }
        toastRegion.alphaValue = 0
        for view in [primaryTitle, actionsTitle, divider] as [NSView] { view.isHidden = true }
        for view in [viewRegion, toastRegion, primaryTitle, primaryKeys, divider, actionsTitle, actionsKeys] as [NSView]
        {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    public func apply(_ theme: ResolvedTheme) {
        metrics = theme.theme.actionBar
        fadeDuration = theme.motion.toastFade
        let fonts = theme.theme.fonts
        for label in [viewTitle, toastText, actionsTitle] { label.font = fonts.actionBar.nsFont }
        primaryTitle.font = fonts.actionBarPrimary.nsFont
        divider.layer?.backgroundColor = theme.hairline
        primaryKeys.apply(theme)
        actionsKeys.apply(theme)
        toastButton.apply(theme)
        needsLayout = true
    }

    /// Shows new content. Only the parts that changed are touched, and the bar is laid out
    /// again only when a width can have changed: it updates on every keystroke.
    public func apply(_ content: ActionBarContent) {
        let old = self.content
        guard content != old else { return }
        self.content = content
        if content.viewIcon !== old.viewIcon {
            viewIcon.image = content.viewIcon.map { NSImage(cgImage: $0, size: .zero) }
            viewIcon.isHidden = content.viewIcon == nil
        }
        if content.viewTitle != old.viewTitle { viewTitle.stringValue = content.viewTitle }
        if content.primaryTitle != old.primaryTitle {
            primaryTitle.stringValue = content.primaryTitle ?? ""
            primaryTitle.isHidden = content.primaryTitle == nil
        }
        primaryKeys.keys = content.primaryTitle == nil ? [] : content.primaryKeys
        if content.actionsTitle != old.actionsTitle {
            actionsTitle.stringValue = content.actionsTitle ?? ""
            actionsTitle.isHidden = content.actionsTitle == nil
        }
        actionsKeys.keys = content.actionsTitle == nil ? [] : content.actionsKeys
        divider.isHidden = content.primaryTitle == nil || content.actionsTitle == nil
        if content.viewTitle != old.viewTitle || content.primaryTitle != old.primaryTitle {
            setAccessibilityLabel([content.viewTitle, content.primaryTitle].compactMap(\.self).joined(separator: ", "))
        }
        let widthsChanged =
            (content.viewIcon == nil) != (old.viewIcon == nil) || content.primaryTitle != old.primaryTitle
            || content.primaryKeys != old.primaryKeys || content.actionsTitle != old.actionsTitle
            || content.actionsKeys != old.actionsKeys
        if widthsChanged { needsLayout = true }
    }

    /// Cross-fades a toast in over the view's name, or back out when `toast` is nil.
    public func show(_ toast: ActionBarToast?) {
        guard toast != self.toast else { return }
        self.toast = toast
        if let toast {
            toastText.stringValue = toast.text
            switch toast.style {
            case .progress:
                toastSymbol.isHidden = true
                spinner.startAnimation(nil)
            case .success, .failure:
                spinner.stopAnimation(nil)
                toastSymbol.isHidden = false
                let success = toast.style == .success
                toastSymbol.image = NSImage(
                    systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    accessibilityDescription: nil
                )
                toastSymbol.contentTintColor = success ? .systemGreen : .systemOrange
            case .info:
                spinner.stopAnimation(nil)
                toastSymbol.isHidden = true
            }
            toastButton.title = toast.buttonTitle ?? ""
            toastButton.key = toast.buttonKeys.joined()
            toastButton.needsDisplay = true
            toastButton.setAccessibilityLabel(toast.buttonTitle)
            toastButton.isHidden = toast.buttonTitle == nil
            NSAccessibility.post(
                element: self, notification: .announcementRequested,
                userInfo: [.announcement: toast.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        } else {
            spinner.stopAnimation(nil)
            toastButton.isHidden = true
        }
        needsLayout = true
        let showsToast = toast != nil
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = fadeDuration
                context.allowsImplicitAnimation = fadeDuration > 0
                viewRegion.animator().alphaValue = showsToast ? 0 : 1
                toastRegion.animator().alphaValue = showsToast ? 1 : 0
            }, completionHandler: nil)
    }

    override public func layout() {
        super.layout()
        let height = bounds.height
        let inset = CGFloat(metrics.horizontalInset)
        let spacing = CGFloat(metrics.itemSpacing)
        var right = bounds.width - inset

        func placeKeys(_ keys: KeycapView) {
            let width = keys.fittingWidth
            keys.frame = CGRect(x: right - width, y: 0, width: width, height: height)
            right -= width + (width > 0 ? spacing : 0)
        }
        func placeLabel(_ label: FixedLabel, maxWidth: CGFloat) {
            guard !label.isHidden else { return }
            let width = min(maxWidth, label.textWidth)
            label.frame = centered(label, x: right - width, width: width)
            right -= width
        }
        placeKeys(actionsKeys)
        placeLabel(actionsTitle, maxWidth: bounds.width * CGFloat(metrics.titleMaxFraction))
        if !divider.isHidden {
            right -= CGFloat(metrics.dividerSpacing)
            let dividerHeight = CGFloat(metrics.dividerHeight)
            divider.frame = CGRect(
                x: right - 1, y: ((height - dividerHeight) / 2).rounded(), width: 1, height: dividerHeight)
            right -= 1 + CGFloat(metrics.dividerSpacing)
        }
        placeKeys(primaryKeys)
        placeLabel(primaryTitle, maxWidth: bounds.width * CGFloat(metrics.titleMaxFraction))

        let left = CGRect(x: inset, y: 0, width: max(0, right - inset - spacing * 2), height: height)
        viewRegion.frame = left
        toastRegion.frame = left
        let iconSize = CGFloat(metrics.iconSize)
        var x: CGFloat = 0
        if !viewIcon.isHidden {
            viewIcon.frame = CGRect(x: 0, y: ((height - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
            x = iconSize + spacing
        }
        viewTitle.frame = centered(viewTitle, x: x, width: max(0, left.width - x))
        let symbol = CGRect(x: 0, y: ((height - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
        spinner.frame = symbol
        toastSymbol.frame = symbol
        let textX = toast?.style == .info ? 0 : iconSize + spacing
        var textRight = left.width
        if !toastButton.isHidden {
            let buttonHeight = CGFloat(metrics.keycapHeight + metrics.keycapPadding)
            let buttonWidth = min(toastButton.fittingWidth, max(0, left.width - textX))
            let buttonX = min(left.width - buttonWidth, textX + ceil(toastText.textWidth) + spacing * 2)
            toastButton.frame = CGRect(
                x: max(textX, buttonX), y: ((height - buttonHeight) / 2).rounded(), width: buttonWidth,
                height: buttonHeight)
            textRight = toastButton.frame.minX - spacing * 2
        }
        toastText.frame = centered(toastText, x: textX, width: max(0, textRight - textX))
    }

    private func centered(_ label: FixedLabel, x: CGFloat, width: CGFloat) -> CGRect {
        let labelHeight = label.lineHeight
        return CGRect(x: x, y: ((bounds.height - labelHeight) / 2).rounded(), width: width, height: labelHeight)
    }
}
