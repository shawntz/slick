import AppKit
import CoreGraphics
import Foundation

/// The `record` step: a clip of the panel in motion. The format is in docs/SCENARIOS.md.
///
/// ```json
/// { "record": { "name": "type-dark", "appearance": "dark" } }
/// ```
public struct ScenarioRecording: Sendable, Decodable, Equatable {
    /// The panel's look during the clip.
    public enum Appearance: String, Sendable, Decodable { case dark, light }
    /// What shows behind the panel.
    public enum Backdrop: String, Sendable, Decodable { case wallpaper, none }

    /// The size of the recorded area, in points: the published stills' frame, which is the glass
    /// with 90 points on each side.
    public static let canvasSize = CGSize(width: 940, height: 740)

    /// The clip's file name without an extension. Letters, digits, `-` and `_` only.
    public var name: String
    /// The panel's appearance. Nil keeps the Mac's.
    public var appearance: Appearance?
    /// The wallpaper of the published stills, or nothing.
    public var backdrop: Backdrop
    /// Seconds without keyboard or mouse input that the Mac must have had before the clip starts.
    public var idle: Double
    /// Scales the pauses between steps. 1 is a person's pace; 0 plays the steps at once.
    public var pace: Double
    /// Seconds the clip runs before the next step plays.
    public var lead: Double
    /// Frames per second to record. Nil records at the display's refresh rate.
    public var frameRate: Double?

    public init(
        name: String, appearance: Appearance? = nil, backdrop: Backdrop = .wallpaper, idle: Double = 120,
        pace: Double = 1, lead: Double = 0.6, frameRate: Double? = nil
    ) {
        self.name = name
        self.appearance = appearance
        self.backdrop = backdrop
        self.idle = idle
        self.pace = pace
        self.lead = lead
        self.frameRate = frameRate
    }

    private enum CodingKeys: String, CodingKey {
        case name, appearance, backdrop, idle, pace, lead, frameRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            appearance: try container.decodeIfPresent(Appearance.self, forKey: .appearance),
            backdrop: try container.decodeIfPresent(Backdrop.self, forKey: .backdrop) ?? .wallpaper,
            idle: try container.decodeIfPresent(Double.self, forKey: .idle) ?? 120,
            pace: try container.decodeIfPresent(Double.self, forKey: .pace) ?? 1,
            lead: try container.decodeIfPresent(Double.self, forKey: .lead) ?? 0.6,
            frameRate: try container.decodeIfPresent(Double.self, forKey: .frameRate))
        guard Self.isFileName(name) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "a clip name uses letters, digits, - and _ only")
        }
        guard idle >= 0, pace >= 0, lead >= 0, frameRate.map({ $0 > 0 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .idle, in: container, debugDescription: "idle, pace and lead are 0 or more; frameRate is more")
        }
    }

    /// True for a name that is safe as a file name on its own.
    static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0))
            }
    }
}

/// The `stopRecording` step: how long the clip runs on and which files it becomes.
public struct ScenarioClipOutput: Sendable, Decodable, Equatable {
    /// Seconds the clip runs after the last step.
    public var tail: Double
    /// Seconds into the clip for the poster picture. Nil takes the last frame.
    public var poster: Double?
    /// The most bytes the web MP4 may take.
    public var webMaxBytes: Int
    /// The GIF's width in pixels.
    public var gifWidth: Int
    /// The most bytes the GIF may take.
    public var gifMaxBytes: Int

    public init(
        tail: Double = 0.8, poster: Double? = nil, webMaxBytes: Int = 3_000_000, gifWidth: Int = 940,
        gifMaxBytes: Int = 6_000_000
    ) {
        self.tail = tail
        self.poster = poster
        self.webMaxBytes = webMaxBytes
        self.gifWidth = gifWidth
        self.gifMaxBytes = gifMaxBytes
    }

    private enum CodingKeys: String, CodingKey {
        case tail, poster, webMaxBytes, gifWidth, gifMaxBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tail: try container.decodeIfPresent(Double.self, forKey: .tail) ?? 0.8,
            poster: try container.decodeIfPresent(Double.self, forKey: .poster),
            webMaxBytes: try container.decodeIfPresent(Int.self, forKey: .webMaxBytes) ?? 3_000_000,
            gifWidth: try container.decodeIfPresent(Int.self, forKey: .gifWidth) ?? 940,
            gifMaxBytes: try container.decodeIfPresent(Int.self, forKey: .gifMaxBytes) ?? 6_000_000)
        guard tail >= 0, poster.map({ $0 >= 0 }) ?? true, webMaxBytes > 0, gifWidth >= 16, gifMaxBytes > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .tail, in: container, debugDescription: "tail and poster are 0 or more; sizes are positive")
        }
    }
}

/// Takes the clips for the `record` and `stopRecording` steps.
///
/// A build made with `SCENARIO_RECORDING=1` has ``ScenarioClipRecorder``, which uses
/// LauncherUITesting's recorder and encoders. Other builds have none, so the release app links
/// neither those nor the video frameworks, and a `record` step fails. Tests pass a fake.
@MainActor public protocol ScenarioRecorder: AnyObject {
    /// True once a person touched the keyboard or mouse during the clip. By then the recorder has
    /// put the panel away and given key status back; the runner stops the run.
    var inputArrived: Bool { get }
    /// The area the clip records, in AppKit screen coordinates, while a clip records. Nil otherwise.
    var canvas: CGRect? { get }
    /// Starts a clip of `panel`, writing into `folder`. Returns why it could not, or nil.
    func start(_ recording: ScenarioRecording, panel: PanelController, folder: URL) async -> String?
    /// Hears each step that ran during the clip, so the recorder can check the panel's look.
    func stepDidRun(_ step: ScenarioStep)
    /// Ends the clip and writes its files. Returns the paths written, or why it failed.
    func stop(_ output: ScenarioClipOutput) async -> Result<[String], ScenarioRecorderFailure>
    /// Ends the clip and deletes what it wrote, after a failed step or input.
    func cancel() async
}

/// Why a clip could not be finished.
public struct ScenarioRecorderFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// This app's windows that a clip shows besides the panel, such as the settings window a scenario
/// opened for a picture. The recorder keeps its wallpaper behind them and puts them away when a
/// person touches the Mac.
@MainActor public enum ScenarioWindows {
    /// This app's windows on screen inside `canvas`, front to back. `panel` and every other panel
    /// are left out.
    public static func shown(in canvas: CGRect, besides panel: NSWindow) -> [NSWindow] {
        NSApp.windows
            .filter { $0 !== panel && !($0 is NSPanel) && $0.isVisible && $0.frame.intersects(canvas) }
            .sorted { $0.orderedIndex < $1.orderedIndex }
    }
}

/// The pauses that make a recorded scenario play like a person at the keyboard. Each is in
/// seconds before the step or character, and the record step's `pace` scales them all.
nonisolated public enum ScenarioPacing {
    /// Gaps between typed characters: about eight a second, unevenly, as people type.
    static let characterGaps: [Double] = [0.105, 0.135, 0.095, 0.15, 0.115, 0.125, 0.1, 0.14]

    /// The pause before a step, given the step before it.
    public static func pause(before step: ScenarioStep, after previous: ScenarioStep?) -> Double {
        switch step {
        case .type:
            if case .type = previous { return 0 }
            return 0.3
        case .press(let keys):
            if case .press(let last) = previous, last == keys { return 0.24 }
            return keys.contains("+") ? 0.5 : 0.42
        case .summon: return 0.55
        case .dismiss: return 0.5
        case .clickLink: return 0.5
        case .wait, .waitUntilIdle, .expect, .fill, .capture, .record, .stopRecording, .still: return 0
        }
    }

    /// The pause before the character at `index` of a typed text.
    public static func pause(beforeCharacter character: Character, at index: Int) -> Double {
        guard index > 0 else { return 0 }
        let gap = characterGaps[index % characterGaps.count]
        return character == " " ? gap + 0.04 : gap
    }
}
