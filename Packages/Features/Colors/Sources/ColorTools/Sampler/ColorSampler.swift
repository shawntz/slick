import Kit
import Synchronization

/// A color the user clicked on screen, in the color space it arrived in.
nonisolated struct PickedColor: Hashable, Sendable {
    /// The space the components are in.
    enum Space: Hashable, Sendable {
        /// sRGB, as a display with an sRGB profile reports it.
        case sRGB
        /// Display P3, as most Mac displays report it.
        case displayP3
        /// Extended sRGB, already converted by the system from the display's own profile.
        case extendedSRGB
    }

    var space: Space
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    /// The color in extended sRGB, which keeps a color outside sRGB as it is. Nil when a component
    /// is not a number.
    var color: ColorValue? {
        let value: ColorValue
        switch space {
        case .sRGB, .extendedSRGB:
            value = ColorValue(red: red, green: green, blue: blue, alpha: alpha)
        case .displayP3:
            value = ColorSpaces.fromDisplayP3(red: red, green: green, blue: blue, alpha: alpha)
        }
        return value.sanitized
    }
}

/// Why the sampler gave no color although the user picked one.
nonisolated enum ColorSamplerError: Error, Hashable, Sendable {
    /// The system's color could not be turned into RGB components.
    case unreadable
}

/// The system's color sampler: the magnifier that follows the pointer until the user clicks a
/// pixel or presses Escape.
///
/// The live implementation shows it on screen and needs no permission. Tests, scenarios, self-tests
/// and benchmarks get ``SimulatedColorSampler``, which shows nothing.
nonisolated protocol ColorSampler: Sendable {
    /// Shows the sampler and returns the color the user clicked, or nil when the user pressed
    /// Escape. Throws ``ColorSamplerError`` when the picked color cannot be read.
    func sample() async throws -> PickedColor?
}

/// The color sampler for each kind of run.
nonisolated enum ColorSamplerKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ColorSampler {
        SystemColorSampler()
    }

    static func isolated(_ context: FeatureContext) -> any ColorSampler {
        SimulatedColorSampler()
    }
}

/// A sampler that shows nothing and returns the colors it was given, one per pick. With none left,
/// it returns what it returned last, so a scenario can pick again and again.
nonisolated final class SimulatedColorSampler: ColorSampler {
    /// What one pick returns.
    enum Outcome: Hashable, Sendable {
        case picked(PickedColor)
        /// The user pressed Escape.
        case cancelled
        case unreadable
    }

    private struct State {
        var outcomes: [Outcome]
        var last: Outcome
        var count = 0
    }

    private let state: Mutex<State>

    /// The sample scenarios pick: Rebecca Purple, #663399, in sRGB.
    static let sample = PickedColor(space: .sRGB, red: 0.4, green: 0.2, blue: 0.6)

    init(_ outcomes: [Outcome] = [.picked(sample)]) {
        state = Mutex(State(outcomes: outcomes, last: outcomes.last ?? .cancelled))
    }

    /// Plays these outcomes on the next picks, in order.
    func queue(_ outcomes: [Outcome]) {
        state.withLock { state in
            state.outcomes += outcomes
            if let last = outcomes.last { state.last = last }
        }
    }

    /// How many times the sampler was shown.
    var count: Int { state.withLock { $0.count } }

    func sample() async throws -> PickedColor? {
        let outcome = state.withLock { state in
            state.count += 1
            return state.outcomes.isEmpty ? state.last : state.outcomes.removeFirst()
        }
        switch outcome {
        case .picked(let color): return color
        case .cancelled: return nil
        case .unreadable: throw ColorSamplerError.unreadable
        }
    }
}
