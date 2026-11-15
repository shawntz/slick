/// A rectangle in points, in the global space the Accessibility API uses: the origin is the top-left
/// corner of the main display and y grows downward. Displays to the left of or above the main
/// display have negative coordinates.
///
/// The geometry is plain arithmetic on this type, with no system calls, so every layout can be
/// tested on any machine.
nonisolated struct Frame: Hashable, Sendable, Codable, CustomStringConvertible {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A frame from its four edges.
    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var size: Size { Size(width: width, height: height) }
    var area: Double { max(width, 0) * max(height, 0) }
    var isPortrait: Bool { height > width }

    /// The overlap with another frame, or nil when they do not overlap.
    func intersection(_ other: Frame) -> Frame? {
        let minX = max(minX, other.minX)
        let minY = max(minY, other.minY)
        let maxX = min(maxX, other.maxX)
        let maxY = min(maxY, other.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return Frame(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// The frame shrunk by `amount` on every side. It never turns inside out: a side that would
    /// cross the middle stops there.
    func inset(by amount: Double) -> Frame {
        let dx = min(amount, width / 2)
        let dy = min(amount, height / 2)
        return Frame(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// True when every edge is within `tolerance` points of the other frame's. Apps round frames,
    /// so a frame read back is rarely the exact one that was set.
    func isClose(to other: Frame, tolerance: Double = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }

    /// The frame with each edge moved to the nearest device pixel of a display with this scale.
    ///
    /// Edges round half up in pixels, so two neighbors that share a boundary, or sit a whole number
    /// of points apart, still do after rounding. Rounding the origin and size separately would not
    /// keep that promise.
    func snapped(scale: Double) -> Frame {
        let scale = max(scale, 1)
        func snap(_ value: Double) -> Double { (value * scale + 0.5).rounded(.down) / scale }
        return Frame(minX: snap(minX), minY: snap(minY), maxX: snap(maxX), maxY: snap(maxY))
    }

    /// The frame moved so its origin sits on the pixel grid, with its size untouched. For layouts
    /// that keep the window's own size.
    func snappedOrigin(scale: Double) -> Frame {
        let scale = max(scale, 1)
        func snap(_ value: Double) -> Double { (value * scale + 0.5).rounded(.down) / scale }
        return Frame(x: snap(x), y: snap(y), width: width, height: height)
    }

    /// The distance between the centers of two frames.
    func centerDistance(to other: Frame) -> Double {
        let dx = midX - other.midX
        let dy = midY - other.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    var description: String { "(\(x), \(y), \(width) x \(height))" }
}

/// A width and a height in points.
nonisolated struct Size: Hashable, Sendable, Codable {
    var width: Double
    var height: Double
}
