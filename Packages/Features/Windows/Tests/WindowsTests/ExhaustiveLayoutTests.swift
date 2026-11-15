import Testing

@testable import Windows

/// Every layout command, on every display in the fixtures, with several gap settings and window
/// shapes, checked against the rules every result must keep.
@Suite("Every layout on every display", .timeLimit(.minutes(1)))
struct ExhaustiveLayoutTests {
    static let optionSets: [LayoutOptions] = [
        LayoutOptions(),
        LayoutOptions(screenGap: 10, windowGap: 8),
        LayoutOptions(screenGap: 7, windowGap: 13, almostMaximizeFraction: 0.75),
        LayoutOptions(screenGap: 48, windowGap: 48, almostMaximizeFraction: 0.5),
    ]

    /// Window shapes relative to a display: inside, hanging off an edge, larger than the display,
    /// and tiny.
    static func windows(on display: Display) -> [(name: String, frame: Frame, fits: Bool)] {
        let v = display.visibleFrame
        return [
            (
                "inside",
                Frame(
                    x: v.minX + v.width * 0.2, y: v.minY + v.height * 0.2, width: v.width * 0.4, height: v.height * 0.4),
                true
            ),
            (
                "hanging",
                Frame(x: v.maxX - v.width * 0.3, y: v.minY + 50, width: v.width * 0.4, height: v.height * 0.5), true
            ),
            ("oversized", Frame(x: v.minX - 20, y: v.minY - 10, width: v.width + 100, height: v.height + 60), false),
            ("tiny", Frame(x: v.midX, y: v.midY, width: 120, height: 80), true),
        ]
    }

    @Test(arguments: Displays.singles)
    func everyResultIsOnScreenAndOnThePixelGrid(_ display: Display) {
        var checked = 0
        for options in Self.optionSets {
            let area = display.layoutArea(screenGap: options.screenGap)
            for shape in Self.windows(on: display) {
                for command in WindowCommands.layouts {
                    let context =
                        "\(command.id) on \(display.id), \(shape.name), gaps \(options.screenGap)/\(options.windowGap)"
                    let result = LayoutPlanner.plan(
                        request(command.layout, command: command.id, options: options), window: window(shape.frame),
                        displays: [display])
                    switch (command.layout, result) {
                    case (.display, .failure(let reason)):
                        #expect(reason == .onlyOneDisplay, "\(context)")
                    case (.restore, .failure(let reason)):
                        #expect(reason == .nothingToRestore, "\(context)")
                    case (.resize, .failure(let reason)):
                        #expect(reason == .atLimit, "\(context)")
                    case (_, .failure(let reason)):
                        Issue.record("\(context): \(reason)")
                    case (let layout, .success(let plan)):
                        checked += 1
                        let frame = plan.frame
                        #expect(frame.width > 0 && frame.height > 0, "\(context)")
                        // Layouts that keep the window's own size put only its origin on the grid.
                        let origin = Frame(x: frame.x, y: frame.y, width: 0, height: 0)
                        switch layout {
                        case .center, .moveToEdge, .maximizeHeight, .maximizeWidth:
                            #expect(isOnPixelGrid(origin, scale: display.scale), "\(context): \(frame)")
                        default:
                            #expect(isOnPixelGrid(frame, scale: display.scale), "\(context): \(frame)")
                        }
                        #expect(plan.scale == display.scale, "\(context)")
                        let keepsSize: Bool
                        switch layout {
                        case .moveToEdge, .resize: keepsSize = true
                        default: keepsSize = false
                        }
                        if shape.fits || !keepsSize {
                            #expect(contains(display.visibleFrame, frame), "\(context): \(frame)")
                        }
                        switch layout {
                        case .half, .quarter, .thirds, .maximize:
                            #expect(contains(area, frame, slack: 0), "\(context): \(frame)")
                        case .moveToEdge:
                            #expect(frame.size == shape.frame.size, "\(context) resized the window")
                        default:
                            break
                        }
                    }
                }
            }
        }
        #expect(checked > 300)
    }

    @Test(arguments: Displays.singles)
    func everyHalfCyclesBackToTheStart(_ display: Display) throws {
        for options in Self.optionSets {
            for command in WindowCommands.halves {
                var frame = Self.windows(on: display)[0].frame
                var last: Placement?
                var steps: [Frame] = []
                for _ in 0..<4 {
                    let plan = try planned(
                        request(command.layout, command: command.id, options: options, last: last),
                        window: window(frame), displays: [display])
                    steps.append(plan.frame)
                    last = Placement(command: command.id, window: "1_1", frame: plan.frame, step: plan.step)
                    frame = plan.frame
                }
                #expect(steps[0] == steps[3], "\(command.id) on \(display.id)")
                #expect(Set(steps[0..<3]).count == 3, "\(command.id) on \(display.id)")
            }
        }
    }

    @Test(arguments: Array(Displays.desks.indices))
    func nextThenPreviousComesBack(_ deskIndex: Int) throws {
        let desk = Displays.desks[deskIndex]
        for options in Self.optionSets {
            for source in desk {
                let regionFrames = [Layout.halfRegion(.left, fraction: 0.5), Layout.quarterRegion(.bottomRight)].map {
                    $0.frame(
                        in: source.layoutArea(screenGap: options.screenGap), windowGap: options.windowGap,
                        scale: source.scale)
                }
                for (index, start) in (regionFrames + [Self.windows(on: source)[0].frame]).enumerated() {
                    let context = "desk \(deskIndex), from \(source.id), frame \(index)"
                    let there = try planned(
                        request(.display(offset: 1), options: options), window: window(start), displays: desk)
                    let target = try #require(desk.holding(there.frame))
                    #expect(target.id != source.id, "\(context)")
                    #expect(contains(target.visibleFrame, there.frame), "\(context): \(there.frame)")
                    #expect(isOnPixelGrid(there.frame, scale: target.scale), "\(context)")
                    let back = try planned(
                        request(.display(offset: -1), options: options), window: window(there.frame), displays: desk)
                    #expect(desk.holding(back.frame)?.id == source.id, "\(context)")
                    if index < regionFrames.count {
                        // A region comes back exactly. A scaled frame within the rounding of two moves.
                        #expect(back.frame == start, "\(context): \(back.frame) != \(start)")
                    } else {
                        #expect(back.frame.isClose(to: start, tolerance: 2), "\(context): \(back.frame) != \(start)")
                    }
                }
            }
        }
    }
}
