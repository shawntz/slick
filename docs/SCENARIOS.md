# Scenarios

A scenario is a JSON file of steps that drives the real panel the way a person would: it shows the panel, types, presses keys, waits for work to finish, checks what the panel shows and captures pictures. App runs one with `--scenario <file>`, and `make scenario S=<file>` builds the app and runs it through LaunchServices.

The runner is `ScenarioRunner` in the Host package. It drives a `PanelController` that App builds over the real root search and features in the `scenario` run environment, so side effects go to fakes and data lives in a temporary folder.

## What the runner guarantees

- Keys reach the panel through the same entry points the keyboard uses: the search field's delegate, the focused card or form field's editor, and the overlay's own key handling. Nothing is posted to the system.
- Key events from the hardware are dropped while a scenario runs, so a person typing at the Mac cannot change the result.
- The panel sits in the bottom-left corner of the main screen and never takes key status, except during a capture that asks for the key look. That capture holds key status for about 120 ms.
- The whole run is bounded by the scenario's time limit. Every wait and every capture stops at it.
- Captures and `result.json` go to the output folder. The last line printed is `scenario PASS`, or `scenario FAIL: ` followed by the step and the reason.

## File format

```json
{
  "name": "Root search opens a list and filters it",
  "timeLimit": 20,
  "steps": [
    { "summon": true },
    { "type": "shelf" },
    { "expect": { "selection": "Open Shelf" } },
    { "press": "return" },
    { "waitUntilIdle": 2 },
    { "expect": { "page": "list", "title": "Shelf" } },
    { "capture": "shelf" },
    { "dismiss": true }
  ]
}
```

| Key | Type | Meaning |
|---|---|---|
| `name` | string | Printed at the start and written to `result.json`. Required. |
| `timeLimit` | number | Seconds the whole run may take. Default 30, at most 120. |
| `steps` | array | Run in order. The first step that fails ends the run. |

Each step is an object with exactly one key, the step's name. An unknown name, or an object with two keys, makes the file unreadable and the run fails before it starts.

## Steps

| Step | Value | What it does |
|---|---|---|
| `summon` | `true` | Shows the panel without key status. Fails when the panel does not show. |
| `dismiss` | `true` | Hides the panel, as Escape on an empty root search does. |
| `type` | string | Types each character at the end of whatever has the keyboard: the search field, a card's filter field or a form field. Each character in the search field is one keystroke. |
| `press` | string | Presses one key combination. See "Keys". |
| `waitUntilIdle` | seconds | Waits until nothing loads, streams, submits, runs or animates, checked twice in a row 10 ms apart. Fails with what is still busy when the time runs out. |
| `wait` | seconds | Waits. Use `waitUntilIdle` when you can. |
| `expect` | object | Checks what the panel shows. See "Expectations". |
| `clickLink` | string | Clicks the link with this target in the detail shown, on a detail page or in the pane beside a list, as a person would. Fails when the detail shows no such link. |
| `fill` | `{ "field": id, "value": text }` | Sets a form field as if the user had entered it. A checkbox takes `"true"` or `"false"`, a dropdown an option's value, a tags field words separated by commas, and a files field one path. Fails when the top page is not a form or has no such field. |
| `capture` | name, or `{ "name": name, "key": true }` | Writes `captures/<name>.png` in the output folder. With `key`, the panel takes key status for about 120 ms so the glass shows its key look. Fails when the panel is hidden or the capture takes longer than 5 s. |
| `record` | object | Starts a clip. See "Recording a clip". |
| `stopRecording` | `true` or object | Ends the clip and writes its files. See "Recording a clip". |
| `still` | string | During a clip, writes `captures/<name>.png` of the clip's whole recorded area: the wallpaper and every window of this app over it. The panel may be hidden. See "Recording a clip". |

## Keys

A key combination is its modifiers and its key joined by `+`, such as `down`, `return`, `cmd+k`, `shift+cmd+return` or `ctrl+n`.

- Modifiers: `cmd`, `shift`, `opt` and `ctrl`. `option` and `alt` also name `opt`, and `control` names `ctrl`.
- Named keys: `up`, `down`, `left`, `right`, `return`, `escape`, `tab`, `delete`, `space`, `comma`, `plus` and `minus`. `enter`, `esc` and `backspace` also work.
- Any other key is one character, such as `k`, `1` or `,`.

Where a key goes:

- While a card shows, plain keys go to the card: arrows move its selection, Return runs the selected entry, Escape clears its filter or closes it. Command chords go to the panel, so `cmd+k` closes the action panel.
- While a form field has the keyboard, plain keys go to the field: Tab moves to the next field, Escape leaves the form. Command chords go to the panel, so `cmd+return` submits.
- Otherwise keys go to the panel's keyboard model, exactly as the search field reports them: `delete` removes the last character, or goes back when the field is empty; `escape` clears the query, then goes back, then dismisses; a plain character is typed.

## Expectations

Every key is optional. Each key present must hold, and the step reports every one that does not.

| Key | Type | Holds when |
|---|---|---|
| `rows` | strings | The titles of every shown row, or every cell in a grid, are exactly these, in order. |
| `rowsInclude` | strings | Each of these titles is among the shown rows or cells. |
| `rowCount` | number | This many rows or cells show. |
| `selection` | string | The selected row's or cell's title. `""` means nothing is selected. |
| `toast` | string | The action bar shows this toast text. A toast with a message reads `Title: message`. `{brand}` stands for the app's name, which a file never writes out. |
| `noToast` | `true` | No toast shows. |
| `title` | string | The top page's title, as the breadcrumb shows it. Empty for root search. |
| `ghost` | string | The ghost completion after the typed text. |
| `query` | string | The search field's text. |
| `page` | string | The top page's kind: `root`, `list`, `grid`, `detail`, `form`, `quickLook` or `other`. |
| `detailIncludes` | string | The detail page, or the detail pane beside a list, contains this text. |
| `actions` | strings | The action panel is open and its entries have exactly these titles, in order. |
| `visible` | bool | The panel is on screen, or hidden. |
| `fieldErrors` | strings | Exactly these form field IDs show an error, in any order. `[]` means none. |
| `card` | string | The title of the confirmation or permission card waiting for an answer. `""` means none. |
| `largeType` | string | The text Large Type showed last in the run. `""` when it showed nothing. Large Type is recorded, never shown, outside the live app. |

## Recording a clip

A `record` step starts a clip of the panel, and `stopRecording` ends it. The steps between play in real time at a person's pace, and every frame the window server shows is recorded.

```json
{ "record": { "name": "hero-dark", "appearance": "dark" } },
{ "type": "dr" },
{ "wait": 1.6 },
{ "press": "return" },
{ "stopRecording": { "poster": 3.0 } }
```

Only a build made with `SCENARIO_RECORDING=1` in its environment can record. Host's manifest then links LauncherUITesting's recorder, MP4 writer and GIF encoder, which bring AVFoundation and VideoToolbox. A build without it, such as `make app`, links none of that, and a `record` step fails with a reason that says so. `scenarios/media/record.sh` makes the recording build in `build/media`, away from the release app.

`record` takes:

| Key | Default | Meaning |
|---|---|---|
| `name` | required | The clip's file name: letters, digits, `-` and `_`. |
| `appearance` | the Mac's | `dark` or `light`, for this process only. |
| `backdrop` | `wallpaper` | The published stills' wallpaper behind the panel, or `none`. |
| `idle` | 120 | Seconds without keyboard or mouse input the Mac must have had. The step fails at once when it has had fewer. |
| `pace` | 1 | Scales every pause below. 0 plays the steps at once. |
| `lead` | 0.6 | Seconds recorded before the next step plays. |
| `frameRate` | the display's | Frames per second to record. |

What happens:

- The recorded area is 940 by 740 points in the bottom-left corner of the main screen, the frame of the published stills. The panel moves so its glass sits centered across it and 6 points above its middle, and moves back afterwards. When something moves the window during the clip, such as a theme with other metrics, it is put back at once.
- The panel takes key status for the whole clip, so the glass shows its key look, and every summon makes it key. After each step the recorder checks that a visible panel is key. A clip where it was not fails, because its glass looked flat.
- The pauses are a person's: 0.3 s before typing starts, then about eight characters a second at uneven gaps, 0.42 s before a key press, 0.24 s between repeats of the same key, 0.5 s before a Command chord, 0.55 s before a summon and 0.5 s before a dismiss. `wait` steps add holds. Expectations and `waitUntilIdle` add none.
- A capture during a clip keeps the clip's wallpaper and key status.
- A window of this app that is open inside the recorded area when the clip starts, such as the settings window from `openSettings` or the onboarding window from `openOnboarding`, stays in front: the wallpaper takes its level, just below it, and a `still` step pictures it over the wallpaper. Open it before `record`. A window opened during the clip sits behind the wallpaper. When input arrives, such windows are put away with the panel.
- The moment anyone touches the keyboard, mouse or trackpad, the panel is put away, key status goes back, and the run fails with "input arrived during the clip, so it was thrown out". A failed step also throws the clip out. So does a file that ends while a clip records.

`stopRecording` takes `tail`, the seconds recorded after the last step, 0.8 by default, and `poster`, the second of the clip for the poster picture, the last frame by default. `webMaxBytes`, 3,000,000, `gifWidth`, 940, and `gifMaxBytes`, 6,000,000, set the budgets. It writes into `clips/` in the output folder:

| File | What it is |
|---|---|
| `<name>-master.mp4` | Every frame as recorded, H.264 at 24 Mbit/s, at the display's pixel scale. |
| `<name>.mp4` | The web copy: the first of 60 fps at 8 and 5 Mbit/s, then 30 fps at 4 and 2.5 Mbit/s, then smaller sizes, that fits the budget. |
| `<name>.gif` | The README copy, 20 fps with 256 colours, or fewer frames and colours until it fits. |
| `<name>-poster.png` | The frame at `poster`, full size. |
| `<name>-sheet.png`, `<name>-start.png` | Frames across the clip, and its first 18 frames at 30 fps, for checking it by eye. |
| `<name>.json` | Length, frame count, the longest gap between frames, frames the writer dropped, idle time at the start and every file's size and settings. |

The files are listed in `result.json` with the captures.

## Output

The output folder holds:

- `result.json`: `name`, `passed`, `reason`, `seconds`, `captures` and `steps`. `reason` is absent when the run passed. `captures` lists file paths, clips included. `steps` has one entry per step run, with `index`, `step`, `passed`, `milliseconds` and `note`, which is the reason a step failed.
- `captures/<name>.png`: one picture per `capture` step, at the display's pixel scale.
- `clips/`: the files of each clip. See "Recording a clip".

Standard output gets one line per step, `step 3 expect: ok`, and the verdict last.

## Writing a scenario

- Wait with `waitUntilIdle` after anything that loads: pushing a page, a custom-filtered keystroke, a submit.
- A Return pressed while an async section still loads is fine: closing the panel cancels the section and the root page is idle again.
- Check one thing per `expect` where a failure would be ambiguous. A step reports every key that does not hold.
- Use invented data only. A scenario never names real people, files or apps.
- Captures in a scenario run against App's real root search show whatever that build's catalog holds. Use the scenario environment's fixtures for anything you commit.

## App steps and file keys

App adds steps of its own for what only the app can see or do, written `{ "app": { ... } }` among these steps, and two file keys: `startTime`, the moment the run's clock starts, and `systemApps`, which lists Apple's own apps with their real icons. scenarios/README.md documents every key. The ones a person reaches for most:

- `select`: picks a row by its title, with Down and Up as a person would. Use it instead of counting Down presses, which break when a feature adds or hides a row.
- `waitForRow`: waits, 5 s at most, until a row shows on a page that fills itself after its own read.
- `setTime`, `sessionStart` and `frontApp`: move the run's clock, play a wake and put an app in front, so suggestions before typing can be proved. The run's clock reads UTC and US English.
- `openSettings`, `captureSettings` and `closeSettings`: open the real settings window on a pane at a fixed place without key status or a saved frame, capture it and close it.
- `makeFiles` and `chooseFiles`: write made-up files in the run's own home folder, which shows as `~`, and hand them to the next open dialog, as for an import. `homeFiles` checks that files exist there, and `openDialogs` counts the open dialogs asked for.
- `openOnboarding`, `captureOnboarding` and `closeOnboarding`: the same for the onboarding window on a named step, such as `hotkey`. It applies no switch and marks onboarding not done. To picture the hotkey step with the Spotlight walkthrough, first make the hotkey wait: play `systemShortcuts` with `cmd+space`, then set `launcherHotkey` to another combination and back.

## Examples

- `Packages/Host/Tests/Scenarios/root-to-list.json`: ghost completion, opening a list from root search, filtering it, the action panel, Escape's three steps and a capture.
- `Packages/Host/Tests/Scenarios/form-validation.json`: a form's required field, its validator's error, a valid submit and the toast it shows.
- `scenarios/media/*.json`: the clips on the website and in the README. `make media` records them.
- `scenarios/*.json`: the joined app, every feature included. `make test-App` runs them headless.

`ScenarioTests` runs the two Host examples against the host's test features and fake root search, with the panel off screen and a stand-in capture.

## Calling the runner from App

```swift
let runner = ScenarioRunner(panel: panel, output: outputFolder)
runner.makeBackdrop = { frame in BackdropWindow(kind: .busy, frame: frame) }
let passed = await runner.run(file: scenarioURL)
exit(passed ? 0 : 1)
```

A build with recording sets `runner.recorder` itself; tests pass a fake `ScenarioRecorder`.

`ScenarioRunner(panel:output:placesInCorner:)` moves the panel to the bottom-left corner, turns off following the pointer's screen and turns off taking key status. `capture` defaults to `PanelSnapshot.capture`, ScreenCaptureKit of this process's own windows, which needs no permission. `makeBackdrop` is optional; without it a capture shows the panel over transparency.
