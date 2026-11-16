import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// The summon order that keeps the glass's flat, non-key look off screen. No test takes key
/// status: the key change is replaced by a recorder.
@Suite(.timeLimit(.minutes(1)))
struct SummonOrderTests {
    /// What the panel looked like at the moment it was made key.
    struct KeyMoment: Equatable {
        var rootOpacity: Float
        var accessibilityHidden: Bool
    }

    private func summoner(
        strategy: SummonStrategy = .layerOpacity, keyFirst: Bool? = nil
    ) -> (Summoner, LauncherSurface, () -> [KeyMoment]) {
        let surface = TestSupport.makeSurface()
        let summoner = Summoner(surface: surface, strategy: strategy)
        summoner.followsPointerScreen = false
        if let keyFirst { summoner.makesKeyBeforeShowing = keyFirst }
        var moments: [KeyMoment] = []
        summoner.keyChange = { _ in
            moments.append(
                KeyMoment(
                    rootOpacity: surface.rootView.layer?.opacity ?? -1,
                    accessibilityHidden: surface.rootView.isAccessibilityHidden()))
        }
        summoner.prewarm()
        return (summoner, surface, { moments })
    }

    @Test func theDefaultMakesThePanelKeyWhileItIsStillInvisible() {
        let (summoner, surface, moments) = summoner()
        defer { surface.panel.close() }
        #expect(summoner.makesKeyBeforeShowing)
        summoner.summon()
        #expect(moments() == [KeyMoment(rootOpacity: 0, accessibilityHidden: true)])
        #expect(surface.rootView.layer?.opacity == 1)
        #expect(!surface.rootView.isAccessibilityHidden())
        #expect(summoner.lastTimings.keyLook >= 0)
        summoner.dismiss(returnFocus: false)
        #expect(surface.rootView.layer?.opacity == 0)
    }

    /// The key look comes from each glass view's own layout after the key change, so every piece
    /// is laid out before the panel shows, the results container of the split layout too.
    @Test func everyPieceOfGlassIsLaidOutBeforeTheFirstFrame() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.theme = .beam
        let summoner = Summoner(surface: surface)
        summoner.followsPointerScreen = false
        var opacityAtKey: Float = -1
        summoner.keyChange = { _ in
            // What AppKit does on a key change: each glass view needs layout again.
            for piece in surface.glassPieces { piece.needsLayout = true }
            opacityAtKey = surface.rootView.layer?.opacity ?? -1
        }
        summoner.prewarm()
        summoner.summon()
        #expect(surface.glassPieces.count == 2)
        #expect(opacityAtKey == 0)
        #expect(surface.glassPieces.allSatisfy { !$0.needsLayout })
        summoner.dismiss(returnFocus: false)
    }

    @Test func theOldOrderShowsThePanelBeforeMakingItKey() {
        let (summoner, surface, moments) = summoner(keyFirst: false)
        defer { surface.panel.close() }
        summoner.summon()
        #expect(moments() == [KeyMoment(rootOpacity: 1, accessibilityHidden: false)])
        #expect(summoner.lastTimings.keyLook == 0)
        summoner.dismiss(returnFocus: false)
    }

    @Test func aSummonWithoutKeyStatusNeverMakesThePanelKey() {
        let (summoner, surface, moments) = summoner()
        defer { surface.panel.close() }
        summoner.takesKeyStatus = false
        summoner.summon()
        #expect(moments().isEmpty)
        #expect(surface.rootView.layer?.opacity == 1)
        #expect(summoner.lastTimings.keyLook == 0)
        summoner.dismiss(returnFocus: false)
    }

    @Test func orderFrontStillOrdersInBeforeMakingKey() {
        let (summoner, surface, moments) = summoner(strategy: .orderFront)
        defer { surface.panel.close() }
        #expect(!surface.panel.isVisible)
        summoner.summon()
        #expect(moments() == [KeyMoment(rootOpacity: 1, accessibilityHidden: false)])
        #expect(surface.panel.isVisible)
        summoner.dismiss(returnFocus: false)
    }

    @Test func everySummonMakesThePanelKeyOnce() {
        let (summoner, surface, moments) = summoner()
        defer { surface.panel.close() }
        for _ in 0..<3 {
            summoner.summon()
            summoner.summon()
            summoner.dismiss(returnFocus: false)
        }
        #expect(moments().count == 3)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SummonLookMeterTests {
    private let start: UInt64 = 1_000_000_000

    private func at(_ milliseconds: Double, _ level: Double) -> SummonLookMeter.Sample {
        let offset = SummonLookMeter.ticks(milliseconds: abs(milliseconds))
        return SummonLookMeter.Sample(
            displayTime: milliseconds < 0 ? start - offset : start + offset, luminance: level)
    }

    @Test func aBrightFlatFrameBeforeTheDarkKeyLookCountsOnce() throws {
        let samples = [at(-30, 20), at(8, 54), at(25, 24), at(33, 24), at(100, 24)]
        let results = SummonLookMeter.analyse(samples, starts: [start])
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.flatFrames == 1)
        #expect(abs(result.firstPixels - 8) < 0.01)
        #expect(abs(result.keyLook - 25) < 0.01)
        #expect(abs(result.flatMilliseconds - 17) < 0.01)
        #expect(result.levels == [20, 54, 24, 24, 24])
    }

    @Test func aFirstFrameAtTheKeyLookHasNoFlatFrames() throws {
        let results = SummonLookMeter.analyse([at(-30, 20), at(20, 24), at(28, 24)], starts: [start])
        let result = try #require(results.first)
        #expect(result.flatFrames == 0)
        #expect(result.flatMilliseconds == 0)
        #expect(result.firstPixels == result.keyLook)
    }

    @Test func lightModeFlatFramesAreDarkerThanTheWallpaper() throws {
        let samples = [at(-30, 237), at(9, 228), at(17, 230), at(26, 254), at(60, 254)]
        let result = try #require(SummonLookMeter.analyse(samples, starts: [start]).first)
        #expect(result.flatFrames == 2)
    }

    @Test func eachSummonReadsOnlyItsOwnFrames() {
        let second = start + SummonLookMeter.ticks(milliseconds: 300)
        var samples = [at(-30, 20), at(8, 54), at(25, 24), at(160, 20)]
        samples.append(
            SummonLookMeter.Sample(displayTime: second + SummonLookMeter.ticks(milliseconds: 20), luminance: 24))
        let results = SummonLookMeter.analyse(samples.shuffled(), starts: [start, second])
        #expect(results.map(\.flatFrames) == [1, 0])
    }

    @Test func aKeyLookTooCloseToTheWallpaperIsSkipped() {
        let samples = [at(-30, 100), at(8, 120), at(25, 101)]
        #expect(SummonLookMeter.analyse(samples, starts: [start]).isEmpty)
        #expect(SummonLookMeter.analyse([at(8, 54)], starts: [start]).isEmpty, "no frame before the summon")
    }
}
