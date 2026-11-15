import Testing

@testable import Windows

/// One test or more for each layout, with exact frames on the laptop fixture: 1512 by 982 points at
/// scale 2, whose visible frame starts 33 points down and is 879 points tall.
@Suite("Layout planner", .timeLimit(.minutes(1)))
struct PlannerTests {
    let laptop = [Displays.laptop]
    let desk = [Displays.laptop, Displays.rightExternal]
    let small = window(Frame(x: 300, y: 200, width: 800, height: 500))

    // MARK: - Guards

    @Test func refusesFullScreenAndFixedWindows() {
        var fullScreen = small
        fullScreen.isFullScreen = true
        #expect(LayoutPlanner.plan(request(.maximize), window: fullScreen, displays: laptop) == .failure(.fullScreen))
        var stuck = small
        stuck.canMove = false
        #expect(LayoutPlanner.plan(request(.maximize), window: stuck, displays: laptop) == .failure(.cannotMove))
        #expect(LayoutPlanner.plan(request(.maximize), window: small, displays: []) == .failure(.noDisplay))
    }

    // MARK: - Sizes

    @Test func maximizeFillsTheVisibleFrameLessTheScreenGap() throws {
        #expect(try planned(request(.maximize), window: small, displays: laptop).frame == Displays.laptop.visibleFrame)
        let gapped = LayoutOptions(screenGap: 12, windowGap: 30)
        #expect(
            try planned(request(.maximize, options: gapped), window: small, displays: laptop).frame
                == Frame(x: 12, y: 45, width: 1488, height: 855))
    }

    @Test func almostMaximizeCoversItsShareCentered() throws {
        let frame = try planned(request(.almostMaximize), window: small, displays: laptop).frame
        let visible = Displays.laptop.visibleFrame
        #expect(abs(frame.width - visible.width * 0.9) <= 1)
        #expect(abs(frame.height - visible.height * 0.9) <= 1)
        #expect(abs(frame.midX - visible.midX) <= 0.5 && abs(frame.midY - visible.midY) <= 0.5)
        #expect(isOnPixelGrid(frame, scale: 2))

        let half = try planned(
            request(.almostMaximize, options: LayoutOptions(almostMaximizeFraction: 0.5)), window: small,
            displays: laptop
        ).frame
        #expect(half == Frame(x: 378, y: 253, width: 756, height: 439.5))

        // At full size it still keeps the screen gap.
        let full = try planned(
            request(.almostMaximize, options: LayoutOptions(screenGap: 10, almostMaximizeFraction: 1)), window: small,
            displays: laptop
        ).frame
        #expect(full == Displays.laptop.visibleFrame.inset(by: 10))
    }

    @Test func maximizeHeightAndWidthKeepTheOtherAxis() throws {
        #expect(
            try planned(request(.maximizeHeight), window: small, displays: laptop).frame
                == Frame(x: 300, y: 33, width: 800, height: 879))
        #expect(
            try planned(request(.maximizeWidth), window: small, displays: laptop).frame
                == Frame(x: 0, y: 200, width: 1512, height: 500))
        // A window hanging off the right side is pulled in.
        let hanging = window(Frame(x: 1000, y: 100, width: 800, height: 500))
        #expect(try planned(request(.maximizeHeight), window: hanging, displays: laptop).frame.minX == 712)
    }

    @Test func centerKeepsTheSizeAndShrinksOnlyWhatDoesNotFit() throws {
        #expect(
            try planned(request(.center), window: small, displays: laptop).frame
                == Frame(x: 356, y: 222.5, width: 800, height: 500))
        let huge = window(Frame(x: -50, y: 0, width: 2000, height: 1200))
        #expect(try planned(request(.center), window: huge, displays: laptop).frame == Displays.laptop.visibleFrame)
    }

    // MARK: - Edges

    @Test func moveToEachEdgeWithoutResizing() throws {
        func moved(_ edge: Edge, _ frame: Frame = Frame(x: 300, y: 200, width: 800, height: 500)) throws -> Frame {
            try planned(request(.moveToEdge(edge)), window: window(frame), displays: laptop).frame
        }
        #expect(try moved(.left) == Frame(x: 0, y: 200, width: 800, height: 500))
        #expect(try moved(.right) == Frame(x: 712, y: 200, width: 800, height: 500))
        #expect(try moved(.top) == Frame(x: 300, y: 33, width: 800, height: 500))
        #expect(try moved(.bottom) == Frame(x: 300, y: 412, width: 800, height: 500))
        // The other axis is pulled on screen when the window fits.
        #expect(
            try moved(.left, Frame(x: 300, y: 600, width: 800, height: 500))
                == Frame(x: 0, y: 412, width: 800, height: 500))
        #expect(
            try moved(.top, Frame(x: -100, y: 600, width: 800, height: 500))
                == Frame(x: 0, y: 33, width: 800, height: 500))
        let gapped = try planned(
            request(.moveToEdge(.right), options: LayoutOptions(screenGap: 10)), window: small, displays: laptop
        ).frame
        #expect(gapped.maxX == 1502 && gapped.size == small.frame.size)
    }

    // MARK: - Larger and smaller

    @Test func makeLargerAndSmallerShareTheChangeBetweenFreeSides() throws {
        #expect(
            try planned(request(.resize(grow: true)), window: small, displays: laptop).frame
                == Frame(x: 284, y: 184, width: 832, height: 532))
        #expect(
            try planned(request(.resize(grow: false)), window: small, displays: laptop).frame
                == Frame(x: 316, y: 216, width: 768, height: 468))
    }

    @Test func aSideAgainstTheEdgeStaysThere() throws {
        let atLeft = window(Frame(x: 0, y: 200, width: 800, height: 500))
        #expect(try planned(request(.resize(grow: true)), window: atLeft, displays: laptop).frame.minX == 0)
        let atRight = window(Frame(x: 1000, y: 200, width: 512, height: 500))
        let grown = try planned(request(.resize(grow: true)), window: atRight, displays: laptop).frame
        #expect(grown.maxX == 1512 && grown.width == 544)
        // A maximized window shrinks from both sides.
        let maximized = window(Displays.laptop.visibleFrame)
        #expect(
            try planned(request(.resize(grow: false)), window: maximized, displays: laptop).frame
                == Frame(x: 16, y: 49, width: 1480, height: 847))
    }

    @Test func resizingStopsAtTheLimits() throws {
        let maximized = window(Displays.laptop.visibleFrame)
        #expect(
            LayoutPlanner.plan(request(.resize(grow: true)), window: maximized, displays: laptop) == .failure(.atLimit))
        let smallest = window(Frame(x: 300, y: 200, width: 200, height: 150))
        #expect(
            LayoutPlanner.plan(request(.resize(grow: false)), window: smallest, displays: laptop) == .failure(.atLimit))
        let nearly = window(Frame(x: 300, y: 200, width: 210, height: 150))
        #expect(
            try planned(request(.resize(grow: false)), window: nearly, displays: laptop).frame
                == Frame(x: 305, y: 200, width: 200, height: 150))
        // Growing never passes the visible frame.
        let wide = window(Frame(x: 0, y: 200, width: 1500, height: 500))
        #expect(try planned(request(.resize(grow: true)), window: wide, displays: laptop).frame.width == 1512)
    }

    // MARK: - Cycling a half

    func step(_ last: Placement?, at frame: Frame, behavior: RepeatBehavior = .cycleSizes) throws -> PlannedFrame {
        try planned(
            request(.half(.left), command: "left-half", options: LayoutOptions(repeatBehavior: behavior), last: last),
            window: window(frame), displays: laptop)
    }

    let half = Frame(x: 0, y: 33, width: 756, height: 879)
    let twoThirds = Frame(x: 0, y: 33, width: 1008, height: 879)
    let third = Frame(x: 0, y: 33, width: 504, height: 879)

    @Test func aHalfCyclesThroughTwoThirdsAndOneThird() throws {
        var last: Placement?
        var frame = small.frame
        var seen: [Frame] = []
        for _ in 0..<4 {
            let plan = try step(last, at: frame)
            seen.append(plan.frame)
            frame = plan.frame
            last = Placement(command: "left-half", window: "1_1", frame: plan.frame, step: plan.step)
        }
        #expect(seen == [half, twoThirds, third, half])
    }

    @Test func aWindowAlreadyAtTheHalfStartsCyclingWithoutMemory() throws {
        #expect(try step(nil, at: half).frame == twoThirds)
        #expect(try step(nil, at: twoThirds).frame == half, "two thirds from another command is not a repeat")
    }

    @Test func movingTheWindowOrUsingAnotherCommandStartsOver() throws {
        let moved = Placement(command: "left-half", window: "1_1", frame: twoThirds, step: 1)
        #expect(try step(moved, at: Frame(x: 40, y: 33, width: 1008, height: 879)).frame == half)
        let other = Placement(command: "first-two-thirds", window: "1_1", frame: twoThirds, step: 1)
        #expect(try step(other, at: twoThirds).frame == half)
        let otherWindow = Placement(command: "left-half", window: "2_9", frame: twoThirds, step: 1)
        #expect(try step(otherWindow, at: twoThirds).frame == half)
    }

    @Test func aRepeatFollowsTheFrameTheWindowTook() throws {
        // The app kept a minimum width, so the window is wider than two thirds. It still cycles.
        let wider = Frame(x: 0, y: 33, width: 1100, height: 879)
        let last = Placement(command: "left-half", window: "1_1", frame: wider, step: 1)
        #expect(try step(last, at: wider).frame == third)
    }

    @Test func cyclingCanBeTurnedOff() throws {
        #expect(try step(nil, at: half, behavior: .none).frame == half)
        let last = Placement(command: "left-half", window: "1_1", frame: half, step: 0)
        #expect(try step(last, at: half, behavior: .none).step == 0)
    }

    @Test func aRepeatedHalfCanCrossToTheNextDisplay() throws {
        let options = LayoutOptions(repeatBehavior: .moveAcrossDisplays)
        let rightHalf = Frame(x: 756, y: 33, width: 756, height: 879)
        func press(_ last: Placement?, at frame: Frame) throws -> PlannedFrame {
            try planned(
                request(.half(.right), command: "right-half", options: options, last: last), window: window(frame),
                displays: desk)
        }
        // Not yet a half: take the half here.
        #expect(try press(nil, at: small.frame).frame == rightHalf)
        // At the right half: cross to the left half of the display on the right.
        let crossed = try press(nil, at: rightHalf)
        #expect(crossed.frame == Frame(x: 1512, y: 25, width: 960, height: 1055))
        #expect(crossed.step == 1)
        // Pressed again: the right half of that display, then it stays, with no display beyond.
        let last = Placement(command: "right-half", window: "1_1", frame: crossed.frame, step: 1)
        let settled = try press(last, at: crossed.frame)
        #expect(settled.frame == Frame(x: 2472, y: 25, width: 960, height: 1055))
        let again = Placement(command: "right-half", window: "1_1", frame: settled.frame, step: 0)
        #expect(try press(again, at: settled.frame).frame == settled.frame)
    }

    // MARK: - Displays

    @Test func nextDisplayKeepsARegionWithExactGaps() throws {
        let options = LayoutOptions(screenGap: 10, windowGap: 8)
        let leftHalf = Frame(x: 10, y: 43, width: 742, height: 859)
        let moved = try planned(
            request(.display(offset: 1), options: options), window: window(leftHalf), displays: desk)
        #expect(moved.frame == Frame(x: 1522, y: 35, width: 946, height: 1035))
        #expect(moved.scale == 1)
    }

    @Test func nextDisplayScalesAnyOtherFrame() throws {
        // A quarter of the way in, half the size, on the laptop.
        let frame = Frame(x: 378, y: 252.75, width: 756, height: 439.5)
        let moved = try planned(request(.display(offset: 1)), window: window(frame), displays: desk).frame
        #expect(moved.isClose(to: Frame(x: 1992, y: 288.75, width: 960, height: 527.5), tolerance: 1))
        #expect(isOnPixelGrid(moved, scale: 1))
    }

    @Test func aWindowMovedToASmallerDisplayStaysInside() throws {
        let desk = [Displays.leftExternal, Displays.laptop]
        let big = window(Frame(x: -2500, y: -150, width: 2400, height: 1380))
        let moved = try planned(request(.display(offset: 1)), window: big, displays: desk).frame
        #expect(contains(Displays.laptop.visibleFrame, moved))
    }

    @Test func nextAndPreviousWrapAround() throws {
        let row = [Displays.rightExternal, Displays.leftExternal, Displays.laptop]
        let onRight = window(Frame(x: 2000, y: 200, width: 800, height: 500))
        let next = try planned(request(.display(offset: 1)), window: onRight, displays: row)
        #expect(row.holding(next.frame) == Displays.leftExternal)
        let onLeft = window(Frame(x: -2000, y: 0, width: 800, height: 500))
        let previous = try planned(request(.display(offset: -1)), window: onLeft, displays: row)
        #expect(row.holding(previous.frame) == Displays.rightExternal)
        #expect(
            LayoutPlanner.plan(request(.display(offset: 1)), window: small, displays: laptop)
                == .failure(.onlyOneDisplay))
    }

    @Test func nextDisplayToAPortraitDisplayAbove() throws {
        let desk = [Displays.laptop, Displays.portraitAbove]
        let moved = try planned(request(.display(offset: 1)), window: window(half), displays: desk)
        // The left half stays the left half on the portrait display.
        #expect(moved.frame == Frame(x: 200, y: -1895, width: 540, height: 1895))
    }

    // MARK: - Restore

    @Test func restoreReturnsTheRememberedFrame() throws {
        let original = Frame(x: 123, y: 145, width: 640, height: 480)
        let plan = try planned(request(.restore, restore: ["1_1": original]), window: window(half), displays: laptop)
        #expect(plan.frame == original)
        #expect(
            LayoutPlanner.plan(request(.restore), window: window(half), displays: laptop) == .failure(.nothingToRestore)
        )
    }

    @Test func restoreOntoADisplayThatIsGoneLandsOnScreen() throws {
        let lost = Frame(x: 4000, y: 100, width: 640, height: 480)
        let plan = try planned(request(.restore, restore: ["1_1": lost]), window: window(half), displays: desk)
        #expect(contains(Displays.rightExternal.visibleFrame, plan.frame))
        #expect(plan.frame.size == lost.size)
    }

    // MARK: - Settling after a refused size

    @Test func aWindowThatStaysLargerKeepsItsAnchoredSide() {
        let area = Displays.laptop.visibleFrame
        let wide = Size(width: 900, height: 879)
        #expect(LayoutPlanner.settled(wide, planned: half, area: area) == Frame(x: 0, y: 33, width: 900, height: 879))
        let rightHalf = Frame(x: 756, y: 33, width: 756, height: 879)
        #expect(
            LayoutPlanner.settled(wide, planned: rightHalf, area: area) == Frame(x: 612, y: 33, width: 900, height: 879)
        )
        let centerThird = Frame(x: 504, y: 33, width: 504, height: 879)
        #expect(LayoutPlanner.settled(Size(width: 600, height: 879), planned: centerThird, area: area).minX == 456)
        let topHalf = Frame(x: 0, y: 33, width: 1512, height: 439.5)
        #expect(LayoutPlanner.settled(Size(width: 1512, height: 600), planned: topHalf, area: area).minY == 33)
        let bottomHalf = Frame(x: 0, y: 472.5, width: 1512, height: 439.5)
        #expect(LayoutPlanner.settled(Size(width: 1512, height: 600), planned: bottomHalf, area: area).minY == 312)
    }

    @Test func aWindowLargerThanTheScreenStartsAtItsEdge() {
        let area = Displays.laptop.visibleFrame
        let settled = LayoutPlanner.settled(
            Size(width: 1600, height: 1000), planned: Frame(x: 756, y: 33, width: 756, height: 879), area: area)
        #expect(settled.minX == 0 && settled.minY == 33)
    }

    @Test func aWindowThatTookThePlannedSizeStaysPut() {
        let area = Displays.laptop.visibleFrame
        #expect(LayoutPlanner.settled(half.size, planned: half, area: area) == half)
    }
}
