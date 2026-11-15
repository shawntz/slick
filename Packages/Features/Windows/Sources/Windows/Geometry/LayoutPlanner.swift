/// What pressing a half again does when the window is already there.
nonisolated enum RepeatBehavior: String, Hashable, Sendable, CaseIterable {
    /// A half, then two thirds, then one third, then a half again.
    case cycleSizes
    /// The window moves to the display on that side, into the half that faces back.
    case moveAcrossDisplays
    /// The window stays a half.
    case none
}

/// The user's layout settings, as plain values a background thread can read.
nonisolated struct LayoutOptions: Hashable, Sendable {
    /// Points between a window and the edges of the visible frame.
    var screenGap: Double = 0
    /// Points between two windows that share a side.
    var windowGap: Double = 0
    var repeatBehavior: RepeatBehavior = .cycleSizes
    /// The share of the visible frame Almost Maximize covers, from 0.5 to 1.
    var almostMaximizeFraction: Double = 0.9
}

/// A window as the service read it.
nonisolated struct WindowState: Hashable, Sendable {
    /// Identifies the window for as long as it is open. See ``WindowRef``.
    var key: String
    var frame: Frame
    var isFullScreen = false
    /// False when the app does not let anyone move the window.
    var canMove = true
    /// False for fixed-size windows. They still move.
    var canResize = true
}

/// Where the feature last put a window, so the next press of the same command can tell it is a
/// repeat.
nonisolated struct Placement: Hashable, Sendable {
    var command: String
    var window: String
    /// The frame the window took, which may differ from the one asked for.
    var frame: Frame
    var step: Int
}

/// Everything a layout command needs besides the window and the displays. Plain values, so the
/// service can plan, move and check on one background thread in one pass.
nonisolated struct LayoutRequest: Hashable, Sendable {
    var command: String
    var layout: Layout
    var options: LayoutOptions
    var lastPlacement: Placement?
    /// Frames to restore, by window key.
    var restoreFrames: [String: Frame] = [:]
}

/// Why a command left the window where it was.
nonisolated enum Unchanged: Error, Hashable, Sendable {
    case noWindow
    case fullScreen
    case cannotMove
    case noDisplay
    case onlyOneDisplay
    case nothingToRestore
    /// Make Larger at full size, or Make Smaller at the smallest size.
    case atLimit
}

/// The frame a layout asks for, and how to read the result.
nonisolated struct PlannedFrame: Hashable, Sendable {
    var frame: Frame
    /// The area the frame lies in, used to keep a window that refused the size anchored and inside.
    var area: Frame
    var scale: Double
    /// The cycle step, 0 for anything that does not cycle.
    var step: Int
}

/// Turns a command into a frame. Pure: no system calls, no clock, no state. Every case is tested.
nonisolated enum LayoutPlanner {
    /// How far Make Larger and Make Smaller change each dimension, in points.
    static let resizeStep = 32.0
    /// Make Smaller stops at this size.
    static let smallestSize = Size(width: 200, height: 150)

    static func plan(
        _ request: LayoutRequest, window: WindowState, displays: [Display]
    ) -> Result<PlannedFrame, Unchanged> {
        guard !window.isFullScreen else { return .failure(.fullScreen) }
        guard window.canMove else { return .failure(.cannotMove) }
        guard let display = displays.holding(window.frame) else { return .failure(.noDisplay) }
        let options = request.options
        let area = display.layoutArea(screenGap: options.screenGap)
        // A display that reports no usable area, as one can while it is being connected, gets no
        // frame rather than a window of zero size, and is never a target.
        guard display.isUsable(screenGap: options.screenGap) else { return .failure(.noDisplay) }
        let targets = displays.filter { $0.isUsable(screenGap: options.screenGap) }

        func placed(_ frame: Frame, on target: Display = display, step: Int = 0) -> Result<PlannedFrame, Unchanged> {
            .success(
                PlannedFrame(
                    frame: frame, area: target.layoutArea(screenGap: options.screenGap), scale: target.scale,
                    step: step))
        }
        func region(_ region: Region, on target: Display = display) -> Frame {
            region.frame(
                in: target.layoutArea(screenGap: options.screenGap), windowGap: options.windowGap, scale: target.scale)
        }

        switch request.layout {
        case .half(let edge):
            let steps = Layout.halfFractions.map { region(Layout.halfRegion(edge, fraction: $0)) }
            let repeated = repeatedStep(request, window: window, first: steps[0])
            switch options.repeatBehavior {
            case .none:
                return placed(steps[0])
            case .cycleSizes:
                let step = repeated.map { ($0 + 1) % steps.count } ?? 0
                return placed(steps[step], step: step)
            case .moveAcrossDisplays:
                // Step 1 marks a window that just crossed over. Pressed again, it takes the half on
                // its new display before it crosses any further.
                guard repeated == 0, let neighbor = targets.neighbor(of: display, toward: edge) else {
                    return placed(steps[0])
                }
                let facing = region(Layout.halfRegion(edge.opposite, fraction: 0.5), on: neighbor)
                return placed(facing, on: neighbor, step: 1)
            }
        case .quarter(let corner):
            return placed(region(Layout.quarterRegion(corner)))
        case .thirds(let slot):
            return placed(region(slot.region(portrait: display.visibleFrame.isPortrait)))
        case .maximize:
            return placed(region(.full))
        case .almostMaximize:
            let visible = display.visibleFrame
            let fraction = min(max(options.almostMaximizeFraction, 0.1), 1)
            let width = visible.width * fraction
            let height = visible.height * fraction
            let centered = Frame(
                x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
            return placed((centered.intersection(area) ?? area).snapped(scale: display.scale))
        case .maximizeHeight:
            let width = min(window.frame.width, area.width)
            let x = clamp(window.frame.minX, area.minX, area.maxX - width)
            return placed(
                Frame(x: x, y: area.minY, width: width, height: area.height).snappedOrigin(scale: display.scale))
        case .maximizeWidth:
            let height = min(window.frame.height, area.height)
            let y = clamp(window.frame.minY, area.minY, area.maxY - height)
            return placed(
                Frame(x: area.minX, y: y, width: area.width, height: height).snappedOrigin(scale: display.scale))
        case .center:
            let width = min(window.frame.width, area.width)
            let height = min(window.frame.height, area.height)
            let frame = Frame(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
            return placed(frame.snappedOrigin(scale: display.scale))
        case .moveToEdge(let edge):
            return placed(moved(window.frame, to: edge, in: area).snappedOrigin(scale: display.scale))
        case .resize(let grow):
            let frame = resized(window.frame, grow: grow, in: area).snapped(scale: display.scale)
            guard !frame.isClose(to: window.frame, tolerance: 0.5) else { return .failure(.atLimit) }
            return placed(frame)
        case .display(let offset):
            let ordered = targets.spatiallyOrdered
            guard ordered.count > 1, let index = ordered.firstIndex(of: display) else {
                return .failure(.onlyOneDisplay)
            }
            let count = ordered.count
            let target = ordered[((index + offset) % count + count) % count]
            return placed(transfer(window.frame, from: display, to: target, options: options), on: target)
        case .restore:
            guard let frame = request.restoreFrames[window.key] else { return .failure(.nothingToRestore) }
            // The display the window came from may be gone. Then the frame moves onto the nearest one.
            guard let home = targets.holding(frame) else { return .failure(.noDisplay) }
            let onScreen = targets.contains { $0.frame.intersection(frame) != nil }
            return placed(onScreen ? frame : fitted(frame, into: home.visibleFrame), on: home)
        }
    }

    /// The step a repeat of the same command continues from, or nil when this press starts over.
    ///
    /// A press repeats when the feature put this window there with the same command and the window
    /// has not moved since. A window that already sits in the first step also counts, so a half
    /// cycles even after a relaunch.
    static func repeatedStep(_ request: LayoutRequest, window: WindowState, first: Frame) -> Int? {
        if let last = request.lastPlacement, last.command == request.command, last.window == window.key,
            last.frame.isClose(to: window.frame)
        {
            return last.step
        }
        return first.isClose(to: window.frame) ? 0 : nil
    }

    /// Moves a frame against an edge of an area without resizing it. Along the other axis it stays
    /// where it is, pulled inside the area when it fits.
    static func moved(_ frame: Frame, to edge: Edge, in area: Frame) -> Frame {
        var result = frame
        switch edge {
        case .left: result.x = area.minX
        case .right: result.x = area.maxX - frame.width
        case .top: result.y = area.minY
        case .bottom: result.y = area.maxY - frame.height
        }
        switch edge {
        case .left, .right:
            if frame.height <= area.height { result.y = clamp(frame.minY, area.minY, area.maxY - frame.height) }
        case .top, .bottom:
            if frame.width <= area.width { result.x = clamp(frame.minX, area.minX, area.maxX - frame.width) }
        }
        return result
    }

    /// Grows or shrinks a frame by one step on each axis. A side against the area's edge stays
    /// there and the opposite side takes the whole change. Otherwise both sides share it.
    static func resized(_ frame: Frame, grow: Bool, in area: Frame) -> Frame {
        let horizontal = resizedAxis(
            start: frame.minX, length: frame.width, areaStart: area.minX, areaLength: area.width,
            smallest: smallestSize.width, grow: grow)
        let vertical = resizedAxis(
            start: frame.minY, length: frame.height, areaStart: area.minY, areaLength: area.height,
            smallest: smallestSize.height, grow: grow)
        return Frame(x: horizontal.start, y: vertical.start, width: horizontal.length, height: vertical.length)
    }

    private static func resizedAxis(
        start: Double, length: Double, areaStart: Double, areaLength: Double, smallest: Double, grow: Bool
    ) -> (start: Double, length: Double) {
        let newLength: Double
        if grow {
            newLength = length >= areaLength ? length : min(length + resizeStep, areaLength)
        } else {
            newLength = length <= smallest ? length : max(length - resizeStep, smallest)
        }
        let change = newLength - length
        let atStart = abs(start - areaStart) <= 1
        let atEnd = abs(start + length - (areaStart + areaLength)) <= 1
        var newStart: Double
        if atStart && !atEnd {
            newStart = start
        } else if atEnd && !atStart {
            newStart = start - change
        } else {
            newStart = start - change / 2
        }
        if newLength <= areaLength {
            newStart = clamp(newStart, areaStart, areaStart + areaLength - newLength)
        }
        return (newStart, newLength)
    }

    /// The frame on another display, keeping its place relative to the display. A frame in one of
    /// the feature's regions takes the same region there, with exact gaps. Any other frame scales
    /// with the visible frames and is pulled inside.
    static func transfer(_ frame: Frame, from source: Display, to target: Display, options: LayoutOptions) -> Frame {
        let sourceArea = source.layoutArea(screenGap: options.screenGap)
        let targetArea = target.layoutArea(screenGap: options.screenGap)
        for region in Layout.regions(portrait: source.visibleFrame.isPortrait)
        where region.frame(in: sourceArea, windowGap: options.windowGap, scale: source.scale).isClose(to: frame) {
            return region.frame(in: targetArea, windowGap: options.windowGap, scale: target.scale)
        }
        let from = source.visibleFrame
        let to = target.visibleFrame
        let scaled = Frame(
            x: to.minX + (frame.minX - from.minX) / from.width * to.width,
            y: to.minY + (frame.minY - from.minY) / from.height * to.height,
            width: frame.width / from.width * to.width,
            height: frame.height / from.height * to.height)
        return fitted(scaled, into: targetArea).snapped(scale: target.scale)
    }

    /// The frame shrunk to fit the area if it is larger, then moved inside it.
    static func fitted(_ frame: Frame, into area: Frame) -> Frame {
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        return Frame(
            x: clamp(frame.minX, area.minX, area.maxX - width), y: clamp(frame.minY, area.minY, area.maxY - height),
            width: width, height: height)
    }

    /// Where a window that refused the planned size should sit, given the size it took.
    ///
    /// Apps keep a minimum size, and some windows cannot be resized at all. Along each axis whose
    /// size differs, the window keeps the side the plan put against the area's edge: a left half
    /// that stayed wider still starts at the left edge, a right half still ends at the right edge,
    /// and anything else stays centered on the planned frame. Then it is pulled inside the area
    /// when it fits.
    static func settled(_ actual: Size, planned: Frame, area: Frame) -> Frame {
        func axis(
            actual: Double, plannedStart: Double, plannedLength: Double, areaStart: Double, areaLength: Double
        ) -> Double {
            guard abs(actual - plannedLength) > 1 else { return plannedStart }
            let atStart = abs(plannedStart - areaStart) <= 1
            let atEnd = abs(plannedStart + plannedLength - (areaStart + areaLength)) <= 1
            let start: Double
            if atStart && !atEnd {
                start = plannedStart
            } else if atEnd && !atStart {
                start = plannedStart + plannedLength - actual
            } else {
                start = plannedStart + (plannedLength - actual) / 2
            }
            guard actual <= areaLength else { return areaStart }
            return clamp(start, areaStart, areaStart + areaLength - actual)
        }
        return Frame(
            x: axis(
                actual: actual.width, plannedStart: planned.minX, plannedLength: planned.width,
                areaStart: area.minX, areaLength: area.width),
            y: axis(
                actual: actual.height, plannedStart: planned.minY, plannedLength: planned.height,
                areaStart: area.minY, areaLength: area.height),
            width: actual.width, height: actual.height)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}
