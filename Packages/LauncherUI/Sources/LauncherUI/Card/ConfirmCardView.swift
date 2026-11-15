import AppKit

/// What a confirm card asks.
nonisolated public struct ConfirmContent: Sendable, Equatable {
    public var title: String
    public var message: String?
    /// The confirm button's title, such as "Delete".
    public var confirmTitle: String
    public var cancelTitle: String
    /// Draws the confirm button in the destructive colour.
    public var isDestructive: Bool
    /// The label of a checkbox beside the buttons, such as "Don't ask again". Nil shows none.
    /// Read `ConfirmCardView.isSuppressionChecked` in `onConfirm`.
    public var suppressionTitle: String?

    public init(
        title: String, message: String? = nil, confirmTitle: String, cancelTitle: String = "Cancel",
        isDestructive: Bool = false, suppressionTitle: String? = nil
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.isDestructive = isDestructive
        self.suppressionTitle = suppressionTitle
    }
}

/// A question in the middle of the panel: a title, a message and two buttons. Return confirms and
/// Escape cancels; either one removes the card. A destructive confirm is red.
///
/// With a `suppressionTitle` the card also shows a checkbox, such as "Don't ask again", at the
/// leading end of the button row. Space or a click toggles it.
public final class ConfirmCardView: CardSurface, PanelOverlay {
    public var onConfirm: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// Whether the suppression checkbox is ticked. Always false without a `suppressionTitle`.
    public var isSuppressionChecked: Bool { suppression?.isOn ?? false }
    public var overlaySizeDidChange: (() -> Void)?
    public let content: ConfirmContent

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let cancelButton: CardButton
    let confirmButton: CardButton
    let suppression: CheckboxFormControl?
    private var theme: ResolvedTheme?

    public init(content: ConfirmContent) {
        self.content = content
        cancelButton = CardButton(title: content.cancelTitle, key: "esc", role: .plain)
        confirmButton = CardButton(
            title: content.confirmTitle, key: "↩", role: content.isDestructive ? .destructive : .prominent)
        suppression = content.suppressionTitle.map { title in
            let box = CheckboxFormControl()
            box.update(.checkbox(label: title))
            return box
        }
        super.init(frame: .zero)
        titleLabel.stringValue = content.title
        messageLabel.stringValue = content.message ?? ""
        messageLabel.isHidden = content.message == nil
        titleLabel.textColor = .labelColor
        // The full label colour: secondary text on the light card fell under 3:1 over white.
        messageLabel.textColor = .labelColor
        for label in [titleLabel, messageLabel] {
            label.isSelectable = false
            label.alignment = .left
        }
        for view in [titleLabel, messageLabel, cancelButton, confirmButton] as [NSView] { body.addSubview(view) }
        cancelButton.onPress = { [weak self] in self?.cancel() }
        confirmButton.onPress = { [weak self] in self?.confirm() }
        if let suppression {
            body.addSubview(suppression)
            // A click focuses the box; hand focus back, so the card keeps Return, Escape and Space.
            suppression.onChange = { [weak self] _ in
                guard let self else { return }
                window?.makeFirstResponder(self)
            }
            suppression.onEscape = { [weak self] in self?.cancel() }
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(content.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var acceptsFirstResponder: Bool { true }

    /// Return confirms and Escape cancels. Other keys do nothing while the card asks.
    override public func keyDown(with event: NSEvent) {
        guard let chord = KeyChord(event: event) else { return }
        switch chord.key {
        case KeyChord.Key.returnKey: confirm()
        case KeyChord.Key.escape: cancel()
        case KeyChord.Key.space: suppression?.toggle()
        default: break
        }
    }

    override public func cancelOperation(_ sender: Any?) {
        cancel()
    }

    private func confirm() {
        dismissFromPanel()
        onConfirm?()
    }

    private func cancel() {
        dismissFromPanel()
        onCancel?()
    }

    /// Where the title's text and the message's first line are, for inspection.
    var titleTextFrame: CGRect {
        let frame = convert(titleLabel.frame, from: body)
        let width = min(frame.width, ceil(titleLabel.attributedStringValue.size().width))
        return CGRect(x: frame.minX + 2, y: frame.minY, width: width, height: frame.height)
    }
    var messageLineFrame: CGRect? {
        guard !messageLabel.isHidden, let font = messageLabel.font else { return nil }
        let frame = convert(messageLabel.frame, from: body)
        return CGRect(
            x: frame.minX + 2, y: frame.minY, width: frame.width * 0.8, height: ceil(font.ascender - font.descender))
    }

    // MARK: PanelOverlay

    public var placement: OverlayPlacement { .center }
    public var dimsBehind: Bool { true }
    public var focusView: NSView? { self }
    public func overlayDidDismiss() {}

    public func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        applyChrome(theme, cornerRadius: theme.theme.card.cornerRadius)
        titleLabel.font = theme.card.confirmTitleFont
        messageLabel.font = theme.card.confirmMessageFont
        cancelButton.apply(theme)
        confirmButton.apply(theme)
        suppression?.apply(theme)
        needsLayout = true
    }

    public func overlaySize(maximum: CGSize) -> CGSize {
        guard let theme else { return .zero }
        let card = theme.theme.card
        let width = min(maximum.width, CGFloat(card.confirmWidth))
        let heights = textHeights(width: width - CGFloat(card.confirmPadding) * 2)
        var height = CGFloat(card.confirmPadding) * 2 + heights.title + CGFloat(card.buttonHeight)
        height += CGFloat(card.confirmGap) * (heights.message > 0 ? 2 : 1) + heights.message
        return CGSize(width: width, height: min(maximum.height, ceil(height)))
    }

    private func textHeights(width: CGFloat) -> (title: CGFloat, message: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let title = ceil(titleLabel.cell?.cellSize(forBounds: bounds).height ?? 0)
        let message = messageLabel.isHidden ? 0 : ceil(messageLabel.cell?.cellSize(forBounds: bounds).height ?? 0)
        return (title, message)
    }

    override public func layout() {
        super.layout()
        guard let theme else { return }
        let card = theme.theme.card
        let padding = CGFloat(card.confirmPadding)
        let width = bounds.width - padding * 2
        let heights = textHeights(width: width)
        var y = padding
        titleLabel.frame = CGRect(x: padding, y: y, width: width, height: heights.title)
        y += heights.title + CGFloat(card.confirmGap)
        if heights.message > 0 {
            messageLabel.frame = CGRect(x: padding, y: y, width: width, height: heights.message)
            y += heights.message + CGFloat(card.confirmGap)
        }
        let buttonHeight = CGFloat(card.buttonHeight)
        var right = bounds.width - padding
        for button in [confirmButton, cancelButton] {
            let buttonWidth = button.fittingWidth
            button.frame = CGRect(x: right - buttonWidth, y: y, width: buttonWidth, height: buttonHeight)
            right -= buttonWidth + CGFloat(card.buttonSpacing)
        }
        if let suppression {
            let width = min(suppression.fittingWidth, max(0, right - padding))
            suppression.frame = CGRect(x: padding, y: y, width: width, height: buttonHeight)
        }
    }
}
