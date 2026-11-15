import Testing

@testable import Windows

/// The regions that tile a display: halves, quarters and thirds, with and without gaps, on every
/// display shape and scale in the fixtures.
@Suite("Regions", .timeLimit(.minutes(1)))
struct RegionTests {
    static let gapPairs: [(screen: Double, window: Double)] = [(0, 0), (10, 8), (0, 7), (5, 0), (13, 11), (48, 48)]

    func frame(_ region: Region, on display: Display, screen: Double = 0, window: Double = 0) -> Frame {
        region.frame(in: display.layoutArea(screenGap: screen), windowGap: window, scale: display.scale)
    }

    @Test func halvesOfTheLaptopWithoutGaps() {
        let laptop = Displays.laptop
        #expect(
            frame(Layout.halfRegion(.left, fraction: 0.5), on: laptop) == Frame(x: 0, y: 33, width: 756, height: 879))
        #expect(
            frame(Layout.halfRegion(.right, fraction: 0.5), on: laptop) == Frame(x: 756, y: 33, width: 756, height: 879)
        )
        #expect(
            frame(Layout.halfRegion(.top, fraction: 0.5), on: laptop) == Frame(x: 0, y: 33, width: 1512, height: 439.5))
        #expect(
            frame(Layout.halfRegion(.bottom, fraction: 0.5), on: laptop)
                == Frame(x: 0, y: 472.5, width: 1512, height: 439.5))
    }

    @Test func halvesWithGapsEndOneWindowGapApart() {
        let laptop = Displays.laptop
        let left = frame(Layout.halfRegion(.left, fraction: 0.5), on: laptop, screen: 10, window: 8)
        let right = frame(Layout.halfRegion(.right, fraction: 0.5), on: laptop, screen: 10, window: 8)
        #expect(left == Frame(x: 10, y: 43, width: 742, height: 859))
        #expect(right == Frame(x: 760, y: 43, width: 742, height: 859))
    }

    @Test func halvesOnAWholePointDisplayStayOnWholePoints() {
        let display = Displays.oddSmall
        let top = frame(Layout.halfRegion(.top, fraction: 0.5), on: display)
        let bottom = frame(Layout.halfRegion(.bottom, fraction: 0.5), on: display)
        #expect(top == Frame(x: 0, y: 25, width: 1366, height: 350))
        #expect(bottom == Frame(x: 0, y: 375, width: 1366, height: 349))
        let left = frame(Layout.halfRegion(.left, fraction: 0.5), on: display, window: 7)
        let right = frame(Layout.halfRegion(.right, fraction: 0.5), on: display, window: 7)
        #expect(left.maxX == 680 && right.minX == 687)
    }

    @Test func cycleStepsOfEachHalf() {
        let laptop = Displays.laptop
        let lefts = Layout.halfFractions.map { frame(Layout.halfRegion(.left, fraction: $0), on: laptop) }
        #expect(lefts.map(\.width) == [756, 1008, 504])
        #expect(lefts.allSatisfy { $0.minX == 0 })
        let rights = Layout.halfFractions.map { frame(Layout.halfRegion(.right, fraction: $0), on: laptop) }
        #expect(rights.map(\.width) == [756, 1008, 504])
        #expect(rights.allSatisfy { $0.maxX == 1512 })
        let bottoms = Layout.halfFractions.map { frame(Layout.halfRegion(.bottom, fraction: $0), on: laptop) }
        #expect(bottoms.allSatisfy { $0.maxY == 912 })
        #expect(bottoms.map(\.height) == [439.5, 586, 293])
    }

    @Test(arguments: Displays.singles)
    func halvesAndQuartersTileEveryDisplay(_ display: Display) {
        for gaps in Self.gapPairs {
            let area = display.layoutArea(screenGap: gaps.screen)
            func f(_ region: Region) -> Frame { frame(region, on: display, screen: gaps.screen, window: gaps.window) }
            let left = f(Layout.halfRegion(.left, fraction: 0.5))
            let right = f(Layout.halfRegion(.right, fraction: 0.5))
            let top = f(Layout.halfRegion(.top, fraction: 0.5))
            let bottom = f(Layout.halfRegion(.bottom, fraction: 0.5))
            let context = "\(display.id) gaps \(gaps)"
            #expect(left.minX == area.minX && right.maxX == area.maxX, "\(context)")
            #expect(abs(right.minX - left.maxX - gaps.window) < 1e-9, "\(context)")
            #expect(top.minY == area.minY && bottom.maxY == area.maxY, "\(context)")
            #expect(abs(bottom.minY - top.maxY - gaps.window) < 1e-9, "\(context)")

            let topLeft = f(Layout.quarterRegion(.topLeft))
            let topRight = f(Layout.quarterRegion(.topRight))
            let bottomLeft = f(Layout.quarterRegion(.bottomLeft))
            let bottomRight = f(Layout.quarterRegion(.bottomRight))
            #expect(abs(topRight.minX - topLeft.maxX - gaps.window) < 1e-9, "\(context)")
            #expect(abs(bottomLeft.minY - topLeft.maxY - gaps.window) < 1e-9, "\(context)")
            #expect(topLeft.maxX == bottomLeft.maxX && topRight.minX == bottomRight.minX, "\(context)")
            #expect(topLeft.maxY == topRight.maxY && bottomLeft.minY == bottomRight.minY, "\(context)")
            #expect(topLeft.minX == area.minX && topLeft.minY == area.minY, "\(context)")
            #expect(bottomRight.maxX == area.maxX && bottomRight.maxY == area.maxY, "\(context)")
            // Quarters line up with halves.
            #expect(topLeft.maxX == left.maxX && bottomRight.minY == bottom.minY, "\(context)")
            for frame in [left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight] {
                #expect(isOnPixelGrid(frame, scale: display.scale), "\(context) \(frame)")
                #expect(contains(area, frame, slack: 0), "\(context) \(frame)")
            }
        }
    }

    @Test(arguments: Displays.singles)
    func thirdsTileAlongTheLongSide(_ display: Display) {
        let portrait = display.visibleFrame.isPortrait
        for gaps in Self.gapPairs {
            let area = display.layoutArea(screenGap: gaps.screen)
            func f(_ slot: ThirdsSlot) -> Frame {
                frame(slot.region(portrait: portrait), on: display, screen: gaps.screen, window: gaps.window)
            }
            // Measure along the long side: x on a landscape display, y on a portrait one.
            func start(_ frame: Frame) -> Double { portrait ? frame.minY : frame.minX }
            func end(_ frame: Frame) -> Double { portrait ? frame.maxY : frame.maxX }
            let context = "\(display.id) gaps \(gaps)"
            let first = f(.first)
            let center = f(.center)
            let last = f(.last)
            #expect(start(first) == (portrait ? area.minY : area.minX), "\(context)")
            #expect(end(last) == (portrait ? area.maxY : area.maxX), "\(context)")
            #expect(abs(start(center) - end(first) - gaps.window) < 1e-9, "\(context)")
            #expect(abs(start(last) - end(center) - gaps.window) < 1e-9, "\(context)")
            #expect(abs(start(last) - end(f(.firstTwo)) - gaps.window) < 1e-9, "\(context)")
            #expect(abs(start(f(.lastTwo)) - end(first) - gaps.window) < 1e-9, "\(context)")
            // Center two thirds sits in the middle, within a pixel.
            let centerTwo = f(.centerTwo)
            let middle = portrait ? area.midY : area.midX
            #expect(abs((start(centerTwo) + end(centerTwo)) / 2 - middle) <= 1, "\(context)")
            for slot in ThirdsSlot.allCases {
                #expect(isOnPixelGrid(f(slot), scale: display.scale), "\(context) \(slot)")
                #expect(contains(area, f(slot), slack: 0), "\(context) \(slot)")
            }
        }
    }

    @Test func thirdsStackOnAPortraitDisplay() {
        let display = Displays.portraitAbove
        let first = frame(ThirdsSlot.first.region(portrait: true), on: display)
        #expect(first.width == display.visibleFrame.width)
        #expect(first.minY == display.visibleFrame.minY)
        #expect(abs(first.height - display.visibleFrame.height / 3) <= 0.5)
    }

    @Test func aHugeGapNeverInvertsARegion() {
        let display = Displays.oddSmall
        let region = Layout.quarterRegion(.topLeft)
        let squeezed = region.frame(
            in: Frame(x: 0, y: 0, width: 40, height: 40), windowGap: 400, scale: display.scale)
        #expect(squeezed.width > 0 && squeezed.height > 0)
    }

    @Test func everyRegionIsListedOnceForNextDisplay() {
        let regions = Layout.regions(portrait: false)
        // Full, 4 edges x 3 steps, 4 quarters, 6 thirds.
        #expect(regions.count == 1 + 12 + 4 + 6)
        // A left third is also a first third, so a few entries may coincide, but no more than that.
        #expect(Set(regions).count >= 19)
    }
}
