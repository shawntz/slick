import Testing

@testable import Windows

@Suite("Frames and displays", .timeLimit(.minutes(1)))
struct FrameAndDisplayTests {
    @Test func snappingMovesEachEdgeToTheNearestPixel() {
        let frame = Frame(minX: 10.2, minY: 20.74, maxX: 100.26, maxY: 50.5)
        #expect(frame.snapped(scale: 1) == Frame(minX: 10, minY: 21, maxX: 100, maxY: 51))
        #expect(frame.snapped(scale: 2) == Frame(minX: 10, minY: 20.5, maxX: 100.5, maxY: 50.5))
        #expect(isOnPixelGrid(frame.snapped(scale: 3), scale: 3))
    }

    @Test func snappingKeepsWholeNumberGapsBetweenNeighbors() {
        // Two edges a whole number of points apart stay that far apart, wherever the pair sits,
        // including across zero, where rounding half away from zero would break the rule.
        for scale in [1.0, 2, 3] {
            for start in stride(from: -3.0, through: 3.0, by: 0.125) {
                for gap in [0.0, 1, 5, 7, 8] {
                    let left = Frame(minX: -100, minY: 0, maxX: start - gap / 2, maxY: 10).snapped(scale: scale)
                    let right = Frame(minX: start + gap / 2, minY: 0, maxX: 100, maxY: 10).snapped(scale: scale)
                    #expect(abs(right.minX - left.maxX - gap) < 1e-9, "scale \(scale), start \(start), gap \(gap)")
                }
            }
        }
    }

    @Test func insetNeverTurnsInsideOut() {
        #expect(Frame(x: 0, y: 0, width: 100, height: 50).inset(by: 10) == Frame(x: 10, y: 10, width: 80, height: 30))
        let tiny = Frame(x: 0, y: 0, width: 10, height: 4).inset(by: 10)
        #expect(tiny.width == 0 && tiny.height == 0)
        #expect(tiny.midX == 5 && tiny.midY == 2)
    }

    @Test func intersectionAndCloseness() {
        let a = Frame(x: 0, y: 0, width: 100, height: 100)
        #expect(
            a.intersection(Frame(x: 50, y: 50, width: 100, height: 100)) == Frame(x: 50, y: 50, width: 50, height: 50))
        #expect(a.intersection(Frame(x: 100, y: 0, width: 10, height: 10)) == nil)
        #expect(a.isClose(to: Frame(x: 1, y: -2, width: 100, height: 101)))
        #expect(!a.isClose(to: Frame(x: 3, y: 0, width: 100, height: 100)))
    }

    @Test func appKitDisplaysFlipIntoTheAccessibilitySpace() {
        let main = 982.0
        let laptop = Display.fromAppKit(
            id: 1, frame: Frame(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: Frame(x: 0, y: 70, width: 1512, height: 879), scale: 2, mainHeight: main)
        #expect(laptop == Displays.laptop)
        let right = Display.fromAppKit(
            id: 2, frame: Frame(x: 1512, y: -98, width: 1920, height: 1080),
            visibleFrame: Frame(x: 1512, y: -98, width: 1920, height: 1055), scale: 1, mainHeight: main)
        #expect(right == Displays.rightExternal)
        let above = Display.fromAppKit(
            id: 4, frame: Frame(x: 200, y: 982, width: 1080, height: 1920),
            visibleFrame: Frame(x: 200, y: 982, width: 1080, height: 1895), scale: 2, mainHeight: main)
        #expect(above == Displays.portraitAbove)
        let below = Display.fromAppKit(
            id: 7, frame: Frame(x: -204, y: -1080, width: 1920, height: 1080),
            visibleFrame: Frame(x: -204, y: -1080, width: 1920, height: 1055), scale: 1, mainHeight: main)
        #expect(below == Displays.belowExternal)
    }

    @Test func aWindowBelongsToTheDisplayHoldingMostOfIt() {
        let desk = [Displays.laptop, Displays.rightExternal]
        #expect(desk.holding(Frame(x: 1400, y: 100, width: 400, height: 300)) == Displays.rightExternal)
        #expect(desk.holding(Frame(x: 1300, y: 100, width: 400, height: 300)) == Displays.laptop)
        // Off every display: the nearest one.
        #expect(desk.holding(Frame(x: 5000, y: 100, width: 400, height: 300)) == Displays.rightExternal)
        #expect(desk.holding(Frame(x: -900, y: 100, width: 400, height: 300)) == Displays.laptop)
        #expect([Display]().holding(Frame(x: 0, y: 0, width: 1, height: 1)) == nil)
    }

    @Test func displaysAreWalkedLeftToRightThenTopToBottom() {
        let ordered = [Displays.rightExternal, Displays.laptop, Displays.leftExternal, Displays.portraitAbove]
            .spatiallyOrdered
        #expect(ordered.map(\.id) == [3, 1, 4, 2])
    }

    @Test func neighborsInEachDirection() {
        let row = [Displays.leftExternal, Displays.laptop, Displays.rightExternal]
        #expect(row.neighbor(of: Displays.laptop, toward: .left) == Displays.leftExternal)
        #expect(row.neighbor(of: Displays.laptop, toward: .right) == Displays.rightExternal)
        #expect(row.neighbor(of: Displays.laptop, toward: .top) == nil)
        #expect(row.neighbor(of: Displays.rightExternal, toward: .right) == nil)
        let stack = [Displays.laptop, Displays.portraitAbove, Displays.belowExternal]
        #expect(stack.neighbor(of: Displays.laptop, toward: .top) == Displays.portraitAbove)
        #expect(stack.neighbor(of: Displays.laptop, toward: .bottom) == Displays.belowExternal)
        #expect(stack.neighbor(of: Displays.portraitAbove, toward: .bottom) == Displays.laptop)
    }

    @Test func edgesFaceEachOther() {
        #expect(Edge.allCases.map(\.opposite) == [.right, .left, .bottom, .top])
    }
}
