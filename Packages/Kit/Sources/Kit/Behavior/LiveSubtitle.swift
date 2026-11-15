/// How a command appears in the fallback list under root results.
///
/// A fallback is a switch the user owns. Root search shows the fallbacks that are on, in the user's
/// order, under every typed query. Until the user sets a fallback's switch in settings, it follows
/// ``startsOn``, which is false by default: a fallback that starts on sits under everything the
/// user types.
public struct Fallback: Sendable {
    /// The row title for the typed text, such as `Search the web for "kit"`.
    public var title: @Sendable (String) -> String
    /// True puts the command in the fallback list until the user turns it off. Keep it false, the
    /// default, except for the feature's own default web search, or for an item the user marked as
    /// a fallback in the feature itself, such as a quicklink.
    public var startsOn: Bool

    public init(startsOn: Bool = false, title: @escaping @Sendable (String) -> String) {
        self.startsOn = startsOn
        self.title = title
    }
}

/// A subtitle that root search refreshes while the command's row is visible, such as a script's
/// inline output. The host cancels a fetch when the row scrolls away or the panel closes.
///
/// Make one with ``background(every:changes:fetch:)`` when the fetch does real work, such as
/// running a process or reading a file: root search then calls it off the main thread. The
/// initializer's fetch runs on the main actor, for a fetch that only reads state the feature
/// already holds.
public struct LiveSubtitle: Sendable {
    /// What the subtitle shows.
    public struct Value: Hashable, Sendable, ExpressibleByStringInterpolation {
        public var text: String
        /// A color for the text, such as red for a script that failed. Nil uses the theme's.
        public var color: KitColor?

        public init(_ text: String, color: KitColor? = nil) {
            self.text = text
            self.color = color
        }

        public init(stringLiteral value: String) {
            self.init(value)
        }
    }

    /// How often to refresh. Root never refreshes more often than every ten seconds.
    public var interval: Duration
    /// Fires when the subtitle should refresh at once, such as after the command ran.
    public var changes: ChangeSignal?
    /// Produces the subtitle on the main actor. Nil keeps the previous one. For a subtitle made with
    /// ``background(every:changes:fetch:)`` it calls ``backgroundFetch``.
    public var fetch: @MainActor @Sendable () async -> Value?
    /// Produces the subtitle off the main thread. Nil keeps the previous one. When set, root search
    /// calls it instead of ``fetch``. Nil for a subtitle whose fetch runs on the main actor.
    public var backgroundFetch: (@concurrent @Sendable () async -> Value?)?

    public init(
        every interval: Duration, changes: ChangeSignal? = nil, fetch: @escaping @MainActor @Sendable () async -> Value?
    ) {
        self.interval = interval
        self.changes = changes
        self.fetch = fetch
        backgroundFetch = nil
    }

    /// A subtitle whose fetch runs off the main thread, so a slow fetch never holds up typing.
    public static func background(
        every interval: Duration, changes: ChangeSignal? = nil,
        fetch: @escaping @concurrent @Sendable () async -> Value?
    ) -> LiveSubtitle {
        var subtitle = LiveSubtitle(every: interval, changes: changes) { await fetch() }
        subtitle.backgroundFetch = fetch
        return subtitle
    }

    /// Fetches once, off the main thread when the subtitle allows it.
    public func value() async -> Value? {
        if let backgroundFetch { return await backgroundFetch() }
        return await fetch()
    }
}
