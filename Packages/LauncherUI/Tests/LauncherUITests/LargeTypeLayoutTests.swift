import AppKit
import Testing

@testable import LauncherUI

/// Large Type's layout over texts from one digit to a long paragraph, on screens from small to
/// very large. Measured with AppKit's text system; no window is made.
@Suite("Large Type: layout", .timeLimit(.minutes(1)))
@MainActor struct LargeTypeLayoutTests {
    /// Visible frames of common screens, with a menu bar and a Dock taken off.
    nonisolated static let screens: [CGRect] = [
        CGRect(x: 0, y: 70, width: 1024, height: 673),
        CGRect(x: 0, y: 0, width: 1440, height: 875),
        CGRect(x: 1440, y: -200, width: 2560, height: 1415),
        CGRect(x: 0, y: 0, width: 3840, height: 2135),
    ]

    nonisolated static let digit = "7"
    nonisolated static let code = "482 913"
    nonisolated static let phone = "+1 555 0100 0199"
    nonisolated static let sentence = "Meet at the north entrance of the station at half past nine."
    nonisolated static let paragraph = String(
        repeating: "The quick brown fox jumps over the lazy dog while the synthetic text runs on. ", count: 8)
    nonisolated static let huge = String(repeating: "word ", count: 2_000)

    private let font = LargeTypeStyle(theme: .standard, accessibility: DisplayAccessibility()).font
    private let metrics = LargeTypeMetrics.standard

    private func layout(_ text: String, _ screen: CGRect) -> LargeTypeLayout {
        LargeTypeLayout.make(text, screen: screen, font: font)
    }

    @Test(arguments: screens, [digit, code, phone, sentence, paragraph, huge])
    func theTextFitsItsLimitsAndTheBackingIsCenteredOnTheScreen(screen: CGRect, text: String) {
        let layout = layout(text, screen)
        #expect(layout.textFrame.width <= screen.width * metrics.widthFraction + 1)
        #expect(layout.textFrame.height <= screen.height * metrics.heightFraction + 1)
        #expect(layout.fontSize >= metrics.minimumSize)
        #expect(layout.fontSize <= max(metrics.minimumSize, screen.height * metrics.maximumSizeFraction) + 0.5)
        #expect(screen.insetBy(dx: -1, dy: -1).contains(layout.frame), "the backing stays on the screen")
        #expect(abs(layout.frame.midX - screen.midX) <= 1)
        #expect(abs(layout.frame.midY - screen.midY) <= 1)
        #expect(layout.textFrame.minX >= metrics.minimumPadding)
        #expect(layout.frame.width >= layout.textFrame.maxX + metrics.minimumPadding - 1)
        if !layout.isCut {
            // What draws fits the box the backing leaves for it.
            let drawn = LargeTypeLayout.measure(
                layout.text, font: font, size: layout.fontSize,
                width: layout.wraps ? screen.width * metrics.widthFraction : nil)
            #expect(drawn.width <= layout.textFrame.width + 1)
            #expect(drawn.height <= layout.textFrame.height + 1)
        }
    }

    @Test(arguments: screens)
    func shortTextStaysOnOneLineAndLongTextWraps(screen: CGRect) {
        for text in [Self.digit, Self.code, Self.phone] {
            let layout = layout(text, screen)
            #expect(!layout.wraps, "\(text) on one line")
            #expect(
                LargeTypeLayout.measure(text, font: font, size: layout.fontSize, width: nil).height
                    <= layout.fontSize * 1.5, "one line high")
        }
        for text in [Self.sentence, Self.paragraph] {
            #expect(layout(text, screen).wraps, "\(text.prefix(20)) wraps")
        }
    }

    @Test(arguments: screens)
    func aDigitIsCappedAndShorterTextIsNeverSmaller(screen: CGRect) {
        let digit = layout(Self.digit, screen)
        #expect(abs(digit.fontSize - (screen.height * metrics.maximumSizeFraction).rounded(.down)) <= 1)
        let unwrapped = [Self.digit, Self.code, Self.phone].map { layout($0, screen).fontSize }
        #expect(unwrapped == unwrapped.sorted(by: >))
        let wrapped = [Self.sentence, Self.paragraph].map { layout($0, screen).fontSize }
        #expect(wrapped == wrapped.sorted(by: >))
    }

    @Test(arguments: [code, phone, sentence, paragraph])
    func aLargerScreenNeverShowsSmallerText(text: String) {
        let sizes = Self.screens.map { layout(text, $0).fontSize }
        #expect(sizes == sizes.sorted())
    }

    @Test func aPhoneNumberUsesMostOfTheWidth() {
        let screen = Self.screens[1]
        let layout = layout(Self.phone, screen)
        #expect(layout.textFrame.width >= screen.width * metrics.widthFraction * 0.9)
    }

    @Test func veryLongTextIsCutWithAnEllipsis() {
        let layout = layout(Self.huge, Self.screens[0])
        #expect(layout.text.count == metrics.maximumCharacters + 1)
        #expect(layout.text.hasSuffix("…"))
        #expect(layout.wraps)
        #expect(layout.isCut)
        #expect(layout.fontSize == metrics.minimumSize)
    }

    @Test func spacesAndLineBreaksAroundTheTextAreLeftOutAndInnerLinesKept() {
        let layout = layout("\n  555 0100\n0199  \n", Self.screens[1])
        #expect(layout.text == "555 0100\n0199")
        #expect(!layout.wraps)
        let oneLine = LargeTypeLayout.measure("555 0100", font: font, size: layout.fontSize, width: nil).height
        #expect(layout.textFrame.height >= oneLine * 2 - 1, "two lines")
    }

    @Test func aWordWiderThanTheScreenStillLaysOut() {
        let word = String(repeating: "x", count: 400)
        let layout = layout(word, Self.screens[0])
        #expect(layout.wraps)
        #expect(layout.textFrame.width <= Self.screens[0].width * metrics.widthFraction + 1)
    }
}
