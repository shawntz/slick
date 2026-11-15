import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// The list draws its own rows, so it describes them to accessibility by hand. These tests read
/// that description through the `NSAccessibility` protocol, in process. A test runner cannot
/// serve the `AXUIElement` API (it never finishes launching as an app), so the same checks run
/// through that API in the demo app: `scripts/ui-demo.sh accessibility`.
@Suite(.timeLimit(.minutes(1)))
struct AccessibilityTests {
    @Test func rowsAndHeadersAreExposed() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(SyntheticCatalog().rootContent())
        list.select(1, animated: false)
        var activated: [Int] = []
        list.onActivate = { activated.append($0) }

        #expect(list.accessibilityRole() == .list)
        let items = try #require(list.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(items.count == 11, "two headers and nine rows")
        #expect(items[0].accessibilityRole() == .staticText)
        #expect(items[0].accessibilityLabel() == "Suggested")
        #expect(items[1].accessibilityRole() == .button)
        #expect(items[1].accessibilityLabel() == "Aurora Notes, Application")
        #expect(items[1].accessibilityHelp() == "⌘1")
        #expect(items[2].isAccessibilitySelected())
        #expect(!items[1].isAccessibilitySelected())
        #expect((list.accessibilitySelectedChildren() as? [NSAccessibilityElement])?.first === items[2])
        #expect(items[3].accessibilityPerformPress())
        #expect(activated == [2])
    }

    @Test func rowFramesAreInScreenCoordinates() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(SyntheticCatalog().rootContent())
        let items = try #require(list.accessibilityChildren() as? [NSAccessibilityElement])
        let expected = window.convertToScreen(list.convert(try #require(list.rowRect(0)), to: nil))
        #expect(items[1].accessibilityFrame() == expected)
    }

    @Test func selectingThroughAccessibilityReportsIt() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(SyntheticCatalog().rootContent())
        var selected: [Int] = []
        list.onSelect = { selected.append($0) }
        let items = try #require(list.accessibilityChildren() as? [NSAccessibilityElement])
        items[4].setAccessibilitySelected(true)
        #expect(list.selectedRow == 3)
        #expect(selected == [3])
    }

    @Test func elementsAreBuiltOnlyWhenAsked() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(SyntheticCatalog().rootContent())
        #expect(list.accessibilityCache == nil)
        _ = list.accessibilityChildren()
        #expect(list.accessibilityCache?.count == 11)
        list.apply(SyntheticCatalog().content(for: "no"))
        #expect(list.accessibilityCache == nil)
    }
}
