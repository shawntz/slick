import AppKit
import CoreText
import LauncherUITesting
import Testing

@testable import LauncherUI

/// The list keeps typeset lines between updates. A row typeset from the cache must look exactly
/// like one typeset afresh, and the cache must follow the theme.
@Suite(.timeLimit(.minutes(1)))
struct RowLineCacheTests {
    let catalog = SyntheticCatalog()

    @Test func aCachedRowMatchesAFreshOne() {
        let theme = TestSupport.lightTheme
        let cache = RowLineCache()
        var rows = catalog.content(for: "co").sections.flatMap(\.rows)
        rows[0].subtitleColor = CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        rows[1].title = String(repeating: "A title too long to fit beside its accessories ", count: 4)
        for style in [RowStyle.oneLine, .twoLine] {
            for emphasizes in [true, false] {
                for row in rows {
                    func typeset(_ lines: RowLineCache?) -> RowTypeset {
                        RowTypesetter.typeset(
                            row, width: 520, height: 52, style: style, emphasizesMatches: emphasizes, theme: theme,
                            scale: 2, lines: lines)
                    }
                    let fresh = typeset(nil)
                    _ = typeset(cache)
                    let cached = typeset(cache)
                    #expect(Self.describe(cached) == Self.describe(fresh), "\(row.title), \(style)")
                }
            }
        }
        #expect(cache.hits > 0)
    }

    @Test func titlesWithOtherHighlightsAreTypesetAgain() {
        let theme = TestSupport.lightTheme
        let cache = RowLineCache()
        let row = ListRow(id: 1, title: "Cobalt Terminal", titleHighlights: [HighlightRange(location: 0, length: 2)])
        var moved = row
        moved.titleHighlights = [HighlightRange(location: 0, length: 3)]
        for item in [row, moved] {
            let set = RowTypesetter.typeset(
                item, width: 760, height: 44, style: .oneLine, emphasizesMatches: true, theme: theme, scale: 2,
                lines: cache)
            let fresh = RowTypesetter.typeset(
                item, width: 760, height: 44, style: .oneLine, emphasizesMatches: true, theme: theme, scale: 2)
            #expect(Self.describe(set) == Self.describe(fresh))
        }
        #expect(cache.misses == 2)
    }

    @Test func theListStartsOverWhenTheThemeChanges() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.rootContent())
        list.displayIfNeeded()
        #expect(list.lineCache.count > 0)
        list.apply(
            ResolvedTheme(
                theme: .standard, appearance: NSAppearance(named: .darkAqua)!, accessibility: DisplayAccessibility()))
        #expect(list.lineCache.count == 0)
    }

    @Test func theCacheStaysWithinItsLimit() {
        let theme = TestSupport.lightTheme
        let cache = RowLineCache()
        for index in 0..<(RowLineCache.limit * 2) {
            _ = RowTypesetter.typeset(
                ListRow(id: UInt64(index), title: "Item \(index)"), width: 760, height: 44, style: .oneLine,
                emphasizesMatches: false, theme: theme, scale: 2, lines: cache)
        }
        #expect(cache.count <= RowLineCache.limit)
    }

    /// Every drawn line's text, colours and place, and every frame.
    static func describe(_ set: RowTypeset) -> String {
        func line(_ placed: RowTypeset.PlacedLine?) -> String {
            guard let placed else { return "-" }
            let runs = CTLineGetGlyphRuns(placed.line) as? [CTRun] ?? []
            let colors = runs.map { run -> String in
                let attributes = CTRunGetAttributes(run) as NSDictionary
                return String(describing: attributes[kCTForegroundColorAttributeName as String])
            }
            return
                "\(placed.origin) \(RowTypesetter.lineWidth(placed.line)) \(CTLineGetGlyphCount(placed.line)) \(colors)"
        }
        func accessory(_ item: RowTypeset.Accessory) -> String {
            switch item {
            case .text(let placed): "text \(line(placed))"
            case .group(let parts): "group \(parts.map(accessory))"
            case .capsule(let frame, _, _, let text): "capsule \(frame) \(line(text))"
            case .image(_, let frame): "image \(frame)"
            }
        }
        return [
            "\(set.iconFrame)", line(set.title), "\(set.titleFrame)", line(set.subtitle),
            "\(String(describing: set.subtitleFrame))", "\(set.accessories.map(accessory))",
        ].joined(separator: " | ")
    }
}
