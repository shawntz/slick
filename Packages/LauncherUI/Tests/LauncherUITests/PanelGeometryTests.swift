import CoreGraphics
import Testing

@testable import LauncherUI

@Suite struct PanelGeometryTests {
    let theme = Theme.standard

    @Test func glassTopSitsAt22PercentAndIsCentred() {
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 900)
        let geometry = PanelGeometry(theme: theme, visibleFrame: visible)
        let insets = theme.panel.shadowInsets
        let glassTop = Double(geometry.windowFrame.maxY) - insets.top
        #expect(glassTop == Double(visible.maxY - visible.height * 0.22).rounded())
        let glassMidX = Double(geometry.windowFrame.minX) + insets.left + theme.panel.width / 2
        #expect(abs(glassMidX - Double(visible.midX)) <= 0.5)
    }

    @Test func windowHoldsTheTallestGlassAndItsShadow() {
        let geometry = PanelGeometry(theme: theme, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 900))
        let insets = theme.panel.shadowInsets
        #expect(Double(geometry.windowFrame.width) == theme.panel.width + insets.left + insets.right)
        #expect(Double(geometry.windowFrame.height) == theme.maxGlassHeight + insets.top + insets.bottom)
        #expect(
            geometry.glassFrame
                == CGRect(x: insets.left, y: insets.top, width: theme.panel.width, height: theme.maxGlassHeight))
    }

    @Test func aShortScreenMovesTheGlassUpToFit() {
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 700)
        let geometry = PanelGeometry(theme: theme, visibleFrame: visible)
        let glassBottom = Double(geometry.windowFrame.minY) + theme.panel.shadowInsets.bottom
        #expect(glassBottom >= Double(visible.minY) + theme.panel.minimumScreenMargin)
    }

    @Test func secondScreenOffsetsAreKept() {
        let visible = CGRect(x: 1512, y: -200, width: 1920, height: 1050)
        let geometry = PanelGeometry(theme: theme, visibleFrame: visible)
        #expect(visible.contains(CGPoint(x: geometry.windowFrame.midX, y: geometry.windowFrame.midY)))
    }
}
