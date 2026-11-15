import Kit
import KitTesting
import Testing

@testable import Windows

/// Synthetic displays in the Accessibility space, in the arrangements people have.
nonisolated enum Displays {
    /// A Retina laptop: 1512 by 982 points at scale 2, a 33 point menu bar, a 70 point Dock below.
    static let laptop = Display(
        id: 1, frame: Frame(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: Frame(x: 0, y: 33, width: 1512, height: 879), scale: 2)

    /// The same laptop with the Dock on the left, 64 points wide.
    static let laptopDockLeft = Display(
        id: 1, frame: Frame(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: Frame(x: 64, y: 33, width: 1448, height: 949), scale: 2)

    /// The same laptop with the Dock on the right.
    static let laptopDockRight = Display(
        id: 1, frame: Frame(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: Frame(x: 0, y: 33, width: 1448, height: 949), scale: 2)

    /// A 1920 by 1080 display at scale 1 to the right of the laptop, tops aligned.
    static let rightExternal = Display(
        id: 2, frame: Frame(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: Frame(x: 1512, y: 25, width: 1920, height: 1055), scale: 1)

    /// A 2560 by 1440 display at scale 1 to the left of the main display, lower than it, so every
    /// coordinate on it is negative or crosses zero.
    static let leftExternal = Display(
        id: 3, frame: Frame(x: -2560, y: -200, width: 2560, height: 1440),
        visibleFrame: Frame(x: -2560, y: -175, width: 2560, height: 1415), scale: 1)

    /// A portrait display at scale 2 above the laptop.
    static let portraitAbove = Display(
        id: 4, frame: Frame(x: 200, y: -1920, width: 1080, height: 1920),
        visibleFrame: Frame(x: 200, y: -1895, width: 1080, height: 1895), scale: 2)

    /// An older 1366 by 768 display at scale 1, whose width does not halve into whole points
    /// once a gap is taken off.
    static let oddSmall = Display(
        id: 5, frame: Frame(x: 0, y: 0, width: 1366, height: 768),
        visibleFrame: Frame(x: 0, y: 25, width: 1366, height: 699), scale: 1)

    /// A display at scale 3 with an odd visible height.
    static let dense = Display(
        id: 6, frame: Frame(x: 0, y: 0, width: 1280, height: 853),
        visibleFrame: Frame(x: 0, y: 24, width: 1280, height: 777), scale: 3)

    /// A 1920 by 1080 display below the laptop at scale 1.
    static let belowExternal = Display(
        id: 7, frame: Frame(x: -204, y: 982, width: 1920, height: 1080),
        visibleFrame: Frame(x: -204, y: 1007, width: 1920, height: 1055), scale: 1)

    /// Every single display, for tests that run each layout on each.
    static let singles: [Display] = [
        laptop, laptopDockLeft, laptopDockRight, rightExternal, leftExternal, portraitAbove, oddSmall, dense,
        belowExternal,
    ]

    /// Desks with more than one display.
    static let desks: [[Display]] = [
        [laptop, rightExternal],
        [laptop, leftExternal],
        [laptop, portraitAbove],
        [leftExternal, laptop, rightExternal],
        [laptop, belowExternal, rightExternal],
    ]
}

/// A window state on a display, for planner tests.
nonisolated func window(_ frame: Frame, key: String = "1_1") -> WindowState {
    WindowState(key: key, frame: frame)
}

/// A request for a layout with options.
nonisolated func request(
    _ layout: Layout, command: String = "test", options: LayoutOptions = LayoutOptions(),
    last: Placement? = nil, restore: [String: Frame] = [:]
) -> LayoutRequest {
    LayoutRequest(command: command, layout: layout, options: options, lastPlacement: last, restoreFrames: restore)
}

/// The planned frame, or a test failure.
nonisolated func planned(
    _ request: LayoutRequest, window: WindowState, displays: [Display],
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> PlannedFrame {
    switch LayoutPlanner.plan(request, window: window, displays: displays) {
    case .success(let plan): return plan
    case .failure(let reason):
        Issue.record("expected a frame, got \(reason)", sourceLocation: sourceLocation)
        throw reason
    }
}

/// True when every edge sits on the display's pixel grid.
nonisolated func isOnPixelGrid(_ frame: Frame, scale: Double) -> Bool {
    [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { value in
        let pixels = value * scale
        return abs(pixels - pixels.rounded()) < 1e-6
    }
}

/// True when `inner` lies inside `outer`, allowing for rounding to the pixel grid.
nonisolated func contains(_ outer: Frame, _ inner: Frame, slack: Double = 0.5) -> Bool {
    inner.minX >= outer.minX - slack && inner.minY >= outer.minY - slack && inner.maxX <= outer.maxX + slack
        && inner.maxY <= outer.maxY + slack
}

/// A harness over a simulated desktop the test controls.
@MainActor struct WindowsHarness {
    let desktop: SimulatedWindows
    let harness: FeatureHarness<WindowsFeature>

    init(
        displays: [Display] = [Displays.laptop, Displays.rightExternal],
        windows: [SimulatedWindows.Window] = [WindowsHarness.editor],
        permissions: PermissionStatus = .granted
    ) {
        desktop = SimulatedWindows(displays: displays, windows: windows)
        let fakes = FakeServices(permissions: permissions)
        fakes.override(WindowServiceKey.self, with: desktop)
        harness = FeatureHarness(WindowsFeature.self, fakes: fakes)
    }

    var settings: FeatureSettings { harness.context.settings }

    /// The focused window's frame now.
    var frame: Frame? { desktop.focused?.frame }

    /// Runs a command the way a hotkey does: with the panel closed.
    @discardableResult
    func press(_ command: String) async throws -> ActionOutcome {
        try await harness.run(command, launch: .hotkey)
    }

    nonisolated static let editor = SimulatedWindows.Window(
        ref: WindowRef(process: 501, token: 7), title: "Draft", appName: "Example Editor",
        bundleID: "com.example.editor", frame: Frame(x: 200, y: 150, width: 800, height: 500))
}
