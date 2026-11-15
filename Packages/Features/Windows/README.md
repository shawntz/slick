# Window Management

Moves and resizes the frontmost window from the launcher or a hotkey, and switches between open windows. Read it next to `docs/FEATURES.md`.

No command has a hotkey. Two hotkey presets match popular window tools. Settings offers them, and nothing is bound until the user applies one. The whole feature can be turned off in the Features pane, for people who use another window manager.

## What it declares

| Kind | What |
|---|---|
| 28 layout commands | halves, quarters, thirds and two thirds, maximize, almost maximize, maximize height and width, center, make larger and smaller, move to each edge, next and previous display, restore |
| Command `toggle-full-screen` | Toggle Full Screen |
| Command `switch-windows` | Switch Windows, a list of open windows, most recent first |
| Hotkey presets | `rectangle` and `spectacle`, declared, never applied |
| Settings pane | window gap, screen gap, almost maximize size, what a repeated half does, a layout name message, the Accessibility status |

Every command needs Accessibility. The host checks it before a command runs and shows its grant card when it is missing.

## Where to look

| File | Shows |
|---|---|
| `Geometry/Frame.swift`, `Display.swift` | the coordinate space, pixel snapping, which display holds a window, display order and neighbors |
| `Geometry/Layout.swift` | every layout as data and the regions that tile a display |
| `Geometry/LayoutPlanner.swift` | the pure frame math for each layout, cycling, moving across displays, and settling a window that refused a size |
| `Geometry/Arranger.swift` | the one pass each service runs: plan, set, read back, correct once |
| `Service/WindowService.swift` | the feature's own service, its `FeatureServiceKey`, and the values it returns |
| `Service/AccessibilityWindows.swift`, `AXElement.swift` | the live service over Accessibility, on one background queue |
| `Service/SimulatedWindows.swift` | the isolated service: a desktop in memory, also the test double |
| `WindowsFeature.swift` | commands, settings pane, presets, restore memory and the last placement |
| `WindowList.swift` | the Switch Windows source and its actions |
| `Strings.swift` | every string a person reads |

## Rules this feature follows

- The geometry makes no system calls. Every layout runs on every display shape in the tests.
- A layout command builds a plain request on the main actor, then the service reads, plans, moves and reads back in one pass off the main thread.
- Tests and scenarios get `SimulatedWindows`. Nothing in the test suite moves a window it did not create.
- A display that reports no usable area is never a target, so no command sets a window of zero size.
- Close Window names the window and its app before it asks, since the list can go stale while it is open.
- Switch Windows builds its rows off the main thread. The live service matches windows to the stacking order per app, so a desk with thousands of windows still lists at once.

## Undocumented interfaces

Window moves use the public Accessibility API. Two attribute names it reads and writes are not in the SDK's headers. Other window managers use them too.

| Attribute | Why | When an app does not have it |
|---|---|---|
| `AXEnhancedUserInterface` | Apps animate frame changes while it is on, so it is turned off for a move and put back after | The read fails and the move goes ahead as is |
| `AXFullScreen` | Toggle Full Screen reads and sets it | The command reports that the window cannot go full screen |

No private function or framework is used.
