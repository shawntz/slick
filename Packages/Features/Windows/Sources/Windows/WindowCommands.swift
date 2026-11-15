/// One layout command as data. The feature turns each into a Kit command.
nonisolated struct LayoutCommand: Hashable, Sendable {
    /// Stable: the user's aliases, hotkeys and presets are keyed by it.
    var id: String
    var title: String
    var symbol: String
    var keywords: [String]
    var layout: Layout
}

/// Every window command, in the order settings lists them.
nonisolated enum WindowCommands {
    static let toggleFullScreenID = "toggle-full-screen"
    static let switchWindowsID = "switch-windows"

    static let layouts: [LayoutCommand] = halves + quarters + thirds + sizes + edges + displays + [restore]

    static let halves: [LayoutCommand] = [
        command("left-half", Strings.leftHalf, "rectangle.lefthalf.filled", .half(.left)),
        command("right-half", Strings.rightHalf, "rectangle.righthalf.filled", .half(.right)),
        command("top-half", Strings.topHalf, "rectangle.tophalf.filled", .half(.top)),
        command("bottom-half", Strings.bottomHalf, "rectangle.bottomhalf.filled", .half(.bottom)),
    ]

    static let quarters: [LayoutCommand] = [
        command("top-left-quarter", Strings.topLeftQuarter, "rectangle.inset.topleft.filled", .quarter(.topLeft)),
        command("top-right-quarter", Strings.topRightQuarter, "rectangle.inset.topright.filled", .quarter(.topRight)),
        command(
            "bottom-left-quarter", Strings.bottomLeftQuarter, "rectangle.inset.bottomleft.filled",
            .quarter(.bottomLeft)),
        command(
            "bottom-right-quarter", Strings.bottomRightQuarter, "rectangle.inset.bottomright.filled",
            .quarter(.bottomRight)),
    ]

    static let thirds: [LayoutCommand] = [
        command("first-third", Strings.firstThird, "rectangle.split.3x1", .thirds(.first)),
        command("center-third", Strings.centerThird, "rectangle.split.3x1", .thirds(.center)),
        command("last-third", Strings.lastThird, "rectangle.split.3x1", .thirds(.last)),
        command("first-two-thirds", Strings.firstTwoThirds, "rectangle.split.3x1", .thirds(.firstTwo)),
        command("center-two-thirds", Strings.centerTwoThirds, "rectangle.split.3x1", .thirds(.centerTwo)),
        command("last-two-thirds", Strings.lastTwoThirds, "rectangle.split.3x1", .thirds(.lastTwo)),
    ]

    static let sizes: [LayoutCommand] = [
        command(
            "maximize", Strings.maximize, "arrow.up.left.and.arrow.down.right", .maximize,
            extra: Strings.maximizeKeywords),
        command("almost-maximize", Strings.almostMaximize, "rectangle.inset.filled", .almostMaximize),
        command("maximize-height", Strings.maximizeHeight, "arrow.up.and.down", .maximizeHeight),
        command("maximize-width", Strings.maximizeWidth, "arrow.left.and.right", .maximizeWidth),
        command("center", Strings.center, "rectangle.center.inset.filled", .center),
        command(
            "make-larger", Strings.makeLarger, "plus.rectangle", .resize(grow: true), extra: Strings.sizeKeywords),
        command(
            "make-smaller", Strings.makeSmaller, "minus.rectangle", .resize(grow: false), extra: Strings.sizeKeywords),
    ]

    static let edges: [LayoutCommand] = [
        command("move-left", Strings.moveLeft, "arrow.left.to.line", .moveToEdge(.left)),
        command("move-right", Strings.moveRight, "arrow.right.to.line", .moveToEdge(.right)),
        command("move-up", Strings.moveUp, "arrow.up.to.line", .moveToEdge(.top)),
        command("move-down", Strings.moveDown, "arrow.down.to.line", .moveToEdge(.bottom)),
    ]

    static let displays: [LayoutCommand] = [
        command("next-display", Strings.nextDisplay, "display.2", .display(offset: 1), extra: Strings.displayKeywords),
        command(
            "previous-display", Strings.previousDisplay, "display.2", .display(offset: -1),
            extra: Strings.displayKeywords),
    ]

    static let restore = command(
        "restore", Strings.restore, "arrow.uturn.backward", .restore, extra: Strings.restoreKeywords)

    private static func command(
        _ id: String, _ title: String, _ symbol: String, _ layout: Layout, extra: [String] = []
    ) -> LayoutCommand {
        LayoutCommand(id: id, title: title, symbol: symbol, keywords: Strings.windowKeywords + extra, layout: layout)
    }
}
