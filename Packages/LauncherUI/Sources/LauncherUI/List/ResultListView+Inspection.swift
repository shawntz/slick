import AppKit
import CoreText

/// Where text is drawn, for contrast measurement in captures and for layout tests. Not for hosts.
@_spi(Testing) public struct DrawnTextFrames {
    public var title: CGRect
    /// The title text after the last matched run, which is drawn dimmer while a query is active.
    public var dimmedTitle: CGRect?
    public var subtitle: CGRect?
    /// Plain-text accessories.
    public var accessories: [CGRect]
    /// The text inside tags and keycaps.
    public var capsules: [CGRect]
    /// The Command-digit hint at the end of the row, when the theme shows one.
    public var runHint: CGRect?
}

extension ResultListView {
    /// Where row `index` draws its text, in view coordinates.
    @_spi(Testing) public func textFrames(row index: Int) -> DrawnTextFrames? {
        guard let rect = rowRect(index), let model = row(at: index), let theme else { return nil }
        let typeset = typeset(index, model, height: rect.height, scale: window?.backingScaleFactor ?? 2)
        let offset = { (frame: CGRect) in frame.offsetBy(dx: rect.minX, dy: rect.minY) }
        var dimmed: CGRect?
        if content.emphasizesMatches,
            let last = model.titleHighlights.max(by: { $0.location + $0.length < $1.location + $1.length })
        {
            let start = CTLineGetOffsetForStringIndex(typeset.title.line, last.location + last.length, nil)
            let frame = typeset.titleFrame
            if frame.minX + start < frame.maxX - 1 {
                dimmed = offset(
                    CGRect(
                        x: frame.minX + start, y: frame.minY, width: frame.maxX - frame.minX - start,
                        height: frame.height))
            }
        }
        func frame(_ placed: RowTypeset.PlacedLine, _ font: CTFont) -> CGRect {
            let ascent = CTFontGetAscent(font)
            return offset(
                CGRect(
                    x: placed.origin.x, y: placed.origin.y - ascent, width: RowTypesetter.lineWidth(placed.line),
                    height: ascent + CTFontGetDescent(font)
                ))
        }
        var accessories: [CGRect] = []
        var capsules: [CGRect] = []
        func collect(_ accessory: RowTypeset.Accessory) {
            switch accessory {
            case .text(let placed): accessories.append(frame(placed, theme.accessoryFont))
            case .capsule(_, _, _, let text): capsules.append(frame(text, theme.tagFont))
            case .group(let parts): parts.forEach(collect)
            case .image: break
            }
        }
        typeset.accessories.forEach(collect)
        return DrawnTextFrames(
            title: offset(typeset.titleFrame), dimmedTitle: dimmed, subtitle: typeset.subtitleFrame.map(offset),
            accessories: accessories, capsules: capsules, runHint: typeset.runHint.map { frame($0, theme.runHintFont) }
        )
    }

    /// Where the visible section headers draw their text, in view coordinates.
    @_spi(Testing) public func headerTextFrames() -> [CGRect] {
        guard let theme else { return [] }
        let metrics = theme.theme.list
        let font = theme.sectionHeaderFont
        let ascent = CTFontGetAscent(font)
        return layoutModel.lines.compactMap { line -> CGRect? in
            guard case .header(let section) = line.kind, let title = content.sections[section].headerText else {
                return nil
            }
            let top = CGFloat(line.y) - scrollOffset
            guard top >= 0, top + CGFloat(line.height) <= viewportHeight else { return nil }
            let width = RowTypesetter.lineWidth(
                CTLineCreateWithAttributedString(
                    RowTypesetter.attributed(title, font: font, color: theme.sectionHeader)))
            return CGRect(
                x: metrics.sectionHeaderX, y: top + metrics.sectionHeaderBaseline - ascent, width: width,
                height: ascent + CTFontGetDescent(font))
        }
    }
}
