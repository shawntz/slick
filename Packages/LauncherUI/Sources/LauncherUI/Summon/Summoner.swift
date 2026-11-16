import AppKit
import QuartzCore

/// How the panel appears and disappears.
nonisolated public enum SummonStrategy: String, Sendable, CaseIterable {
    /// The panel stays ordered in; its root layer's opacity flips between 0 and 1. A plain
    /// opacity change reaches the screen about one refresh sooner than a window-server order
    /// change, and the main thread spends about 0.1 ms on it. The hidden panel passes clicks
    /// through and is hidden from accessibility.
    case layerOpacity
    /// `orderFront` and `orderOut`. Simplest semantics, one refresh slower to first pixels.
    case orderFront
}

/// Main-thread milliseconds for each step of the last summon.
nonisolated public struct SummonTimings: Sendable, Equatable {
    /// Checking for, and rarely moving to, the screen with the pointer.
    public var placement: Double = 0
    /// Making the panel visible: the opacity flip, or `orderFrontRegardless`.
    public var show: Double = 0
    /// Flushing the transaction so the visible frame reaches the render server first.
    public var flush: Double = 0
    /// Exposing the panel to accessibility.
    public var accessibility: Double = 0
    /// `makeKey`, a window-server round trip that the summon budget excludes.
    public var makeKey: Double = 0
    /// Laying out and committing the glass's key look right after `makeKey`, when the panel
    /// becomes key before it shows. This is AppKit's own response to the key change, about 1 to
    /// 1.5 ms. When the panel shows first, the same work runs after `summon()` returns and no
    /// step counts it. Like `makeKey`, it is not part of `excludingMakeKey`.
    public var keyLook: Double = 0

    /// Everything except `makeKey` and the glass's response to it: the part the summon budget
    /// covers.
    public var excludingMakeKey: Double { placement + show + flush + accessibility }
}

/// Shows and hides the launcher with nothing on the path but visibility and key status.
///
/// Everything the panel shows at summon must be prepared before: at dismiss (`prepareNext`) or on
/// the last context change. The query field's editor is installed once at pre-warm and never
/// re-installed on the summon path.
public final class Summoner {
    public let surface: LauncherSurface
    public let strategy: SummonStrategy
    /// Records one `.summon` interval per summon.
    public let probe: LatencyProbe
    /// Move the panel to the screen with the pointer at summon. Off for captures.
    public var followsPointerScreen = true
    /// False shows the panel without making it key: no keyboard focus and the flatter look of a
    /// non-key glass. For tests and measurements that must not take the keyboard.
    public var takesKeyStatus = true
    /// Make the panel key, and lay out the glass for its key look, before the first visible
    /// frame. Applies to `layerOpacity` with `takesKeyStatus`.
    ///
    /// The glass draws its key look with a layer that AppKit turns on in the first layout after
    /// the window becomes key, and the render server shows that layer two refreshes after its
    /// commit. A panel that shows first and becomes key after shows the flatter non-key glass for
    /// one to three refreshes: a bright flash in dark mode, a grey one in light mode. With this
    /// on, the first frame on screen is the key look. It arrives about one refresh later than the
    /// flat first frame did, and no later than the key look did. False restores the old order.
    public var makesKeyBeforeShowing = true
    /// Called after every dismiss, to prepare the next summon's content.
    public var prepareNext: (() -> Void)?
    public private(set) var isShown = false
    /// Step timings of the last summon.
    public private(set) var lastTimings = SummonTimings()
    /// Makes the panel key. Tests replace it, so they can check the order without taking key
    /// status.
    var keyChange: (GlassPanel) -> Void = { $0.makeKey() }
    /// How many times every piece of glass was rendered while the panel was invisible: once at
    /// pre-warm, and once after each theme change that added or restyled a piece.
    private(set) var hiddenGlassRenders = 0
    /// A theme change restyled the glass while the panel showed; render it at the next dismiss.
    private var needsHiddenGlassRender = false

    private var root: NSView { surface.rootView }
    private static let rampKey = "summonRamp"

    public init(surface: LauncherSurface, strategy: SummonStrategy = .layerOpacity, probe: LatencyProbe? = nil) {
        self.surface = surface
        self.strategy = strategy
        self.probe = probe ?? LatencyProbe(view: surface.rootView)
        surface.panel.onResignKey = { [weak self] in self?.dismiss(returnFocus: false) }
        surface.onGlassRestyled = { [weak self] in self?.renderHiddenGlass() }
    }

    /// Renders the panel once so the first real summon costs what every later one does (the
    /// first glass render costs about 30 ms), installs the field editor, and leaves the panel
    /// hidden. Every piece of glass is rendered, a results container that hides by opacity
    /// included. Call once at launch, before the first summon.
    public func prewarm() {
        let panel = surface.panel
        // A process started from a terminal begins active and would make the panel key at once.
        NSApp.deactivate()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        surface.withEveryPieceShown {
            panel.displayIfNeeded()
            CATransaction.flush()
        }
        hiddenGlassRenders += 1
        surface.queryField.installEditor()
        setRootOpacity(0)
        panel.alphaValue = 1
        root.setAccessibilityHidden(true)
        if strategy == .orderFront { panel.orderOut(nil) }
    }

    /// Shows the panel and makes it key. `eventTimestamp` is the hotkey event's own time, for
    /// the latency record.
    public func summon(eventTimestamp: TimeInterval? = nil) {
        guard !isShown else { return }
        isShown = true
        probe.begin(.summon, eventTimestamp: eventTimestamp)
        let panel = surface.panel
        var timings = SummonTimings()
        var lap = LatencyClock.now()
        func split() -> Double {
            let now = LatencyClock.now()
            defer { lap = now }
            return LatencyClock.ms(lap, now)
        }

        if followsPointerScreen { surface.followPointerScreen() }
        timings.placement = split()
        let keyFirst = makesKeyBeforeShowing && takesKeyStatus && strategy == .layerOpacity
        if keyFirst {
            // The panel is ordered in at zero opacity, so it becomes key unseen. The glass turns
            // its key look on in its next layout. Run that layout and commit it now, while the
            // panel is still invisible, so the opacity flip below is a small commit of its own
            // and the first visible frame already has the key look.
            keyChange(panel)
            timings.makeKey = split()
            for piece in surface.glassPieces { piece.layoutSubtreeIfNeeded() }
            CATransaction.flush()
            timings.keyLook = split()
        }
        switch strategy {
        case .layerOpacity:
            setRootOpacity(1, ramp: true)
            timings.show = split()
            // Send the visible frame to the render server before anything else can stall it.
            CATransaction.flush()
            timings.flush = split()
        case .orderFront:
            setRootOpacity(1, ramp: true)
            panel.orderFrontRegardless()
            timings.show = split()
        }
        root.setAccessibilityHidden(false)
        timings.accessibility = split()
        if !keyFirst {
            if takesKeyStatus { keyChange(panel) }
            timings.makeKey = split()
        }
        // Only when nothing in the panel has focus; otherwise this costs 1.2 ms per summon. A form
        // field or an open card keeps the focus it had.
        if !(panel.firstResponder is NSView) { surface.queryField.installEditor() }
        lastTimings = timings
        probe.markApplied()
    }

    /// Hides the panel. With `returnFocus`, key status goes back to the user's window.
    public func dismiss(returnFocus: Bool = true) {
        guard isShown else { return }
        isShown = false
        switch strategy {
        case .layerOpacity:
            setRootOpacity(0)
            root.setAccessibilityHidden(true)
            if returnFocus { NSApp.deactivate() }
        case .orderFront:
            surface.panel.orderOut(nil)
            setRootOpacity(0)
        }
        if needsHiddenGlassRender { renderHiddenGlass() }
        prepareNext?()
    }

    /// Renders every piece of glass once while the panel stays invisible, after a theme change
    /// added or restyled one, so its first render never lands on a summon or a keystroke. While
    /// the panel shows, it waits for the next dismiss.
    private func renderHiddenGlass() {
        guard !isShown else {
            needsHiddenGlassRender = true
            return
        }
        needsHiddenGlassRender = false
        let panel = surface.panel
        let orderedIn = panel.isVisible
        panel.alphaValue = 0
        if !orderedIn { panel.orderFrontRegardless() }
        setRootOpacity(1)
        surface.withEveryPieceShown {
            panel.displayIfNeeded()
            CATransaction.flush()
        }
        setRootOpacity(0)
        if !orderedIn { panel.orderOut(nil) }
        panel.alphaValue = 1
        hiddenGlassRenders += 1
    }

    /// Sets the root layer's opacity in its own transaction, with no implicit animation. With
    /// `ramp`, a theme that asks for it fades in over a few refreshes. With
    /// `makesKeyBeforeShowing` the first frame already has the key look, so a ramp is a matter of
    /// style; without it, a ramp softens the flatter look the glass shows before it is key.
    private func setRootOpacity(_ opacity: Float, ramp: Bool = false) {
        guard let layer = root.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.rampKey)
        layer.opacity = opacity
        let frames = surface.resolvedTheme.motion.summonRampFrames
        if ramp, frames > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = opacity
            fade.duration = Double(frames) / Double(max(1, surface.panel.screen?.maximumFramesPerSecond ?? 60))
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(fade, forKey: Self.rampKey)
        }
        CATransaction.commit()
    }
}
