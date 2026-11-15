import Foundation
import Kit

/// What root search learned about one trigger type: a Beta(accepts, rejects) belief about how often
/// the user takes its suggestions, which starts at the trigger's ``AcceptancePrior``.
///
/// The learned part decays back toward the prior with a 30-day half-life, so an old run of ignores
/// does not count forever. A type whose mean stays under 0.05 after 20 impressions switches off.
nonisolated struct TriggerStats: Codable, Hashable, Sendable {
    /// The learned part halves over this many seconds.
    static let halfLife: TimeInterval = 30 * 86_400
    /// A type switches off after this many impressions when its mean is below ``offBelow``.
    static let offAfter = 20
    static let offBelow = 0.05

    var accepts: Double
    var rejects: Double
    var priorAccepts: Double
    var priorRejects: Double
    /// When ``accepts`` and ``rejects`` were last written.
    var updated: Date
    /// Sessions in which a suggestion of this type was visible for a second or was taken.
    var impressions: Int
    /// Suggestions of this type the user ran.
    var taken: Int
    /// True once acceptance stayed low. Root then stops asking the trigger.
    var isOff: Bool

    init(prior: AcceptancePrior, now: Date) {
        let prior = Self.sane(prior)
        accepts = prior.accepts
        rejects = prior.rejects
        priorAccepts = prior.accepts
        priorRejects = prior.rejects
        updated = now
        impressions = 0
        taken = 0
        isOff = false
    }

    /// The mean acceptance rate at `now`.
    func mean(at now: Date) -> Double {
        let current = decayed(to: now)
        return current.accepts / (current.accepts + current.rejects)
    }

    /// The belief at `now`: the learned part moved back toward the prior by the time since
    /// ``updated``.
    func decayed(to now: Date) -> TriggerStats {
        let age = now.timeIntervalSince(updated)
        guard age > 0 else { return self }
        let keep = pow(0.5, age / Self.halfLife)
        var next = self
        next.accepts = priorAccepts + (accepts - priorAccepts) * keep
        next.rejects = priorRejects + (rejects - priorRejects) * keep
        next.updated = now
        return next
    }

    /// The user ran one of the type's suggestions.
    mutating func accept(at now: Date) {
        self = decayed(to: now)
        accepts += 1
        impressions += 1
        taken += 1
    }

    /// The user saw one of the type's suggestions and did something else. Switches the type off when
    /// acceptance stays low.
    mutating func ignore(at now: Date) {
        self = decayed(to: now)
        rejects += 1
        impressions += 1
        if impressions >= Self.offAfter, accepts / (accepts + rejects) < Self.offBelow {
            isOff = true
        }
    }

    /// Follows a prior the trigger changed in code, keeping what was learned on top of it.
    mutating func adopt(_ prior: AcceptancePrior) {
        let prior = Self.sane(prior)
        guard prior.accepts != priorAccepts || prior.rejects != priorRejects else { return }
        accepts = max(prior.accepts + accepts - priorAccepts, 0.01)
        rejects = max(prior.rejects + rejects - priorRejects, 0.01)
        priorAccepts = prior.accepts
        priorRejects = prior.rejects
    }

    /// A prior with both counts positive and finite, so sampling always works.
    static func sane(_ prior: AcceptancePrior) -> AcceptancePrior {
        func fix(_ value: Double) -> Double { value.isFinite ? min(max(value, 0.01), 1_000) : 1 }
        return AcceptancePrior(accepts: fix(prior.accepts), rejects: fix(prior.rejects))
    }
}

/// How often the user ignored one suggestion, by trigger type and suggestion ID.
nonisolated struct IgnoredSuggestion: Codable, Hashable, Sendable {
    /// After three ignores the suggestion is not shown again.
    static let limit = 3

    var count: Int
    /// The suggestion's own expiry. The record is dropped after it.
    var expires: Date
}

/// A small, fast, seedable generator for Thompson draws: SplitMix64. Tests seed it; the app seeds it
/// from the system generator.
nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Draws from Beta distributions, for Thompson sampling.
nonisolated enum BetaSampler {
    /// One draw from Beta(a, b): X / (X + Y) with X from Gamma(a) and Y from Gamma(b).
    static func sample<G: RandomNumberGenerator>(_ a: Double, _ b: Double, using generator: inout G) -> Double {
        let x = gamma(a, using: &generator)
        let y = gamma(b, using: &generator)
        let sum = x + y
        guard sum > 0, sum.isFinite else { return a / (a + b) }
        return x / sum
    }

    /// One draw from Gamma(shape, 1), by Marsaglia and Tsang. Shapes under 1 are boosted.
    static func gamma<G: RandomNumberGenerator>(_ shape: Double, using generator: inout G) -> Double {
        if shape < 1 {
            let boosted = gamma(shape + 1, using: &generator)
            return boosted * pow(open(&generator), 1 / shape)
        }
        let d = shape - 1.0 / 3.0
        let c = 1 / (9 * d).squareRoot()
        while true {
            var x = 0.0
            var v = 0.0
            repeat {
                x = normal(&generator)
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = open(&generator)
            if u < 1 - 0.0331 * x * x * x * x { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    /// A standard normal draw, by Box and Muller.
    static func normal<G: RandomNumberGenerator>(_ generator: inout G) -> Double {
        let radius = (-2 * log(open(&generator))).squareRoot()
        return radius * cos(2 * Double.pi * open(&generator))
    }

    /// A uniform draw in (0, 1].
    static func open<G: RandomNumberGenerator>(_ generator: inout G) -> Double {
        (Double(generator.next() >> 11) + 1) * 0x1p-53
    }
}

/// One suggestion a trigger offers, with the draw for its type.
nonisolated struct TriggerCandidate: Sendable {
    /// `<feature id>.<trigger id>`.
    var typeKey: String
    var suggestion: Suggestion
    /// The Thompson draw for the type in this panel session.
    var draw: Double
}

/// Picks the trigger rows that go into Suggested.
nonisolated enum TriggerChooser {
    /// A suggestion shows only when its draw times its urgency reaches this.
    static let threshold = 0.15

    /// The rows to insert, best first: at most one, or two when one of them is imminent. Two
    /// suggestions with the same row show once, as the stronger one.
    static func choose(_ candidates: [TriggerCandidate], at now: Date) -> [TriggerCandidate] {
        var scored: [(candidate: TriggerCandidate, score: Double, imminent: Bool)] = []
        for candidate in candidates where candidate.suggestion.expires > now {
            let score = candidate.draw * candidate.suggestion.urgency.value(at: now)
            guard score >= threshold, score.isFinite else { continue }
            scored.append((candidate, score, candidate.suggestion.isImminent(at: now)))
        }
        guard !scored.isEmpty else { return [] }
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.imminent != right.imminent { return left.imminent }
            if left.candidate.typeKey != right.candidate.typeKey {
                return left.candidate.typeKey < right.candidate.typeKey
            }
            return left.candidate.suggestion.id < right.candidate.suggestion.id
        }
        var chosen: [TriggerCandidate] = []
        let slots = scored.contains { $0.imminent } ? 2 : 1
        for entry in scored where chosen.count < slots {
            guard !chosen.contains(where: { $0.suggestion.row.id == entry.candidate.suggestion.row.id }) else {
                continue
            }
            chosen.append(entry.candidate)
        }
        // With two slots, one of them must hold the imminent suggestion that earned the second slot.
        if chosen.count == 2, !chosen.contains(where: { $0.suggestion.isImminent(at: now) }),
            let imminent = scored.first(where: { entry in
                entry.imminent && !chosen.contains { $0.suggestion.row.id == entry.candidate.suggestion.row.id }
            })
        {
            chosen[1] = imminent.candidate
        }
        return chosen
    }
}
