# slick-calc

The calculator behind root search. It answers arithmetic, percentages, number bases, units,
currency, dates, durations and time zones, and it says fast when a query is not math.

It is a pure Rust library with no dependencies. It does no I/O while it evaluates and never
panics. The C ABI for it belongs in `slick-ffi/src/calc.rs` and is not written yet.

## What it answers

| Area | Examples |
|---|---|
| Arithmetic | `2+2`, `2^3^2`, `-2^2`, `5!`, `10 mod 3`, `2(3+4)`, `2pi`, `1e3 + 1`, `0.1 + 0.2` |
| Words | `5 times 3`, `10 divided by 4`, `2 to the power of 10`, `square root of 625`, `10 squared` |
| Functions | `sqrt`, `cbrt`, `abs`, `round(x, places)`, `floor`, `ceil`, `trunc`, `min`, `max`, `sum`, `avg`, `log`, `log(x, base)`, `log2`, `ln`, `exp`, `sin`, `cos`, `tan` and their inverses, `sinh`, `cosh`, `tanh`, `sind`, `gcd`, `lcm` |
| Constants | `pi`, `π`, `e`, `tau`, `phi` |
| Percentages | `20% of 50`, `50 + 10%`, `15% off 80`, `15% on 80`, `30 is what % of 120`, `% change from 40 to 50`, `50 is 20% of what`, `30 out of 120` |
| Bases and forms | `0xff`, `0b1010`, `0o17`, `255 in hex`, `100 in base 7`, `1234 in words`, `1.75 as fraction`, `7/4 as mixed`, `1234567 in scientific` |
| Units | length, mass, volume, cooking, area, temperature, speed, data in decimal and binary prefixes, energy, power, pressure, angle, frequency, force, fuel economy, time. SI prefixes, plurals, symbols, compound input such as `5 ft 11 in in cm` and `2h 30m + 45m`, arithmetic such as `2 km + 500 m` and `100 km / 2 h` |
| Currency | `100 usd in eur`, `$20 to gbp`, `50 euros in yen`, `C$20 in usd`, `$1.5k in eur`. Codes, symbols and common names. Needs a rate table |
| Dates | `today + 3 weeks`, `next friday`, `35 days ago`, `in 3 days`, `days until christmas`, `days between jan 1 and mar 1`, `weekday of 2026-12-25`, `easter 2027` |
| Times | `time in tokyo`, `3pm london in tokyo`, `9am pst to cet`, `time difference tokyo`, `8am to 4pm`, `time until 5pm` |
| Unix time | `unix 1700000000`, `1700000000 to date`, `now in unix`, `2026-12-25 in unix` |

`tests/cases.txt` lists more than 600 queries with the exact answer each one gives.

## The API

```rust
use slick_calc::{evaluate, prepare, Answer, Context, Kind, Rates, ZoneDb, CLAIMS_TOP};

// Once, off the main thread, at launch.
prepare();
let zones = ZoneDb::load_system(&["Europe/Paris"]);      // reads /usr/share/zoneinfo
let mut rates = Rates::new("USD", fetched_at_ms).unwrap();
rates.insert("EUR", 0.92);

// Per keystroke, on the main thread.
let mut ctx = Context::new(now_ms);
ctx.local_zone = "Europe/Paris";
ctx.local_offset_s = 3600;
ctx.decimal = ',';
ctx.grouping = Some('\u{202f}');
ctx.zones = Some(&zones);
ctx.rates = Some(&rates);

let mut answer = Answer::new();                // reuse across keystrokes
if evaluate(query, &ctx, &mut answer) {
    let claims_top = answer.confidence >= CLAIMS_TOP;
    // answer.kind, answer.main, answer.copy, answer.note, answer.alternates()
}
```

### `evaluate(query, context, answer) -> bool`

- Returns false when the query is not a calculation. Then `answer.kind` is `Kind::None` and
  nothing was allocated. A test with a counting allocator holds this.
- Returns true with an answer, or with `Kind::Error` when the query is clearly a calculation
  that has no answer. `answer.problem` says why and `answer.main` says it in words.
- Never panics and never reads a file. After `prepare()` it never waits on a lock. Queries longer
  than `MAX_QUERY_LEN`, which is 256 bytes, are rejected. Expression nesting is bounded.

### The answer

| Field | Meaning |
|---|---|
| `kind` | `Number`, `Percent`, `Quantity`, `Duration`, `Currency`, `Date`, `Time`, `Text`, `Error` |
| `confidence` | 1 to 100. At `CLAIMS_TOP`, which is 80, or more the answer should claim the top of the list. Below it, show the answer in its own section or not at all |
| `main` | The formatted answer: `3.10686 mi`, `92 EUR`, `11:30 PM, Sun 15 Nov` |
| `copy` | The value to copy: no grouping, no unit, the caller's decimal separator. Dates are ISO 8601, times are the clock time, text is the text |
| `note` | Context such as `Rates from 15 Nov 2026` or `Tokyo, JST, UTC+9`. Often empty |
| `alternates()` | Up to four other forms, each with a short label: `Hex`, `Binary`, `Fraction`, `Exact`, `Metric`, `Imperial`, `Rate`, `Local`, `UTC`, `ISO 8601`, `Duration`, `Weeks` |
| `problem` | Why an `Error` answer has no value |

Confidence comes from what the parser saw. An explicit operator, function or conversion gives
90 to 95. A phrase such as `days until christmas` gives 85 to 90. A bare quantity such as `5 km`
gives 60, and a glued one-letter unit such as `3m` gives 30. A number alone, a percentage alone
and most single words are rejected.

### The context

The engine has no locale logic. The caller passes everything:

| Field | Meaning |
|---|---|
| `now_ms` | The current instant, Unix milliseconds |
| `local_zone`, `local_offset_s` | The local IANA zone and its offset now. The offset is the fallback when the zone database lacks the zone |
| `decimal`, `grouping` | Separators for input and output. With a decimal comma, `;` separates function arguments, and `,` does too when a space follows it |
| `date_order`, `hour_cycle` | How dates and times are written |
| `angle` | The unit of `sin(30)` and of `asin(0.5)` |
| `dollar` | The currency a bare `$` or "dollars" means. Default `USD` |
| `rates` | Exchange rates, or none. Without rates a currency conversion answers that rates are not loaded. It never guesses |
| `zones` | Time zone rules, or none. Fixed abbreviations such as PST work without them |

### Built once, off the main thread

- `prepare()` builds the lookup tables, about 0.7 ms. Without it the first query pays.
- `ZoneDb::load_system(extra)` reads every zone the engine names, 258 files, plus `extra`, such as
  the local zone. It took 3.6 to 4.1 ms with the files cached and 22 to 24 ms on a first read on
  the development Mac.
- `Rates::new(base, timestamp_ms)` and `Rates::insert(code, units_per_base)` build a rate table
  from whatever source the app uses.

## Wrapping it in C

The API was shaped for `slick-ffi`:

- One opaque handle owns an `Answer` and a `Context` copy. `slick_calc_evaluate(handle, query
  ptr, len)` returns a status, the kind and the confidence. On a reject it writes three integers
  and nothing else.
- Accessors copy `main`, `copy`, `note` and each alternate's label and text into caller buffers,
  returning the byte length or a too-small status. The strings are UTF-8 without a NUL.
- `ZoneDb` and `Rates` become opaque handles built on a background thread and attached to the
  calculator handle. They are immutable after that, so a reader never waits.

## Time zone data

The engine reads the system's compiled zoneinfo instead of bundling a database crate.

- **Size.** No zone data in the binary. A bundled database adds roughly 100 KB to 1 MB
  depending on the crate, before its date library.
- **Correctness.** macOS updates `/usr/share/zoneinfo` with the system and with its separate
  time zone data updates, which follow the IANA releases. A bundled copy is frozen at build time
  and goes stale with the next rule change somewhere in the world. The system copy also matches
  what the Clock app and Calendar show.
- **Offline.** Both work offline.
- **Cost.** A TZif and POSIX TZ parser of about 470 lines, tested here, and a few milliseconds of
  file reads at launch, off the main thread. Dates past the last transition in a file follow the
  POSIX rule in its footer.

Abbreviations that name standard or daylight time are fixed offsets: `9am pst` is UTC-8 even in
July. Region names follow the region's rules: `pt`, `pacific`, `et`, `eastern`. Where an
abbreviation is ambiguous the common English reading wins: CST is US Central, IST is India.

## Places

`src/data/places.txt` maps 827 places, under 990 names, to 258 IANA zones: every national capital, about 350 of the
largest cities, every country, some states and provinces, and aliases such as Saigon, Bombay and
NYC. Names match without case, diacritics, dots, apostrophes or hyphens. When two places share a
name the larger keeps it: `san jose` is California and `san jose costa rica` is Costa Rica.

## Numbers

A number is an exact fraction of two `i128` values while the arithmetic allows it, and an `f64`
after that. Decimal literals are exact, so `0.1 + 0.2` is `0.3` and `1/3 * 3` is `1`.
Transcendental functions return floats. Display rounds arithmetic to 12 significant digits and
unit conversions to 6, keeps exact short values whole, never rounds away integer digits below
10^15, and switches to scientific notation past 21 integer digits, with the exact integer as an
alternate.

## Dependencies

None. The calculator adds about 330 KB to a stripped release binary with fat LTO at opt-level 3,
measured as the difference between two probe binaries that use the same parts of std. About
24 KB of that is the place table. At `opt-level = "s"` for this crate it is about 250 KB.

## Latency

Thread CPU time in a release build, 15 November 2026, Apple M5, load average 5.6.

| Path | Performance cores p50, p99 | Efficiency cores p50, p99 | Budget |
|---|---|---|---|
| Reject a word or app name | 0.013 µs, 0.51 µs | 0.023 µs, 1.17 µs | p50 under 1 µs |
| Reject words with digits | 0.11 µs, 0.79 µs | 0.25 µs, 1.85 µs | p50 under 1 µs |
| Simple arithmetic | 0.33 µs, 1.04 µs | 1.04 µs, 5.6 µs | p99 under 100 µs |
| Every accepted case in the suite | 0.83 µs, 2.9 µs | 2.3 µs, 11 µs | p99 under 100 µs |
| Slowest case, `180 cm in feet and inches` | 5.8 µs, 6.3 µs | 12 µs, 32 µs | p99 under 100 µs |

## Tests and benchmark

```
scripts/cargo.sh test -p slick-calc            # unit tests, expectations, fuzz, allocation, zones
CALC_DUMP=1 scripts/cargo.sh test -p slick-calc --test expectations -- --nocapture
scripts/cargo.sh bench -p slick-calc           # BENCH_QOS=background for the efficiency cores
```

Use your own `CARGO_TARGET_DIR` when other people build the workspace.

The library forbids unsafe code. The allocation test and the benchmark each contain a small
unsafe block: a counting global allocator, and the Darwin CPU clock and QoS calls.
