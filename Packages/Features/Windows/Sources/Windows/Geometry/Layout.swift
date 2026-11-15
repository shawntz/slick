/// What a window command does to a window's frame.
nonisolated enum Layout: Hashable, Sendable {
    /// Fills one side of the display. Pressed again, it can cycle through two thirds and one third
    /// or move to the next display on that side, as the repeat setting says.
    case half(Edge)
    case quarter(Corner)
    /// A third or two thirds along the display's long side, so thirds stack on a portrait display.
    case thirds(ThirdsSlot)
    case maximize
    /// A centered frame that covers a share of the display, set in settings.
    case almostMaximize
    case maximizeHeight
    case maximizeWidth
    /// The same size, centered.
    case center
    /// The same size, against one edge.
    case moveToEdge(Edge)
    /// A step larger or smaller, on every side that is not against the display's edge.
    case resize(grow: Bool)
    /// The display this many places after the current one, in ``Swift/Array/spatiallyOrdered``
    /// order, keeping the window's frame relative to the display.
    case display(offset: Int)
    /// The frame the window had before the feature first moved it.
    case restore

    /// The sizes a half cycles through, in order: a half, two thirds, one third.
    static let halfFractions: [Double] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// The region of a half, or of one of its cycle steps, against an edge.
    static func halfRegion(_ edge: Edge, fraction: Double) -> Region {
        switch edge {
        case .left: Region(x: 0, y: 0, width: fraction, height: 1)
        case .right: Region(x: 1 - fraction, y: 0, width: fraction, height: 1)
        case .top: Region(x: 0, y: 0, width: 1, height: fraction)
        case .bottom: Region(x: 0, y: 1 - fraction, width: 1, height: fraction)
        }
    }

    static func quarterRegion(_ corner: Corner) -> Region {
        switch corner {
        case .topLeft: Region(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: Region(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: Region(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: Region(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        }
    }

    /// Every region a command can put a window in, for a display of this orientation. Next Display
    /// uses it to keep a window in its region rather than scale its gaps.
    static func regions(portrait: Bool) -> [Region] {
        var regions = [Region.full]
        for edge in Edge.allCases {
            regions += halfFractions.map { halfRegion(edge, fraction: $0) }
        }
        regions += Corner.allCases.map(quarterRegion)
        regions += ThirdsSlot.allCases.map { $0.region(portrait: portrait) }
        return regions
    }
}

/// A third or two thirds of a display, counted along its long side.
nonisolated enum ThirdsSlot: String, Hashable, Sendable, CaseIterable {
    case first, center, last, firstTwo, centerTwo, lastTwo

    /// Where the slot starts and how long it is, in thirds.
    private var span: (start: Double, length: Double) {
        switch self {
        case .first: (0, 1)
        case .center: (1, 1)
        case .last: (2, 1)
        case .firstTwo: (0, 2)
        case .centerTwo: (0.5, 2)
        case .lastTwo: (1, 2)
        }
    }

    /// Columns on a landscape display, rows on a portrait one.
    func region(portrait: Bool) -> Region {
        let start = span.start / 3
        let length = span.length / 3
        return portrait
            ? Region(x: 0, y: start, width: 1, height: length)
            : Region(x: start, y: 0, width: length, height: 1)
    }
}

/// A rectangle in fractions of a layout area: x and y from its top-left corner, sizes from 0 to 1.
nonisolated struct Region: Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = Region(x: 0, y: 0, width: 1, height: 1)

    /// The region's frame in an area that already excludes the screen gap.
    ///
    /// Each side that faces another region moves in by half the window gap, so two neighbors end
    /// exactly one gap apart. Sides on the area's edge stay there. The result snaps to the
    /// display's pixel grid.
    func frame(in area: Frame, windowGap: Double, scale: Double) -> Frame {
        let epsilon = 1e-9
        let minX = area.minX + x * area.width
        let maxX = area.minX + (x + width) * area.width
        let minY = area.minY + y * area.height
        let maxY = area.minY + (y + height) * area.height
        // A gap never takes more than half of the region's own length.
        let halfX = min(windowGap / 2, (maxX - minX) / 4)
        let halfY = min(windowGap / 2, (maxY - minY) / 4)
        return Frame(
            minX: x > epsilon ? minX + halfX : minX,
            minY: y > epsilon ? minY + halfY : minY,
            maxX: x + width < 1 - epsilon ? maxX - halfX : maxX,
            maxY: y + height < 1 - epsilon ? maxY - halfY : maxY
        ).snapped(scale: scale)
    }
}
