import AppKit
import Foundation
import Host
import Kit
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Pure mapping from Kit values to LauncherUI values, and the content container's sizing.
@Suite("Mapping")
@MainActor struct MappingTests {
    @Test func relativeDatesReadLikeAccessories() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RowMapper.relative(now.addingTimeInterval(-30), now: now) == "now")
        #expect(RowMapper.relative(now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(RowMapper.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
        #expect(RowMapper.relative(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
        #expect(RowMapper.relative(now.addingTimeInterval(-15 * 86_400), now: now) == "2w")
        #expect(RowMapper.relative(now.addingTimeInterval(-400 * 86_400), now: now) == "1y")
        #expect(RowMapper.relative(now.addingTimeInterval(10 * 60), now: now) == "in 10m")
    }

    @Test func keycapsFollowTheSystemOrder() {
        #expect(RowMapper.keycaps(KeyCombo(.k, [.command, .shift, .control])) == ["⌃", "⇧", "⌘", "K"])
        #expect(RowMapper.keycaps(.secondaryAction) == ["⌘", "↩"])
    }

    @Test func coloursAndRangesMap() {
        #expect(RowMapper.themeColor(.secondary) == ThemeColor(.secondaryLabel))
        #expect(RowMapper.themeColor(.purple) == ThemeColor(.purple))
        #expect(
            RowMapper.themeColor(.rgba(red: 1, green: 0, blue: 0, alpha: 0.5))
                == ThemeColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(
            RowMapper.ranges([2..<5, 7..<8]) == [
                HighlightRange(location: 2, length: 3), HighlightRange(location: 7, length: 1),
            ])
    }

    @Test func aRowMapsWithItsIconOrAPlaceholder() {
        let icons = FakeIconProvider()
        let mapper = RowMapper(icons: icons, clock: FakeClock())
        let row = Row(id: ItemID("demo", "1"), title: "One", subtitle: "Sub", icon: .symbol("star"))
        let mapped = mapper.listRow(row, highlights: [0..<1])
        #expect(mapped.id == row.id.engineKey)
        #expect(mapped.subtitle == "Sub")
        #expect(mapped.icon != nil)
        #expect(mapped.titleHighlights == [HighlightRange(location: 0, length: 1)])
        icons.holdBack(.symbol("star"))
        #expect(mapper.listRow(row).icon == nil, "a missing icon is a placeholder, never a wait")
    }

    @Test func fixedSizingReportsOneHeightWhateverItShows() {
        _ = NSApplication.shared
        let view = PageContentView(frame: CGRect(x: 0, y: 0, width: 750, height: 500))
        let list = ResultListView()
        view.show(list)
        view.sizing = .fixed(468)
        #expect(view.preferredContentHeight(limit: 500) == 468)
        #expect(list.frame.height == 468)
        view.show(EmptyStateView())
        #expect(view.preferredContentHeight(limit: 500) == 468)
        var changes = 0
        view.onHeightChange = { changes += 1 }
        view.sizing = .fitContent
        #expect(changes == 1)
        #expect(view.preferredContentHeight(limit: 500) == 0, "an empty state with no theme yet is empty")
    }
}
