import AppKit
import CoreText

/// Where the part 2 components draw their text, for contrast measurement in captures. Every frame
/// is in the coordinates of the view it is read from. Not for hosts.
@_spi(Testing) public struct DrawnText {
    /// Text held to the title target (4.5:1): titles, values and body text.
    public var titles: [CGRect] = []
    /// The selected item's title, which sits on the lens or a selection fill.
    public var selectedTitles: [CGRect] = []
    /// Text held to the secondary target (3:1): subtitles, labels, hints and messages.
    public var secondary: [CGRect] = []
    public var headers: [CGRect] = []
    /// Keycaps and tags: their capsule, text included.
    public var capsules: [CGRect] = []
    /// Error and help text under form fields, held to 3:1.
    public var messages: [CGRect] = []
}

extension GridView {
    /// The titles and subtitles of the visible cells, and the visible section headers.
    @_spi(Testing) public func drawnText() -> DrawnText {
        var drawn = DrawnText()
        guard let theme else { return drawn }
        let top = Double(scrollOffset)
        let viewport = CGRect(x: 0, y: 0, width: bounds.width, height: viewportHeight)
        for index in layoutModel.cells(overlapping: top, top + Double(viewportHeight)) {
            guard let rect = cellRect(index), viewport.contains(rect), let cell = cell(at: index) else { continue }
            let typeset = typeset(index, cell, scale: window?.backingScaleFactor ?? 2)
            if let title = typeset.title {
                let frame = DrawnText.frame(title, font: theme.grid.titleFont).offsetBy(dx: rect.minX, dy: rect.minY)
                if index == selectedIndex { drawn.selectedTitles.append(frame) } else { drawn.titles.append(frame) }
            }
            if let subtitle = typeset.subtitle {
                drawn.secondary.append(
                    DrawnText.frame(subtitle, font: theme.grid.subtitleFont).offsetBy(dx: rect.minX, dy: rect.minY))
            }
        }
        let list = theme.theme.list
        let font = theme.sectionHeaderFont
        for header in layoutModel.headers(overlapping: top, top + Double(viewportHeight)) {
            let y = CGFloat(header.y) - scrollOffset
            guard y >= 0, let title = content.sections[header.section].title else { continue }
            let width = RowTypesetter.lineWidth(
                CTLineCreateWithAttributedString(
                    RowTypesetter.attributed(title, font: font, color: theme.sectionHeader)))
            drawn.headers.append(
                CGRect(
                    x: list.sectionHeaderX, y: Double(y) + list.sectionHeaderBaseline - Double(CTFontGetAscent(font)),
                    width: Double(width), height: Double(CTFontGetAscent(font) + CTFontGetDescent(font))))
        }
        return drawn
    }
}

extension CardListView {
    /// Row titles, keycaps and section headers, in this view's coordinates.
    func drawnText() -> DrawnText {
        var drawn = DrawnText()
        guard let theme else { return drawn }
        let card = theme.theme.card
        let font = theme.card.rowFont
        let ascent = CTFontGetAscent(font)
        let height = ascent + CTFontGetDescent(font)
        var index = 0
        for section in sections {
            for item in section.items {
                defer { index += 1 }
                guard let rect = rowRect(index), rect.minY >= 0, rect.maxY <= bounds.height else { continue }
                let x = CGFloat(card.horizontalPadding) + (hasIcons ? CGFloat(card.iconSize + card.iconGap) : 0)
                let width = RowTypesetter.lineWidth(
                    CTLineCreateWithAttributedString(
                        RowTypesetter.attributed(item.title, font: font, color: theme.title)))
                let baseline = rect.minY + RowTypesetter.baseline(centering: font, in: rect.height)
                let frame = CGRect(x: x, y: baseline - ascent, width: width, height: height)
                if index == selectedIndex { drawn.selectedTitles.append(frame) } else { drawn.titles.append(frame) }
                let keys = KeycapRenderer.width(item.keys, theme: theme)
                if keys > 0 {
                    let capHeight = CGFloat(theme.theme.list.keycapHeight)
                    drawn.capsules.append(
                        CGRect(
                            x: rect.maxX - CGFloat(card.horizontalPadding) - keys, y: rect.midY - capHeight / 2,
                            width: keys, height: capHeight))
                }
            }
        }
        return drawn
    }
}

extension ActionCardView {
    /// The rows' text. The filter's placeholder is not measured, as the query's is not.
    @_spi(Testing) public func drawnText() -> DrawnText { list.drawnText().converted(from: list, to: self) }
}

extension DropdownMenuView {
    @_spi(Testing) public func drawnText() -> DrawnText { list.drawnText().converted(from: list, to: self) }
}

extension DetailPane {
    /// The first lines of body text, and the metadata labels and values.
    @_spi(Testing) public func drawnText() -> DrawnText {
        var drawn = DrawnText()
        let text = textView.textView
        if !textView.isHidden, let layout = text.layoutManager, !text.string.isEmpty {
            let glyphs = layout.glyphRange(
                forCharacterRange: NSRange(location: 0, length: min(80, text.string.utf16.count)),
                actualCharacterRange: nil)
            var lines: [CGRect] = []
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in lines.append(used) }
            let origin = text.textContainerOrigin
            for line in lines.prefix(2) {
                drawn.titles.append(convert(line.offsetBy(dx: origin.x, dy: origin.y), from: text))
            }
        }
        if let theme {
            let metadata = metadataView.drawnText(theme: theme)
            drawn.secondary += metadata.secondary.map { convert($0, from: metadataView) }
            drawn.titles += metadata.titles.map { convert($0, from: metadataView) }
            drawn.capsules += metadata.capsules.map { convert($0, from: metadataView) }
        }
        return drawn
    }
}

extension MetadataView {
    /// Label and value text boxes, row by row, measured as `draw(_:)` places them.
    func drawnText(theme: ResolvedTheme) -> DrawnText {
        var drawn = DrawnText()
        let metrics = theme.theme.detail
        let padding = CGFloat(metrics.padding)
        let right = bounds.width - padding
        var y = CGFloat(metrics.metadataGroupGap)
        let labelFont = theme.detail.metadataLabelFont
        let valueFont = theme.detail.metadataValueFont
        func width(_ text: String, _ font: CTFont) -> CGFloat {
            RowTypesetter.lineWidth(
                CTLineCreateWithAttributedString(RowTypesetter.attributed(text, font: font, color: theme.title)))
        }
        func box(_ font: CTFont, x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            let ascent = CTFontGetAscent(font)
            let baseline = y + RowTypesetter.baseline(centering: font, in: height)
            return CGRect(x: x, y: baseline - ascent, width: width, height: ascent + CTFontGetDescent(font))
        }
        for item in items {
            let height = CGFloat(metrics.metadataRowHeight)
            switch item {
            case .separator:
                y += CGFloat(metrics.metadataGroupGap) * 2 + 1
                continue
            case .label(let label, let value), .link(let label, let value, _), .color(let label, _, let value),
                .iconLabel(let label, let value, _):
                drawn.secondary.append(box(labelFont, x: padding, width: width(label, labelFont), height: height))
                let valueWidth = width(value, valueFont)
                drawn.titles.append(box(valueFont, x: right - valueWidth, width: valueWidth, height: height))
            case .tags(let label, _):
                drawn.secondary.append(box(labelFont, x: padding, width: width(label, labelFont), height: height))
            }
            y += height
        }
        return drawn
    }
}

extension FormView {
    /// Labels and messages as secondary text, and the text of one-line fields as titles.
    @_spi(Testing) public func drawnText() -> DrawnText {
        var drawn = DrawnText()
        let visible = CGRect(x: 0, y: 0, width: bounds.width, height: preferredContentHeight(limit: bounds.height))
        for item in content.items {
            guard let row = rowViews(for: item.id) else { continue }
            let document = row.labelSuperview ?? self
            if let label = row.labelTextFrame { drawn.secondary.append(convert(label, from: document)) }
            if let message = row.messageTextFrame { drawn.messages.append(convert(message, from: document)) }
            if case .text = item.kind, let text = row.control?.textFrame, let control = row.control {
                drawn.titles.append(convert(text, from: control))
            }
        }
        // Rows scrolled out of view are not in the capture.
        return drawn.keeping { visible.contains($0) }
    }
}

extension ConfirmCardView {
    /// The title's text, the message's first line and the suppression checkbox's label.
    @_spi(Testing) public func drawnText() -> DrawnText {
        var drawn = DrawnText(titles: [titleTextFrame], secondary: messageLineFrame.map { [$0] } ?? [])
        if let suppression, let frame = suppression.labelTextFrame {
            drawn.titles.append(convert(frame, from: suppression))
        }
        return drawn
    }
}

extension EmptyStateView {
    /// The title's text and the hint's first line.
    @_spi(Testing) public func drawnText() -> DrawnText {
        DrawnText(titles: [titleTextFrame], secondary: hintLineFrame.map { [$0] } ?? [])
    }
}

extension QueryField {
    /// The typed text of the text argument chips.
    @_spi(Testing) public func drawnText() -> DrawnText {
        DrawnText(titles: argumentChips.compactMap { chip in chip.textFrame.map { convert($0, from: chip) } })
    }
}

extension NSTextField {
    /// Where a one-line field or label draws its text: the text's width at its alignment, one
    /// line tall, centred in the frame. In the field's own coordinates.
    var oneLineTextFrame: CGRect? {
        guard !stringValue.isEmpty, let font else { return nil }
        let width = min(bounds.width, ceil(attributedStringValue.size().width))
        let height = ceil(font.ascender - font.descender)
        let x: CGFloat =
            switch alignment {
            case .right: bounds.width - width - 2
            case .center: (bounds.width - width) / 2
            default: 2
            }
        return CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

extension HUDWindow {
    /// The HUD's text in screen coordinates.
    @_spi(Testing) public var textScreenFrame: CGRect? {
        guard let label = textLabel else { return nil }
        return convertToScreen(label.convert(label.bounds, to: nil))
    }
}

extension DrawnText {
    static func frame(_ placed: RowTypeset.PlacedLine, font: CTFont) -> CGRect {
        let ascent = CTFontGetAscent(font)
        return CGRect(
            x: placed.origin.x, y: placed.origin.y - ascent, width: RowTypesetter.lineWidth(placed.line),
            height: ascent + CTFontGetDescent(font))
    }

    /// Only the frames that pass `test`.
    func keeping(_ test: (CGRect) -> Bool) -> DrawnText {
        DrawnText(
            titles: titles.filter(test), selectedTitles: selectedTitles.filter(test), secondary: secondary.filter(test),
            headers: headers.filter(test), capsules: capsules.filter(test), messages: messages.filter(test))
    }

    /// The same frames moved from `view`'s coordinates to `other`'s.
    @MainActor func converted(from view: NSView, to other: NSView) -> DrawnText {
        func move(_ rects: [CGRect]) -> [CGRect] { rects.map { other.convert($0, from: view) } }
        return DrawnText(
            titles: move(titles), selectedTitles: move(selectedTitles), secondary: move(secondary),
            headers: move(headers), capsules: move(capsules), messages: move(messages))
    }
}
