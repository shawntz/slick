import AppKit
import QuartzCore
import os

/// Always-on latency instrumentation: one record and one signpost interval per interaction.
///
/// Each interaction is stamped on one clock (`LatencyClock`) at five points:
/// - `input`: the event's own timestamp, so `input → handler` is the system's delivery delay.
/// - `handler`: our handler started.
/// - `applied`: our synchronous view updates are done.
/// - `committed`: the update was drawn and committed. On macOS 27 AppKit draws views on a
///   refresh-aligned tick, up to a refresh after the run-loop turn ends, so `markApplied()` dirties
///   a 1×1 sentinel view and `committed` is the first run-loop wait after the sentinel drew.
/// - `frame`: the first display-link callback after the commit. Its `frameTarget` is the refresh
///   the render server composes for, which matched ScreenCaptureKit within half a millisecond at
///   p50 in the lab.
///
/// The cost is about 1 µs per interaction, so it stays on. Records go into a fixed ring buffer:
/// no allocation per interaction. Call it once per interaction, never per row.
public final class LatencyProbe {
    /// The interactions the probe tells apart.
    public enum Kind: UInt8, Sendable, CaseIterable {
        case summon, keystroke, selection

        var signpostName: StaticString {
            switch self {
            case .summon: "Summon"
            case .keystroke: "Keystroke"
            case .selection: "Selection"
            }
        }
    }

    /// One interaction's timestamps, in mach ticks. Zero means the point was not reached.
    public struct Record: Sendable {
        public var kind: Kind = .keystroke
        public var input: UInt64 = 0
        public var handler: UInt64 = 0
        public var applied: UInt64 = 0
        public var committed: UInt64 = 0
        public var frame: UInt64 = 0
        public var frameTarget: UInt64 = 0
        /// Main-thread CPU time from the handler to the commit.
        public var cpuNanoseconds: UInt64 = 0

        public init() {}

        /// Whether the interaction reached a display refresh.
        public var isComplete: Bool { frame != 0 }
        public var handlerToApplied: Double { LatencyClock.ms(handler, applied) }
        public var handlerToCommit: Double { LatencyClock.ms(handler, committed) }
        public var commitToFrame: Double { LatencyClock.ms(committed, frame) }
        public var inputToFrameTarget: Double { LatencyClock.ms(input, frameTarget) }
        public var handlerToFrameTarget: Double { LatencyClock.ms(handler, frameTarget) }
        public var cpuMilliseconds: Double { Double(cpuNanoseconds) / 1e6 }
    }

    /// Called when an interaction completes, after its display-link callback.
    public var onRecord: ((Record) -> Void)?
    /// False turns every call into a no-op.
    public var isEnabled = true
    /// How many records the ring holds now.
    public private(set) var count = 0

    private let signposter: OSSignposter
    private var interval: OSSignpostIntervalState?
    private var pending: Record?
    private var turnEnded: UInt64 = 0
    private var cpuStart: UInt64 = 0
    private var ring: [Record]
    private var head = 0
    private var observer: CFRunLoopObserver?
    private var driver: DisplayLinkDriver?
    private let sentinel = ProbeSentinel(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    /// How long to wait for the sentinel to draw before stamping the commit anyway, in ms. A hidden
    /// window never draws.
    private static let commitTimeout = 50.0

    /// `view` provides the display link and hosts the sentinel; use the panel's root view.
    /// Signposts go to `subsystem` under Points of Interest.
    public init(view: NSView, subsystem: String = LatencyProbe.defaultSubsystem, capacity: Int = 1024) {
        signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
        ring = Array(repeating: Record(), count: max(1, capacity))
        view.addSubview(sentinel)
        driver = DisplayLinkDriver(view: view) { [weak self] link in self?.tick(link) }
        // Ordered after Core Animation's commit observer (2,000,000).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_100
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.runLoopWillWait() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// The main bundle's identifier, or the package name when there is none (a test runner).
    public static var defaultSubsystem: String { Bundle.main.bundleIdentifier ?? "LauncherUI" }

    isolated deinit {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    /// Call first thing in a handler. `eventTimestamp` is the event's own time in seconds of
    /// uptime (`NSEvent.timestamp`), when known.
    public func begin(_ kind: Kind, eventTimestamp: TimeInterval? = nil) {
        guard isEnabled else { return }
        let now = LatencyClock.now()
        if let pending { finish(pending) }
        var record = Record()
        record.kind = kind
        record.handler = now
        record.input = eventTimestamp.map { LatencyClock.ticks(seconds: $0) } ?? now
        pending = record
        turnEnded = 0
        cpuStart = LatencyClock.threadCPUNanoseconds()
        interval = signposter.beginInterval(kind.signpostName, id: signposter.makeSignpostID())
    }

    /// Call when the handler's view updates are done.
    public func markApplied() {
        guard isEnabled, pending != nil else { return }
        pending?.applied = LatencyClock.now()
        sentinel.hasDrawn = false
        sentinel.needsDisplay = true
        signposter.emitEvent("applied")
    }

    /// The most recent records, oldest first, optionally of one kind. Allocates; for diagnostics.
    public func records(_ kind: Kind? = nil) -> [Record] {
        (0..<count).compactMap { offset in
            let record = ring[(head - count + offset + ring.count) % ring.count]
            return kind == nil || record.kind == kind ? record : nil
        }
    }

    /// Forgets every record.
    public func reset() {
        head = 0
        count = 0
        pending = nil
    }

    private func runLoopWillWait() {
        guard var record = pending, record.applied != 0, record.committed == 0 else { return }
        let now = LatencyClock.now()
        if turnEnded == 0 { turnEnded = now }
        guard sentinel.hasDrawn || LatencyClock.ms(turnEnded, now) > Self.commitTimeout else { return }
        record.committed = now
        record.cpuNanoseconds = LatencyClock.threadCPUNanoseconds() &- cpuStart
        pending = record
        signposter.emitEvent("committed")
        driver?.isRunning = true
    }

    private func tick(_ link: CADisplayLink) {
        driver?.isRunning = false
        guard var record = pending, record.committed != 0 else { return }
        record.frame = LatencyClock.now()
        record.frameTarget = LatencyClock.ticks(seconds: link.targetTimestamp)
        pending = nil
        finish(record)
        onRecord?(record)
    }

    private func finish(_ record: Record) {
        if let interval { signposter.endInterval(record.kind.signpostName, interval) }
        interval = nil
        ring[head] = record
        head = (head + 1) % ring.count
        count = min(count + 1, ring.count)
    }
}

/// A 1×1 transparent view whose display pass tells the probe that AppKit's display cycle ran.
private final class ProbeSentinel: NSView {
    var hasDrawn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { hasDrawn = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
