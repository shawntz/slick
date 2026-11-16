# Media Controls

Play, pause and skip in Apple's Music app and in Spotify from the launcher. The package is `Music` and the module is `MusicControls`, because the SDK has modules named `MediaPlayer`, `MusicKit` and `NowPlaying`, and a private framework named `MediaControl`. The feature ID is `media`.

## What it declares

| Command | ID | Does |
|---|---|---|
| Play or Pause | `play-pause` | pauses the player that plays, or plays the one that does not; its row shows the current track as a live subtitle |
| Pause | `pause` | pauses the player that plays; with no player playing it sends nothing and says so, so typing "pause" never starts one |
| Next Track | `next-track` | skips ahead |
| Previous Track | `previous-track` | goes back to the previous track |
| Now Playing | `now-playing` | shows the title, artist, album, player and time in a HUD, and sends nothing |

Each command closes the panel with a HUD that says what happened, such as the new track's title. While a player runs none asks first. None pastes and none changes data, so each may run from a deep link after the host's page that asks.

Settings: the preferred player, Music by default. Two hotkey presets for the three transport commands: Function Keys, which uses F7, F8 and F9, and Control, Option and Command, which uses those modifiers with Space and the brackets. Nothing is bound until the user applies one.

Permissions: Automation for Music and Automation for Spotify, each asked only through the host's card.

## Which player

Only running players are candidates. Each is asked what it does, the preferred one first.

1. A player that plays wins. When both play, the preferred one.
2. Otherwise, a running player whose permission was never asked stops the command with the host's card: it may be the one that plays. A player the user refused is left out.
3. Otherwise, the first player that answered, so the preferred one when it answered.
4. When no player runs, the command asks "Open Music?", or the preferred player's name, and opens it only on Open. It never starts a player by itself. Pause asks nothing then: it says nothing is playing.

## Where to look

| File | Shows |
|---|---|
| `MediaControlsFeature.swift` | the manifest, the service, the settings pane |
| `Commands/TransportCommands.swift` | the five commands, the offer to open a player, the reads after a skip |
| `Commands/MediaHotkeyPresets.swift` | the presets and the command IDs |
| `Choosing/PlayerChooser.swift` | which player a command acts on |
| `Choosing/NowPlayingMonitor.swift` | the live subtitle, at most one ask every two seconds |
| `Service/PlayerService.swift` | the service protocol, its failures and its `FeatureServiceKey` |
| `Service/LivePlayers.swift` | the Apple Events; never run in tests or scenarios |
| `Service/ScriptingTerms.swift` | every four-character code, once, with the term it stands for |
| `Service/SimulatedPlayers.swift` | the made-up queues for tests, scenarios, self-tests and benchmarks |
| `Model/TrackText.swift` | names made safe to show, and times |
| `Strings.swift` | every string a person reads |

## Rules this feature follows

- Every side effect goes through `PlayerService`. Outside the live launcher the feature gets `SimulatedPlayers`, so nothing reaches an app.
- Whether a player runs comes from `NSRunningApplication`, which needs no permission. Events go to the running process by its process ID, so a player that quit is never started again by an event.
- Before every event the live service checks the Automation permission without asking, and every send carries `kAEDoNotPromptForUserConsent`. A missing permission becomes the host's card.
- No service call runs on the main actor. Every requirement is `@concurrent`.
- A run cancelled while it asks the players, as when the feature is turned off, sends nothing, and one cancelled while "Open Music?" waits opens nothing.
- Activation does nothing. The feature runs no timer: root search fetches the live subtitle only while the row is on screen, and the monitor answers from memory within two seconds of the last ask.
- Track, artist and album names go through `TrackText`: one line, direction controls shown as U+FFFD, invisible names replaced, long names cut.

## Not verified

The live service has never run. Music's codes were checked against `com.apple.Music.sdef` on macOS 27.2. Spotify's codes come from its dictionary as known and need a check with `sdef` against an installed copy before the first live use.
