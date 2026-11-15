/// What a layout command did to the focused window.
nonisolated enum LayoutOutcome: Hashable, Sendable {
    case moved(Moved)
    case unchanged(Unchanged)
}

/// A window the feature moved.
nonisolated struct Moved: Hashable, Sendable {
    var window: String
    var before: Frame
    /// The frame the window took, read back from it.
    var after: Frame
    var step: Int
}

/// The one pass every window service runs for a layout command: plan the frame, set it, and if the
/// window refused the size, set the position once more so it stays anchored and on screen. Both
/// services call it, so the simulated desktop exercises the same logic as the real one.
nonisolated enum Arranger {
    /// - Parameter setFrame: Sets a frame on the window and returns the frame the window took.
    static func arrange(
        _ request: LayoutRequest, window: WindowState?, displays: [Display], setFrame: (Frame) throws -> Frame
    ) throws -> LayoutOutcome {
        guard let window else { return .unchanged(.noWindow) }
        let plan: PlannedFrame
        switch LayoutPlanner.plan(request, window: window, displays: displays) {
        case .failure(let reason): return .unchanged(reason)
        case .success(let planned): plan = planned
        }
        var actual = try setFrame(plan.frame)
        // The window keeps the size it took. Only its position is corrected.
        let settled = LayoutPlanner.settled(actual.size, planned: plan.frame, area: plan.area)
        if !settled.isClose(to: actual, tolerance: 1) {
            actual = try setFrame(settled.snappedOrigin(scale: plan.scale))
        }
        return .moved(Moved(window: window.key, before: window.frame, after: actual, step: plan.step))
    }
}
