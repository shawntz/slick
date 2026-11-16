# Colors

Pick a color on screen, keep the colors you use, and convert colors you type between the formats people who design and build need. The module is `ColorTools`, so it cannot clash with a type or module named Colors.

## What it declares

| Kind | What |
|---|---|
| Command `pick` | Pick Color: closes the panel and shows the system's color sampler. The picked color is copied in the default format, kept in the history, and named in a HUD. Escape changes nothing. Kept out of deep links. |
| Command `history` | Color History: a list of swatches, Pinned first, then by day, with a detail pane. |
| Instant provider `colors` | A typed color, `color` and a CSS name, or `contrast` and two colors. One row at the top. |
| Settings pane | default format, hex case, typed colors on or off, how many colors to keep, Clear History |
| Permission | Accessibility, to paste into the frontmost app |
| Service | `ColorSamplerKey`: `SystemColorSampler` in the app, `SimulatedColorSampler` everywhere else |

Rows use the namespace `colors`. Typed rows are `colors:typed.<components>`, contrast rows `colors:contrast.<components>/<components>`, history rows `colors:history.<uuid>`. Every row is `.never`, so root search keeps nothing of them.

## Typed colors

Root search answers when the whole query is one color:

- hex behind a number sign with 3, 4, 6 or 8 digits: `#639`, `#66339980`
- `rgb`, `rgba`, `hsl`, `hsla`, `hwb` and `oklch`, in the comma form and the space form with `/` before alpha: `rgb(102, 51, 153)`, `hsl(270 50% 40% / 0.5)`, `oklch(44% 0.16 303)`. Angles take `deg`, `rad`, `grad` and `turn`. `none` reads as 0. Values out of range are clamped as CSS clamps them.
- `color` and a CSS name, or any of the above: `color rebeccapurple`. Names alone clash with ordinary words such as tan and orange, so they need the keyword.
- `contrast` and two colors, text first, background second, with optional `on`, `vs`, `and`, `against` or `over` between them: `contrast #767676 on white`. Names work here too.

The provider decides from the first bytes. It refuses any query that does not start with `#`, `rgb(`, `rgba(`, `hsl(`, `hsla(`, `hwb(`, `oklch(`, `color ` or `contrast `, in any case, and reads at most nine bytes to do so. Only then does it read the setting and parse, up to 200 bytes.

Return copies the default format, Command-Return pastes it, Command-L shows it in Large Type, and the action panel copies every other format. A color does not `represent` text, so the host's text actions, such as Define and Translate, stay off it. Copying or pasting a typed color keeps it in the history, as the calculator keeps answers. A contrast row copies the ratio, or the ratio with its verdicts.

## Formats

| Format | Rebecca Purple |
|---|---|
| Hex | `#663399` |
| RGB | `rgb(102 51 153)` |
| HSL | `hsl(270 50% 40%)` |
| HSB | `hsb(270 66.7% 60%)` |
| HWB | `hwb(270 20% 40%)` |
| OKLCH | `oklch(44.03% 0.1603 303.37)` |
| SwiftUI | `Color(red: 0.4, green: 0.2, blue: 0.6)` |
| AppKit | `NSColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 1)` |
| CSS Variable | `--color-663399: #663399;`, or `--brand-purple: #663399;` for a color named Brand Purple |

With alpha below 1, hex gains two digits and the CSS formats gain `/ alpha`. Numbers use a point whatever the region.

## The math

`ColorSpaces` converts with the CSS Color 4 formulas for HSL, HSB and HWB, and Björn Ottosson's published Oklab matrices for OKLCH. Display P3 goes to sRGB through linear light with a matrix derived in exact fractions from both spaces' primaries and D65. Contrast is WCAG 2's relative luminance, and a ratio is cut, never rounded up, to two decimals, so 4.499 reads 4.49 and fails AA. The tests check published values: colorsys for HSL and HSB, Ottosson's values for the primaries, the CSS value of Display P3 red, and WebAIM's ratios.

Colors are kept as extended sRGB, so a color outside sRGB stays as it was picked. Every format shows the nearest sRGB color by clipping each component. The row shows an Outside sRGB tag, and the detail says so and shows the extended components.

## Picking

`SystemColorSampler` shows `NSColorSampler`, which needs no permission: the system draws the magnifier and hands back only the clicked color. sRGB and Display P3 colors are converted by the feature's own tested math. Any other space, such as a display's own profile, is converted to extended sRGB by ColorSync. Tests, scenarios, the self-test and benchmarks get `SimulatedColorSampler`, which shows nothing and returns the colors a test queued, or Rebecca Purple. The system's sampler cannot be cancelled and stays until the user clicks, so a pick whose run was cancelled meanwhile, as when the feature was turned off, copies and keeps nothing.

## History

`history.json` in the feature's data folder, written atomically. The same color picked or copied again moves to the top and keeps its name and pin. Pinned colors never count against the limit and stay through Clear History. A smaller limit asks first. A damaged file is renamed beside itself and a new history starts. A file from a newer version is shown and never written, and the settings pane says so. That holds too when its entries have a shape this version cannot read: the file stays where it is and the history starts empty for the session. Names from the file are put on one line, direction controls show as U+FFFD, and a name that shows nothing is dropped.

| Action | ID | Shortcut |
|---|---|---|
| Copy as the default format | `copy-<format>` | Return |
| Paste as the default format | `paste` | Command-Return |
| Show in Large Type, the value in the default format | `large-type` | Command-L |
| Copy as every other format | `copy-<format>` | |
| Pin Color, or Unpin Color | `pin`, `unpin` | Command-Period |
| Name This Color | `rename` | Command-E |
| Delete Color, after asking | `delete` | Control-X |
| Clear History, after asking | `clear-history` | Control-Shift-X |

Pin, name and delete read the history again when they run, so an action from a stale row changes nothing it no longer shows.

## Benchmark

`COLORS_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Colors test -c release -Xswiftc -enable-testing --filter Benchmark`. On an M5 under load 9: an answer takes 2.6 µs at p99, a keystroke while typing 2.3 µs, a refusal 0.04 µs at p50 with no allocation, and a 100 KB paste that starts like a color 0.3 µs. The history page's rows take 1.8 ms for 1,000 colors and 164 ms for 50,000, off the main thread.
