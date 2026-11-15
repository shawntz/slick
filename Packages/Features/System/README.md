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
| Empty Trash | `empty-trash` | always, with the number of items when Finder gives it |
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
- Finder counts and empties the Trash through Apple Events, so the command needs Automation for Finder and never Full Disk Access. Finder's Trash takes in every volume and iCloud Drive, and Finder decides about locked items and items in use, as its own Empty Trash does. Finder's own warning is turned off for that one empty and put back, because the command has already asked.
- "Never eject" compares names without case or width and takes `*` as a wildcard, as in `Backup*`.

## Private and undocumented interfaces

The architect accepts these for an app outside the App Store. Each one fails with a clear message when macOS changes it.

| Command | What it uses | When it is missing |
|---|---|---|
| Lock Screen | `SACLockScreenImmediate`, a private function in `/System/Library/PrivateFrameworks/login.framework`, looked up with `dlopen` and `dlsym` | Before the panel closes, the command says Lock Screen is not available in this version of macOS and names the key combination that locks the screen |
| Toggle Hidden Files | Finder's `AppleShowAllFiles` preference key, which Apple does not document | Finder ignores the key, and the command reports what it wrote |

Every other command uses public frameworks, documented Apple Events from Finder's, System Events' and loginwindow's scripting definitions, or `pmset`.
