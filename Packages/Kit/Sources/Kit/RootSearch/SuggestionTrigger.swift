import Foundation

/// Offers situational suggestions for root search's empty state, such as joining a meeting that
/// starts in five minutes.
///
/// Suggestions never pop up by themselves; they appear only when the user opens the panel. Root
/// decides which to show with Thompson sampling: it draws an acceptance rate from the trigger's
/// Beta prior, updated by how often the user took its suggestions, multiplies by the suggestion's
/// urgency, and inserts at most one trigger row (two when one is imminent). A trigger whose
/// suggestions are ignored keeps getting fewer slots, and switches off when acceptance stays low.
///
/// Root asks for suggestions when the context changes (at ``refreshInterval``, after
/// ``RowSource/changes`` or a setting in ``RowSource/reloadsOnSettings``, on wake), never when the
/// hotkey fires.
@MainActor public protocol SuggestionTrigger: RowSource {
    /// The trigger type, unique within the feature, such as "meeting-soon". Learning is kept per type.
    var id: String { get }
    /// The ``ItemID`` namespace of the suggestion rows, unique across features like a catalog
    /// source's, so Root can route a remembered suggestion row back to ``actions(for:)``. The same
    /// object may also be the feature's catalog source or live provider for that namespace.
    var namespace: String { get }
    /// What Root believes about acceptance before it has learned anything.
    var prior: AcceptancePrior { get }
    /// How often to ask again. Nil asks only after a change and on wake.
    var refreshInterval: Duration? { get }
    /// Permissions the trigger needs. Root skips the trigger while one is missing; it never asks.
    var requires: [Permission] { get }

    /// The current suggestions. Return the same ``Suggestion/id`` for the same situation every time.
    /// Throw instead of returning nothing when the work failed or was cancelled, so Root keeps the
    /// suggestions it had.
    func suggestions(at date: Date) async throws -> [Suggestion]
}

extension SuggestionTrigger {
    public var refreshInterval: Duration? { nil }
    public var requires: [Permission] { [] }
}

/// One suggestion: a row plus when and how strongly it applies.
public struct Suggestion: Identifiable, Sendable {
    /// Stable for one situation, such as an event ID plus its start time, so Root can count how often
    /// the user ignored it and stop showing it after three times.
    public var id: String
    /// The row shown. Give one-off rows ``RowMemory/never`` so Root does not remember them.
    public var row: Row
    public var urgency: Urgency
    /// After this moment the suggestion is never shown.
    public var expires: Date
    /// From this moment the suggestion is about to happen, such as a meeting inside its window, and
    /// may take a second slot. Nil never does.
    public var imminentFrom: Date?

    public init(id: String, row: Row, urgency: Urgency, expires: Date, imminentFrom: Date? = nil) {
        self.id = id
        self.row = row
        self.urgency = urgency
        self.expires = expires
        self.imminentFrom = imminentFrom
    }

    /// True when the suggestion is imminent at this moment.
    public func isImminent(at date: Date) -> Bool {
        imminentFrom.map { date >= $0 && date < expires } ?? false
    }
}

/// How relevant a suggestion is over time, from 0 to 1.
public enum Urgency: Hashable, Sendable {
    /// The same value all the time.
    case constant(Double)
    /// 0 before `start`, rising linearly to 1 at `full`, 1 until `end`, 0 after. A meeting at 10:00
    /// might use start 9:45, full 9:55, end 10:10.
    case ramp(start: Date, full: Date, end: Date)
    /// `exp(-age / timeConstant)`, where age is the time since `since`. A file that arrived two
    /// minutes ago with a ten-minute constant scores about 0.82.
    case decay(since: Date, timeConstant: Duration)

    /// The urgency at a moment, clamped to 0...1.
    public func value(at date: Date) -> Double {
        switch self {
        case .constant(let value):
            return min(max(value, 0), 1)
        case .ramp(let start, let full, let end):
            if date < start || date > end { return 0 }
            if date >= full { return 1 }
            let span = full.timeIntervalSince(start)
            return span > 0 ? date.timeIntervalSince(start) / span : 1
        case .decay(let since, let timeConstant):
            let tau = Double(timeConstant.components.seconds) + Double(timeConstant.components.attoseconds) * 1e-18
            guard tau > 0 else { return 0 }
            let age = max(0, date.timeIntervalSince(since))
            return exp(-age / tau)
        }
    }
}

/// A Beta(accepts, rejects) prior on how often the user takes a trigger's suggestions. (4, 1) says
/// "usually taken", (1, 3) says "rarely taken". It is updated as the user responds.
public struct AcceptancePrior: Hashable, Sendable {
    public var accepts: Double
    public var rejects: Double

    public init(accepts: Double, rejects: Double) {
        self.accepts = accepts
        self.rejects = rejects
    }

    /// The prior's mean acceptance rate.
    public var mean: Double { accepts / (accepts + rejects) }
}
