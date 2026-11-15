import SlickCoreC

/// Where audio goes.
public enum AudioRoute: UInt8, Sendable {
    case builtIn = 0
    case headphones = 1
    case bluetooth = 2
    case usb = 3
    case other = 4
}

/// The context the engine predicts in. Set it whenever a value changes (app activation, the hour
/// changing, a device change); the engine recomputes suggestions then, never on the hotkey path.
public struct EngineContext: Hashable, Sendable {
    /// Unix time, seconds.
    public var now: Double
    /// Local hour, 0...23.
    public var hour: UInt8
    /// Local weekday, 0 = Monday ... 6 = Sunday.
    public var weekday: UInt8
    /// The frontmost app, never suggested.
    public var frontmost: ItemKey?
    /// The previously executed item, or nil to use the engine's own record.
    public var previous: ItemKey?
    /// Seconds since `previous` ran.
    public var sincePrevious: Double
    /// Running on battery.
    public var onBattery: Bool
    /// Connected displays.
    public var displayCount: UInt8
    /// Where audio goes.
    public var audioRoute: AudioRoute
    /// First summon after two hours idle, a wake or an unlock.
    public var sessionStart: Bool
    /// A Focus mode is on.
    public var focus: Bool

    public init(
        now: Double,
        hour: UInt8,
        weekday: UInt8,
        frontmost: ItemKey? = nil,
        previous: ItemKey? = nil,
        sincePrevious: Double = 0,
        onBattery: Bool = false,
        displayCount: UInt8 = 1,
        audioRoute: AudioRoute = .builtIn,
        sessionStart: Bool = false,
        focus: Bool = false
    ) {
        self.now = now
        self.hour = hour
        self.weekday = weekday
        self.frontmost = frontmost
        self.previous = previous
        self.sincePrevious = sincePrevious
        self.onBattery = onBattery
        self.displayCount = displayCount
        self.audioRoute = audioRoute
        self.sessionStart = sessionStart
        self.focus = focus
    }

    var raw: SlickContext {
        var c = SlickContext()
        c.now = now
        c.hour = hour
        c.weekday = weekday
        c.frontmost = frontmost?.rawValue ?? 0
        c.previous = previous?.rawValue ?? 0
        c.since_previous = sincePrevious
        c.display_count = displayCount
        c.audio_route = audioRoute.rawValue
        c.flags =
            (onBattery ? UInt8(SLICK_CONTEXT_ON_BATTERY) : 0)
            | (sessionStart ? UInt8(SLICK_CONTEXT_SESSION_START) : 0)
            | (focus ? UInt8(SLICK_CONTEXT_FOCUS) : 0)
        return c
    }
}

/// How an executed item was reached.
public enum ExecutionSource: UInt8, Sendable {
    /// Picked from typed results.
    case typed = 0
    /// Picked from the suggestions.
    case suggestion = 1
    /// Run by its own hotkey.
    case hotkey = 2
    /// Run through a user alias.
    case alias = 3
    /// A fallback action for a query with no good result.
    case fallback = 4
}
