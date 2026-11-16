# Calculator

Answers math in root search as you type: arithmetic, percentages, units, currencies, dates, durations and time zones. Answers you copy or paste are kept in a history. Exchange rates come from the European Central Bank.

The engine is the Rust crate `slick-calc`, reached through CoreBridge's `Calculator`, `CalculatorTimeZones` and `CurrencyRates`. The module is `Calc` because CoreBridge has a type named `Calculator`.

## What it declares

| Kind | What |
|---|---|
| Instant provider `calculator` | One row per query. The answer is the title; how the engine read the question, with its note, is the subtitle, such as "Currency · Rates from 13 Nov 2026". Confident answers claim the top; others show in a Calculator section. Tab puts the engine's copy value in the field. Rows are `memory: .never` |
| Command `history` | Calculator History: saved answers by day, newest first |
| Settings pane | decimal places, digit grouping, decimal separator, dates, times, angles, what "$" means, history on or off, its size, Clear History, exchange rates on or off |
| Permission | Accessibility, to paste an answer into the frontmost app |

Rows use the namespace `calculator`. An answer's key is the trimmed question. A history row's key is `history.<uuid>`.

## Actions

| Row | Action | ID | Shortcut |
|---|---|---|---|
| Answer | Copy Answer, as shown | `copy` | Return |
| Answer | Paste Answer | `paste` | Command-Return |
| Answer | Copy as Plain Number: no grouping, no unit | `copy-plain-number` | Option-Command-C |
| Answer | Copy Question and Answer, as `question = answer` | `copy-question-and-answer` | Option-Shift-Command-C |
| Answer | Show in Large Type, the answer as shown | `large-type` | Command-L |
| Answer | Copy each other form, such as Hex or Fraction | `copy-form-<n>` | |
| Answer that used rates, while downloads are on | Refresh Exchange Rates | `refresh-rates` | Command-R |
| Answer | Open Calculator History | `run.cmd:calculator.history` | |
| No rates yet | Show Answer, Try Again, or Turn On Exchange Rates | `show-answer`, `try-again`, `turn-on-rates` | Return |
| History | Copy Answer, Use Again, Paste Answer, Copy as Plain Number, Copy Question and Answer | `copy`, `use-again`, `paste`, ... | Return, Command-Return |
| History | Delete Answer, Clear History, each after a question | `delete`, `clear-history` | Control-X, Control-Shift-X |

Copying and pasting from root search records the answer in the history, unless history is off. Choosing a smaller history size asks first, because it deletes the oldest answers at once. A history file written by a newer version is shown but never saved over, and settings says so.

Digits typed in full width or in another script, such as `１２ * ３` or `١٢+٣`, are read as ASCII digits before the engine sees them.

## Exchange rates

`ExchangeRateServiceKey` names the rate service. The live `ReferenceRates` sends one GET to `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` through Kit's HTTP service, checks the table and saves it as `rates.json` in the feature's data folder. The isolated `SampleRates` returns made-up rates and sends nothing.

`RateKeeper` decides when. Nothing is downloaded at launch. The first download starts when a currency conversion is typed; the next no sooner than a day after the last success, or half an hour after a failure. Return on the waiting row downloads at once, and Refresh Exchange Rates downloads again whatever the table's age. Both read the setting when they run, so a row made before the user turned downloads off sends nothing. The setting turns downloads off. The saved table is read at activation, so conversions work offline and show the day of their rates.

## Where to look

| File | Holds |
|---|---|
| `CalculatorFeature.swift` | the feature: manifest, command, provider, pane, activation |
| `Engine/` | the one `Calculator`, the context from the region and settings, the region service |
| `Answer/` | the provider, rows, rounding and actions |
| `History/` | the history file and its page |
| `Rates/` | the rate table, the bank's XML, the rate service and when it runs |
| `CalcStrings.swift` | every string a person reads |
| `Tests/CalcTests/Benchmark.swift` | the budgets; run with `CALC_BENCHMARK=1` in release |
