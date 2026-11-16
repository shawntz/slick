import Foundation
import Kit
import KitTesting
import Testing

@testable import ColorTools

/// A harness over the fakes with the history read, as after activation in the app. The sampler
/// returns what the test queued, and Rebecca Purple when the test queued nothing.
func readyHarness(
    fakes: FakeServices = FakeServices(), sampler: SimulatedColorSampler = SimulatedColorSampler()
) async -> FeatureHarness<ColorsFeature> {
    fakes.override(ColorSamplerKey.self, with: sampler)
    let harness = FeatureHarness(ColorsFeature.self, fakes: fakes)
    await harness.activate()
    await harness.feature.waitUntilReady()
    return harness
}

extension FeatureHarness where F == ColorsFeature {
    /// The provider's one row for a query, or nil when it answers nothing.
    func answerRow(_ query: String) -> Row? {
        instantAnswers(for: query).first?.rows.first
    }

    /// The colors in the history, newest first, as hex.
    var historyHexes: [String] {
        feature.history.entries.map { ColorFormatter().hex($0.color) }
    }

    /// The history file in the fakes' data folder.
    var historyFile: URL {
        fakes.storage.dataDirectory(for: "colors").appending(path: "history.json")
    }
}

/// A color from a hex string, for tests.
func color(_ hex: String) throws -> ColorValue {
    try #require(ColorParser.parse(hex, allowsNames: false), "not a color: \(hex)")
}

/// A sRGB pick of the color with this hex.
func pick(_ hex: String) throws -> SimulatedColorSampler.Outcome {
    let value = try color(hex)
    return .picked(PickedColor(space: .sRGB, red: value.red, green: value.green, blue: value.blue, alpha: value.alpha))
}

/// Writes a history file into the fakes' data folder, as a person or a newer version might.
func writeHistory(_ text: String, in fakes: FakeServices) throws {
    let folder = fakes.storage.dataDirectory(for: "colors")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: folder.appending(path: "history.json"))
}

/// True when two numbers differ by no more than `tolerance`.
func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-4) -> Bool {
    abs(a - b) <= tolerance
}

/// A collection of bytes that counts how many it handed out, to prove a check reads only the start.
nonisolated struct CountingBytes: Collection {
    let bytes: [UInt8]
    let reads: Counter

    final class Counter: @unchecked Sendable {
        var count = 0
        var furthest = -1
    }

    init(_ text: String) {
        bytes = Array(text.utf8)
        reads = Counter()
    }

    var startIndex: Int { 0 }
    var endIndex: Int { bytes.count }
    func index(after index: Int) -> Int { index + 1 }

    subscript(position: Int) -> UInt8 {
        reads.count += 1
        reads.furthest = Swift.max(reads.furthest, position)
        return bytes[position]
    }
}

/// A generator with a fixed seed, so a test that draws random colors draws the same ones each run.
/// SplitMix64.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
