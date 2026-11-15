import Foundation

/// Counts, for each summon, the frames that showed the glass before its key look.
///
/// It reads the mean luminance of an empty stretch of glass in every frame the window server
/// displayed, from 0 to 255. Before a summon the stretch shows the wallpaper. The key look is the
/// level the summon settles at. A frame that has left the wallpaper level but is not yet at the key
/// level is flat: the glass without its key look, or a fade on its way in.
nonisolated public enum SummonLookMeter {
    /// One displayed frame.
    public struct Sample: Sendable, Equatable {
        /// When the window server displayed it, in mach ticks.
        public var displayTime: UInt64
        /// Mean luminance of the watched stretch, from 0 to 255.
        public var luminance: Double

        public init(displayTime: UInt64, luminance: Double) {
            self.displayTime = displayTime
            self.luminance = luminance
        }
    }

    /// What one summon showed.
    public struct Result: Sendable, Equatable {
        /// Milliseconds from the summon to the first frame that left the wallpaper level.
        public var firstPixels: Double
        /// Milliseconds from the summon to the first frame at the key look.
        public var keyLook: Double
        /// Frames shown before the key look.
        public var flatFrames: Int
        /// Milliseconds from the first frame to the key look.
        public var flatMilliseconds: Double
        /// The wallpaper level, then the first five levels after it.
        public var levels: [Double]
    }

    /// One result per summon that could be measured, in order. `starts` are the summons' start
    /// times in mach ticks. Frames more than `window` milliseconds after a start belong to its
    /// dismiss and are not read. A summon is skipped when no frame came before it, or when its key
    /// look is within 2 levels of the wallpaper, so the two cannot be told apart.
    public static func analyse(_ samples: [Sample], starts: [UInt64], window: Double = 145) -> [Result] {
        let sorted = samples.filter { $0.displayTime > 0 }.sorted { $0.displayTime < $1.displayTime }
        let span = ticks(milliseconds: window)
        return starts.compactMap { start in
            let after = sorted.filter { $0.displayTime >= start && $0.displayTime < start + span }
            guard let hidden = sorted.last(where: { $0.displayTime < start })?.luminance,
                let key = after.last?.luminance, abs(key - hidden) >= 2
            else { return nil }
            // A level counts as the wallpaper or the key look within 40% of the step between them,
            // and never closer than 1 level or further than 5.
            let tolerance = max(1, min(5, abs(key - hidden) * 0.4))
            guard let first = after.firstIndex(where: { abs($0.luminance - hidden) > tolerance }),
                let keyIndex = after[first...].firstIndex(where: { abs($0.luminance - key) <= tolerance })
            else { return nil }
            return Result(
                firstPixels: milliseconds(start, after[first].displayTime),
                keyLook: milliseconds(start, after[keyIndex].displayTime),
                flatFrames: keyIndex - first,
                flatMilliseconds: milliseconds(after[first].displayTime, after[keyIndex].displayTime),
                levels: [hidden] + after[first...].prefix(5).map(\.luminance))
        }
    }

    /// Mach ticks in `milliseconds`.
    public static func ticks(milliseconds: Double) -> UInt64 {
        UInt64(max(0, milliseconds) * 1e6 * Double(timebase.denom) / Double(timebase.numer))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1e6
    }
}
