/// One display as the geometry sees it, in the Accessibility coordinate space that ``Frame`` describes.
nonisolated struct Display: Hashable, Sendable, Codable {
    /// The system's display ID. Only used to tell displays apart.
    var id: UInt32
    /// The whole display.
    var frame: Frame
    /// The display without the menu bar and the Dock: the area windows are laid out in.
    var visibleFrame: Frame
    /// Device pixels per point, such as 2 for a Retina display. Frames snap to this grid.
    var scale: Double

    /// Converts a display from AppKit's space, whose origin is the bottom-left corner of the main
    /// display and whose y grows upward. `mainHeight` is the main display's height in points.
    static func fromAppKit(
        id: UInt32, frame: Frame, visibleFrame: Frame, scale: Double, mainHeight: Double
    ) -> Display {
        func flipped(_ rect: Frame) -> Frame {
            Frame(x: rect.x, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return Display(id: id, frame: flipped(frame), visibleFrame: flipped(visibleFrame), scale: scale)
    }

    /// The area a layout fills: the visible frame less the gap at the screen edges.
    func layoutArea(screenGap: Double) -> Frame {
        visibleFrame.inset(by: screenGap)
    }

    /// False for a display whose layout area is less than a point across or not a number, as a
    /// display can report while it is being connected.
    func isUsable(screenGap: Double) -> Bool {
        let area = layoutArea(screenGap: screenGap)
        return area.width >= 1 && area.height >= 1 && area.width.isFinite && area.height.isFinite
            && area.x.isFinite && area.y.isFinite
    }
}

extension [Display] {
    /// The display that holds most of the frame. A frame on no display belongs to the nearest one.
    nonisolated func holding(_ frame: Frame) -> Display? {
        var best: (display: Display, area: Double)?
        for display in self {
            let area = display.frame.intersection(frame)?.area ?? 0
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        if let best { return best.display }
        return self.min { $0.frame.centerDistance(to: frame) < $1.frame.centerDistance(to: frame) }
    }

    /// The displays in the order Next Display walks them: left to right, then top to bottom.
    nonisolated var spatiallyOrdered: [Display] {
        sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            return lhs.id < rhs.id
        }
    }

    /// The nearest display beside `display` toward an edge, such as the display to the left. A
    /// display counts when it lies wholly on that side. Among those, one that shares some of the
    /// edge's span wins, then the closest.
    nonisolated func neighbor(of display: Display, toward edge: Edge) -> Display? {
        let source = display.frame
        let candidates = filter { candidate in
            let frame = candidate.frame
            switch edge {
            case .left: return frame.maxX <= source.minX + 1 && candidate.id != display.id
            case .right: return frame.minX >= source.maxX - 1 && candidate.id != display.id
            case .top: return frame.maxY <= source.minY + 1 && candidate.id != display.id
            case .bottom: return frame.minY >= source.maxY - 1 && candidate.id != display.id
            }
        }
        func overlap(_ candidate: Display) -> Double {
            let frame = candidate.frame
            switch edge {
            case .left, .right: return Swift.min(frame.maxY, source.maxY) - Swift.max(frame.minY, source.minY)
            case .top, .bottom: return Swift.min(frame.maxX, source.maxX) - Swift.max(frame.minX, source.minX)
            }
        }
        let touching = candidates.filter { overlap($0) > 0 }
        let pool = touching.isEmpty ? candidates : touching
        return pool.min { $0.frame.centerDistance(to: source) < $1.frame.centerDistance(to: source) }
    }
}

/// One side of a display or a window.
nonisolated enum Edge: String, Hashable, Sendable, Codable, CaseIterable {
    case left, right, top, bottom

    /// The side across from this one.
    var opposite: Edge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

/// One corner of a display.
nonisolated enum Corner: String, Hashable, Sendable, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}
