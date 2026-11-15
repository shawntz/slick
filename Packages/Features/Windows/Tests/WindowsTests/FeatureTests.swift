import Kit
import KitTesting
import Testing

@testable import Windows

@MainActor
@Suite("Window Management feature", .timeLimit(.minutes(1)))
struct FeatureTests {
    // MARK: - Declarations

    @Test func declaresCleanlyWithNoHotkeys() throws {
        let windows = WindowsHarness()
        let harness = windows.harness
        #expect(harness.issues.isEmpty)
        let commands = harness.feature.commands
        #expect(commands.count == WindowCommands.layouts.count + 2)
        #expect(commands.allSatisfy { $0.suggestedHotkey == nil }, "the user assigns hotkeys")
        #expect(commands.allSatisfy { $0.requires == [.accessibility] })
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(WindowsFeature.manifest.permissions.map(\.permission) == [.accessibility])
        #expect(WindowsFeature.manifest.isEnabledByDefault)
    }

    @Test func commandTitlesUseTitleCase() {
        let small: Set<String> = ["to", "a", "an", "the", "of", "and"]
        for command in WindowsHarness().harness.feature.commands {
            for word in command.title.split(separator: " ") where !small.contains(String(word)) {
                #expect(word.first?.isUppercase == true, "\(command.title)")
            }
        }
    }

    @Test func theIsolatedServiceIsTheSimulatedDesktop() {
        // A self-test run without an override never reaches Accessibility.
        let harness = FeatureHarness(WindowsFeature.self)
        #expect(harness.feature.windows is SimulatedWindows)
    }

    @Test func presetsAreDeclaredAndNeverApplied() async throws {
        let windows = WindowsHarness()
        let harness = windows.harness
        await harness.activate()
        let presets = harness.feature.hotkeyPresets
        #expect(presets.map(\.id) == ["rectangle", "spectacle"])
        let commandIDs = Set(harness.feature.commands.map(\.id))
        for preset in presets {
            #expect(Set(preset.bindings.keys).isSubset(of: commandIDs))
            #expect(Set(preset.bindings.values).count == preset.bindings.count)
            // The launcher's own hotkey stays free.
            #expect(!preset.bindings.values.contains(KeyCombo(.space, .command)))
        }
        #expect(harness.fakes.hotkeys.registered.isEmpty)
    }

    /// The owner may run a tiling window manager, so a default binding would fight it. The feature
    /// binds and suggests nothing: a layout gets a hotkey only from a preset or a recording the user
    /// chose in settings.
    @Test func noLayoutHotkeyIsBoundUntilTheUserChoosesOne() async throws {
        let windows = WindowsHarness()
        let harness = windows.harness
        await harness.activate()
        for layout in WindowCommands.layouts {
            try await windows.press(layout.id)
        }
        windows.settings[WindowsSettings.windowGap] = 8
        windows.settings[WindowsSettings.showsLayoutName] = true
        try await harness.settle()
        await harness.deactivate()
        await harness.activate()
        #expect(harness.fakes.hotkeys.registered.isEmpty)
        #expect(harness.feature.commands.allSatisfy { $0.suggestedHotkey == nil })
        #expect(harness.feature.hotkeyPresets.allSatisfy { !$0.bindings.isEmpty }, "offered, not applied")
    }

    @Test func presetsUseKitsKeysForMinusAndEqual() {
        #expect(WindowHotkeyPresets.rectangle.bindings["make-smaller"] == KeyCombo(.minus, [.control, .option]))
        #expect(WindowHotkeyPresets.rectangle.bindings["make-larger"] == KeyCombo(.equal, [.control, .option]))
        #expect(KeyCombo(.minus, [.control, .option]).displayString == "⌃⌥-")
    }

    // MARK: - Running layouts

    @Test func leftHalfMovesTheFocusedWindowQuietly() async throws {
        let windows = WindowsHarness()
        try await windows.press("left-half")
        #expect(windows.frame == Frame(x: 0, y: 33, width: 756, height: 879))
        #expect(windows.harness.huds.isEmpty, "no message by default")
        #expect(windows.harness.isClosed)
    }

    @Test func repeatedPressesCycleAndNameEachSize() async throws {
        let windows = WindowsHarness()
        windows.settings[WindowsSettings.showsLayoutName] = true
        var widths: [Double] = []
        for _ in 0..<4 {
            try await windows.press("left-half")
            widths.append(windows.frame?.width ?? 0)
        }
        #expect(widths == [756, 1008, 504, 756])
        #expect(windows.harness.huds.map(\.title) == ["Left Half", "Left Two Thirds", "Left Third", "Left Half"])
    }

    @Test func pressesFromTheLauncherCycleToo() async throws {
        let windows = WindowsHarness()
        try await windows.harness.run("right-half")
        try await windows.harness.run("right-half")
        #expect(windows.frame == Frame(x: 504, y: 33, width: 1008, height: 879))
    }

    @Test func aWindowMovedByHandStartsTheCycleOver() async throws {
        let windows = WindowsHarness()
        try await windows.press("left-half")
        windows.desktop.update(WindowsHarness.editor.ref) { $0.frame = Frame(x: 40, y: 60, width: 700, height: 600) }
        try await windows.press("left-half")
        #expect(windows.frame?.width == 756)
    }

    @Test func theRepeatSettingChangesWhatAPressDoes() async throws {
        let windows = WindowsHarness()
        windows.settings[WindowsSettings.repeatBehavior] = .moveAcrossDisplays
        try await windows.press("right-half")
        try await windows.press("right-half")
        #expect(windows.frame == Frame(x: 1512, y: 25, width: 960, height: 1055))

        let still = WindowsHarness()
        still.settings[WindowsSettings.repeatBehavior] = .none
        try await still.press("left-half")
        try await still.press("left-half")
        #expect(still.frame?.width == 756)
    }

    @Test func gapsComeFromSettings() async throws {
        let windows = WindowsHarness()
        windows.settings[WindowsSettings.screenGap] = 10
        windows.settings[WindowsSettings.windowGap] = 8
        try await windows.press("right-half")
        #expect(windows.frame == Frame(x: 760, y: 43, width: 742, height: 859))
        // Values outside the pane's range are clamped.
        windows.settings[WindowsSettings.screenGap] = 500
        #expect(WindowsSettings.options(windows.settings).screenGap == 48)
    }

    @Test func almostMaximizeFollowsItsSetting() async throws {
        let windows = WindowsHarness()
        windows.settings[WindowsSettings.almostMaximizePercent] = 50
        try await windows.press("almost-maximize")
        #expect(windows.frame == Frame(x: 378, y: 253, width: 756, height: 439.5))
    }

    @Test func restoreReturnsToTheFrameBeforeTheFirstMove() async throws {
        let windows = WindowsHarness()
        let original = WindowsHarness.editor.frame
        try await windows.press("left-half")
        try await windows.press("maximize")
        try await windows.press("center")
        try await windows.press("restore")
        #expect(windows.frame == original)
        // Once restored there is nothing more to restore.
        try await windows.press("restore")
        #expect(windows.harness.huds.map(\.title) == [Strings.nothingToRestore])
    }

    @Test func restoreRemembersWhereTheUserLastPutTheWindow() async throws {
        let windows = WindowsHarness()
        try await windows.press("left-half")
        let byHand = Frame(x: 300, y: 300, width: 500, height: 400)
        windows.desktop.update(WindowsHarness.editor.ref) { $0.frame = byHand }
        try await windows.press("maximize")
        try await windows.press("restore")
        #expect(windows.frame == byHand)
    }

    @Test func displayCommandsMoveBetweenDisplays() async throws {
        let windows = WindowsHarness()
        try await windows.press("left-half")
        try await windows.press("next-display")
        #expect(windows.frame == Frame(x: 1512, y: 25, width: 960, height: 1055))
        try await windows.press("previous-display")
        #expect(windows.frame == Frame(x: 0, y: 33, width: 756, height: 879))

        let single = WindowsHarness(displays: [Displays.laptop])
        try await single.press("next-display")
        #expect(single.harness.huds.map(\.title) == [Strings.onlyOneDisplay])
        #expect(single.frame == WindowsHarness.editor.frame)
    }

    @Test func resizingAtTheLimitSaysSo() async throws {
        let windows = WindowsHarness()
        try await windows.press("maximize")
        try await windows.press("make-larger")
        #expect(windows.harness.huds.map(\.title) == [Strings.largest])
        try await windows.press("make-smaller")
        #expect(windows.frame == Frame(x: 16, y: 49, width: 1480, height: 847))
    }

    @Test func fullScreenTogglesAndBlocksLayouts() async throws {
        let windows = WindowsHarness()
        try await windows.press(WindowCommands.toggleFullScreenID)
        #expect(windows.desktop.focused?.isFullScreen == true)
        try await windows.press("left-half")
        #expect(windows.harness.huds.map(\.title) == [Strings.fullScreen])
        #expect(windows.desktop.frameSets == 0)
        try await windows.press(WindowCommands.toggleFullScreenID)
        #expect(windows.desktop.focused?.isFullScreen == false)
    }

    @Test func noWindowAndUnmovableWindowsSayWhy() async throws {
        let empty = WindowsHarness(windows: [])
        try await empty.press("maximize")
        try await empty.press(WindowCommands.toggleFullScreenID)
        #expect(empty.harness.huds.map(\.title) == [Strings.noWindow, Strings.noWindow])

        var fixed = WindowsHarness.editor
        fixed.canMove = false
        let stuck = WindowsHarness(windows: [fixed])
        try await stuck.press("maximize")
        #expect(stuck.harness.huds == [.failure(Strings.cannotMove)])
    }

    // MARK: - Permission

    @Test func missingAccessibilityStopsBeforeAnythingMoves() async throws {
        let windows = WindowsHarness(permissions: .notDetermined)
        for command in ["left-half", WindowCommands.toggleFullScreenID, WindowCommands.switchWindowsID] {
            await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
                try await windows.press(command)
            }
        }
        #expect(windows.desktop.frameSets == 0)
        #expect(windows.harness.fakes.permissions.requests.isEmpty, "nothing asked the system")
    }

    @Test func accessibilityTurnedOffWhileRunningAsksTheHostAgain() async throws {
        let windows = WindowsHarness()
        windows.desktop.accessibilityGranted = false
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await windows.press("maximize")
        }
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await windows.press(WindowCommands.toggleFullScreenID)
        }
        #expect(windows.desktop.frameSets == 0)
    }

    @Test func memoryStaysBounded() {
        var memory = RestoreMemory()
        for index in 0..<(RestoreMemory.capacity + 10) {
            let frame = Frame(x: Double(index), y: 0, width: 100, height: 100)
            memory.record(Moved(window: "1_\(index)", before: frame, after: frame, step: 0))
        }
        #expect(memory.count == RestoreMemory.capacity)
        #expect(memory.frames["1_0"] == nil)
        #expect(memory.frames["1_\(RestoreMemory.capacity + 9)"] != nil)
    }
}
