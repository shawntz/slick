# System

System commands: the things people do from a launcher instead of hunting through menus. The module is `SystemCommands`, because the macOS SDK already has a Swift module named `System`.

## What it declares

| Command | ID | Asks first |
|---|---|---|
| Sleep | `sleep` | no |
| Sleep Displays | `sleep-displays` | no |
| Lock Screen | `lock-screen` | no |
| Start Screen Saver | `start-screen-saver` | no |
| Log Out | `log-out` | always |
| Restart | `restart` | always |
| Shut Down | `shut-down` | always |
| Open Trash | `open-trash` | no |
| Empty Trash | `empty-trash` | always, with the number of items |
| Eject All Disks | `eject-all-disks` | yes, with the disk names; the user may turn it off |
| Toggle Hidden Files | `toggle-hidden-files` | no |
| Toggle Dark Mode | `toggle-dark-mode` | no |
| Mute, Unmute, Toggle Mute | `mute`, `unmute`, `toggle-mute` | no |
| Volume Up, Volume Down | `volume-up`, `volume-down` | no |
| Set Volume | `set-volume`, argument `level` from 0 to 100 | no |
| Kill Process | `kill-process`, a list page | Quit and Force Quit always ask |

Quit All Applications belongs to the Applications feature.

## Where to look

| File | Shows |
|---|---|
| `SystemFeature.swift` | the manifest, the five services and the settings pane |
| `Strings.swift` | every string a person reads |
| `SystemFailure.swift` | how a service failure becomes a permission card or a sentence |
| `*/…Service.swift` | each group's service protocol and its `FeatureServiceKey` |
| `*/Live….swift` | the code that acts on the Mac; never run in tests or scenarios |
| `*/Simulated….swift` | the isolated implementations, which are also the test doubles |
| `Processes/ProcessRows.swift` | CPU use from two samples, sorting and the protected list, all pure |
| `Processes/ProcessList.swift` | the Kill Process page and its actions |
| `Tests/SystemCommandsTests/SystemHarness.swift` | the feature over every simulated service |
| `Tests/SystemCommandsTests/HardeningTests.swift` | the safety rules of the live services, and odd input |

## Rules this feature follows

- Every side effect goes through one of five services. Tests, scenarios, self-tests and benchmarks get the simulated ones, so nothing they do can sleep the Mac, empty the Trash or quit a process.
- No service call runs on the main actor. Each one is `@concurrent`.
- Apple Events check permission without asking first. When macOS would ask, the command returns `.needsPermission` and the host shows its card.
- The process list shows only the user's own processes, never this app, PID 1 or below, or the processes that keep the session alive. Quitting checks that the PID still names the same process, then checks the protected list again on the name, path and bundle ID the system reports at that moment, so a stale or wrong row can never end a protected process.
- Emptying the Trash unlocks a locked item before a second try, but never a link, whose flags could belong to a file outside the Trash.
- "Never eject" compares names without case or width and takes `*` as a wildcard, as in `Backup*`.
