//! The calculator through the C ABI: every kind of answer, errors, the reject path with a counting
//! allocator, shared zones and rates, and hostile arguments.
//!
//! The moment is Sunday 15 November 2026, 14:30 UTC, in America/New_York, the same fixed context as
//! the slick-calc suite. The rates are made up.

use super::alloc;
use super::*;
use crate::calc::*;
use std::ptr::NonNull;

/// 2026-11-15T14:30:00Z.
const NOW_MS: i64 = 1_794_753_000_000;
const LOCAL_ZONE: &str = "America/New_York";

/// An owned calculator handle.
struct Calc(*mut SlickCalc);

impl Drop for Calc {
    fn drop(&mut self) {
        assert_eq!(slick_calc_free(self.0), OK);
    }
}

/// What one evaluation gave, copied out through the accessors.
#[derive(Debug, PartialEq)]
struct Got {
    kind: u8,
    confidence: u8,
    problem: u8,
    main: String,
    copy: String,
    note: String,
    alternates: Vec<(String, String)>,
}

fn text_of(c: *const SlickCalc, which: u32, index: u32) -> String {
    let n = slick_calc_text(c, which, index, null_mut(), 0);
    assert!(n >= 0, "measure status {n}");
    let mut buf = vec![0u8; n as usize];
    let m = slick_calc_text(c, which, index, buf.as_mut_ptr(), buf.len().max(1));
    assert_eq!(m, n);
    String::from_utf8(buf).expect("UTF-8")
}

impl Calc {
    fn new() -> Calc {
        let mut c = null_mut();
        assert_eq!(slick_calc_new(&mut c), OK);
        Calc(c)
    }

    /// A calculator in the fixed context, with zones and rates attached.
    fn fixed() -> Calc {
        let c = Calc::new();
        c.context(SlickCalcContext {
            local_offset_s: -5 * 3600,
            grouping: ',' as u32,
            ..SlickCalcContext::default()
        });
        let zones = zones();
        assert_eq!(slick_calc_set_zones(c.0, zones), OK);
        assert_eq!(
            slick_calc_zones_free(zones),
            OK,
            "the calculator keeps its own reference"
        );
        let rates = rates();
        assert_eq!(slick_calc_set_rates(c.0, rates), OK);
        assert_eq!(slick_calc_rates_free(rates), OK);
        c
    }

    fn context(&self, ctx: SlickCalcContext) {
        let rc = slick_calc_set_context(self.0, &ctx, LOCAL_ZONE.as_ptr(), LOCAL_ZONE.len(), b"usd".as_ptr(), 3);
        assert_eq!(rc, OK);
    }

    fn eval(&self, q: &str) -> Option<Got> {
        let mut r = SlickCalcResult::default();
        let rc = slick_calc_evaluate(self.0, q.as_ptr(), q.len(), NOW_MS, &mut r);
        assert!(rc == 0 || rc == 1, "status {rc} for {q:?}");
        if rc == 0 {
            assert_eq!(r, SlickCalcResult::default(), "a reject writes a zeroed result");
            return None;
        }
        let got = Got {
            kind: r.kind,
            confidence: r.confidence,
            problem: r.problem,
            main: text_of(self.0, SLICK_CALC_TEXT_MAIN, 0),
            copy: text_of(self.0, SLICK_CALC_TEXT_COPY, 0),
            note: text_of(self.0, SLICK_CALC_TEXT_NOTE, 0),
            alternates: (0..r.alternate_count as u32)
                .map(|i| {
                    (
                        text_of(self.0, SLICK_CALC_TEXT_ALTERNATE_LABEL, i),
                        text_of(self.0, SLICK_CALC_TEXT_ALTERNATE, i),
                    )
                })
                .collect(),
        };
        assert_eq!(
            (r.main_len, r.copy_len, r.note_len),
            (got.main.len() as u32, got.copy.len() as u32, got.note.len() as u32)
        );
        Some(got)
    }

    fn main(&self, q: &str) -> String {
        self.eval(q).unwrap_or_else(|| panic!("{q:?} was rejected")).main
    }
}

fn zones() -> *mut SlickCalcZones {
    let mut z = null_mut();
    let n = slick_calc_zones_load(null(), 0, LOCAL_ZONE.as_ptr(), LOCAL_ZONE.len(), &mut z);
    assert!(n > 200, "the system zoneinfo loads: {n} zones");
    z
}

fn rates() -> *mut SlickCalcRates {
    let mut r = null_mut();
    // 2026-11-15T12:00:00Z. Units per US dollar, made up.
    assert_eq!(slick_calc_rates_new(b"USD".as_ptr(), 3, 1_794_744_000_000, &mut r), OK);
    for (code, rate) in [("EUR", 0.92), ("GBP", 0.80), ("JPY", 155.0), ("CAD", 1.40)] {
        assert_eq!(slick_calc_rates_insert(r, code.as_ptr(), code.len(), rate), 1);
    }
    r
}

#[test]
fn constants_and_layouts_match_the_calculator() {
    use slick_calc::{Kind, Problem};
    assert_eq!(size_of::<SlickCalcContext>(), 24);
    assert_eq!(size_of::<SlickCalcResult>(), 16);
    assert_eq!(SLICK_CALC_CLAIMS_TOP, slick_calc::CLAIMS_TOP);
    assert_eq!(SLICK_CALC_MAX_QUERY_LEN as usize, slick_calc::MAX_QUERY_LEN);
    assert_eq!(SLICK_CALC_MAX_ALTERNATES as usize, slick_calc::MAX_ALTERNATES);
    let kinds = [
        (SLICK_CALC_KIND_NONE, Kind::None),
        (SLICK_CALC_KIND_NUMBER, Kind::Number),
        (SLICK_CALC_KIND_PERCENT, Kind::Percent),
        (SLICK_CALC_KIND_QUANTITY, Kind::Quantity),
        (SLICK_CALC_KIND_DURATION, Kind::Duration),
        (SLICK_CALC_KIND_CURRENCY, Kind::Currency),
        (SLICK_CALC_KIND_DATE, Kind::Date),
        (SLICK_CALC_KIND_TIME, Kind::Time),
        (SLICK_CALC_KIND_TEXT, Kind::Text),
        (SLICK_CALC_KIND_ERROR, Kind::Error),
    ];
    for (c, k) in kinds {
        assert_eq!(c, k as u8);
    }
    let problems = [
        (SLICK_CALC_PROBLEM_NONE, Problem::None),
        (SLICK_CALC_PROBLEM_DIVISION_BY_ZERO, Problem::DivisionByZero),
        (SLICK_CALC_PROBLEM_OVERFLOW, Problem::Overflow),
        (SLICK_CALC_PROBLEM_UNDEFINED, Problem::Undefined),
        (SLICK_CALC_PROBLEM_NOT_REAL, Problem::NotReal),
        (SLICK_CALC_PROBLEM_NOT_WHOLE, Problem::NotWhole),
        (SLICK_CALC_PROBLEM_INCOMPATIBLE_UNITS, Problem::IncompatibleUnits),
        (SLICK_CALC_PROBLEM_NO_RATES, Problem::NoRates),
        (SLICK_CALC_PROBLEM_NO_RATE, Problem::NoRate),
        (SLICK_CALC_PROBLEM_NO_TIME_ZONES, Problem::NoTimeZones),
        (SLICK_CALC_PROBLEM_UNKNOWN_ZONE, Problem::UnknownZone),
        (SLICK_CALC_PROBLEM_INVALID_DATE, Problem::InvalidDate),
        (SLICK_CALC_PROBLEM_UNSUPPORTED, Problem::Unsupported),
    ];
    for (c, p) in problems {
        assert_eq!(c, p as u8);
    }
}

#[test]
fn every_kind_of_answer_comes_through() {
    assert_eq!(slick_calc_prepare(), OK);
    let c = Calc::fixed();
    let cases: [(&str, u8, &str); 9] = [
        ("2 + 2", SLICK_CALC_KIND_NUMBER, "4"),
        ("30 is what % of 120", SLICK_CALC_KIND_PERCENT, "25%"),
        ("10 kg in lbs", SLICK_CALC_KIND_QUANTITY, "22.0462 lb"),
        ("2h 30m + 45m", SLICK_CALC_KIND_DURATION, "3 h 15 min"),
        ("100 usd in eur", SLICK_CALC_KIND_CURRENCY, "92 EUR"),
        ("today + 3 weeks", SLICK_CALC_KIND_DATE, "Sunday, 6 December 2026"),
        ("time in tokyo", SLICK_CALC_KIND_TIME, "11:30 PM, Sun 15 Nov"),
        (
            "1234 in words",
            SLICK_CALC_KIND_TEXT,
            "one thousand two hundred thirty-four",
        ),
        ("1/0", SLICK_CALC_KIND_ERROR, "Division by zero"),
    ];
    for (q, kind, main) in cases {
        let got = c.eval(q).unwrap_or_else(|| panic!("{q:?} was rejected"));
        assert_eq!((got.kind, got.main.as_str()), (kind, main), "{q:?}: {got:?}");
        assert!((1..=100).contains(&got.confidence), "{q:?}: {got:?}");
        let error = kind == SLICK_CALC_KIND_ERROR;
        assert_eq!(got.problem != SLICK_CALC_PROBLEM_NONE, error, "{q:?}: {got:?}");
    }
    let tip = c.eval("15% tip on $80").expect("an answer");
    assert!(tip.confidence >= SLICK_CALC_CLAIMS_TOP, "{tip:?}");
    let money = c.eval("100 usd in eur").expect("an answer");
    assert_eq!(money.copy, "92");
    assert!(money.note.contains("Rates"), "{money:?}");
    let hex = c.eval("0xff").expect("an answer");
    assert!(!hex.alternates.is_empty(), "{hex:?}");
    assert!(hex.alternates.iter().all(|(l, t)| !l.is_empty() && !t.is_empty()));
    let date = c.eval("tomorrow 3pm").expect("an answer");
    assert_eq!(date.copy, "3:00 PM");
}

#[test]
fn errors_name_their_problem() {
    let c = Calc::fixed();
    let cases = [
        ("1/0", SLICK_CALC_PROBLEM_DIVISION_BY_ZERO),
        ("5 km in kg", SLICK_CALC_PROBLEM_INCOMPATIBLE_UNITS),
        ("sqrt(-1)", SLICK_CALC_PROBLEM_NOT_REAL),
    ];
    for (q, problem) in cases {
        let got = c.eval(q).unwrap_or_else(|| panic!("{q:?} was rejected"));
        assert_eq!(
            (got.kind, got.problem),
            (SLICK_CALC_KIND_ERROR, problem),
            "{q:?}: {got:?}"
        );
        assert!(!got.main.is_empty());
    }
    // Without rates or zones the calculator says so; it never guesses.
    assert_eq!(slick_calc_set_rates(c.0, null()), OK);
    assert_eq!(slick_calc_set_zones(c.0, null()), OK);
    let no_rates = c.eval("100 usd in eur").expect("an error");
    assert_eq!(no_rates.problem, SLICK_CALC_PROBLEM_NO_RATES);
    assert_eq!(no_rates.main, "Exchange rates are not loaded");
    let no_zones = c.eval("time in tokyo").expect("an error");
    assert_eq!(no_zones.problem, SLICK_CALC_PROBLEM_NO_TIME_ZONES);
    assert_eq!(
        c.main("9am pst to cet"),
        "6:00 PM, Sun 15 Nov",
        "fixed abbreviations need no zones"
    );
    // A rate the table lacks.
    let r = rates();
    assert_eq!(slick_calc_set_rates(c.0, r), OK);
    let no_rate = c.eval("100 chf in eur").expect("an error");
    assert_eq!(no_rate.problem, SLICK_CALC_PROBLEM_NO_RATE, "{no_rate:?}");
    // An insert after attaching does not reach the calculator.
    assert_eq!(slick_calc_rates_insert(r, b"chf".as_ptr(), 3, 0.88), 1);
    assert_eq!(
        c.eval("100 chf in eur").expect("an error").problem,
        SLICK_CALC_PROBLEM_NO_RATE
    );
    assert_eq!(slick_calc_set_rates(c.0, r), OK);
    assert_eq!(
        c.eval("100 chf in eur").expect("an answer").kind,
        SLICK_CALC_KIND_CURRENCY
    );
    assert_eq!(slick_calc_rates_count(r), 6, "USD, the four inserted and CHF");
    assert_eq!(slick_calc_rates_free(r), OK);
}

#[test]
fn the_context_changes_formats() {
    let c = Calc::fixed();
    c.context(SlickCalcContext {
        decimal: ',' as u32,
        grouping: '.' as u32,
        ..SlickCalcContext::default()
    });
    assert_eq!(c.main("0,1 + 0,2"), "0,3");
    assert_eq!(c.main("1.000.000 / 4"), "250.000");
    c.context(SlickCalcContext {
        hour_cycle: SLICK_CALC_HOURS_24,
        date_order: SLICK_CALC_DATE_MONTH_DAY_YEAR,
        ..SlickCalcContext::default()
    });
    assert_eq!(c.main("time in tokyo"), "23:30, Sun Nov 15");
    assert_eq!(c.main("today"), "Sunday, November 15, 2026");
    c.context(SlickCalcContext {
        angle: SLICK_CALC_ANGLE_DEGREES,
        ..SlickCalcContext::default()
    });
    assert_eq!(c.main("sin(30)"), "0.5");
    // The dollar setting: a bare "$" is Canadian dollars.
    let ctx = SlickCalcContext::default();
    assert_eq!(slick_calc_set_context(c.0, &ctx, null(), 0, b"cad".as_ptr(), 3), OK);
    assert_eq!(c.main("$140 in usd"), "100 USD");
}

#[test]
fn the_reject_path_allocates_nothing() {
    let c = Calc::fixed();
    let rejects = [
        "safari",
        "Visual Studio Code",
        "terminal",
        "1password",
        "notes 2024",
        "iphone 15 pro",
        "42",
        "",
        "   ",
        "time machine backup",
        "hello world",
    ];
    for q in rejects {
        assert_eq!(c.eval(q), None, "{q:?}");
    }
    let long = "1+".repeat(400);
    let mut r = SlickCalcResult::default();
    let n = alloc::on_this_thread(|| {
        for _ in 0..200 {
            for q in rejects {
                let rc = slick_calc_evaluate(c.0, q.as_ptr(), q.len(), NOW_MS, &mut r);
                assert_eq!(rc, 0);
            }
            let rc = slick_calc_evaluate(c.0, long.as_ptr(), long.len(), NOW_MS, &mut r);
            assert_eq!(rc, 0, "past the length limit");
            assert_eq!(slick_calc_text(c.0, SLICK_CALC_TEXT_MAIN, 0, null_mut(), 0), 0);
        }
    });
    assert_eq!(n, 0, "{n} allocations on the reject path");
    // A warm simple answer allocates nothing either: the answer's strings keep their capacity.
    let q = "12 * 7";
    for _ in 0..3 {
        assert_eq!(slick_calc_evaluate(c.0, q.as_ptr(), q.len(), NOW_MS, &mut r), 1);
    }
    let mut buf = [0u8; 64];
    let n = alloc::on_this_thread(|| {
        for _ in 0..200 {
            assert_eq!(slick_calc_evaluate(c.0, q.as_ptr(), q.len(), NOW_MS, &mut r), 1);
            let len = slick_calc_text(c.0, SLICK_CALC_TEXT_MAIN, 0, buf.as_mut_ptr(), buf.len());
            assert_eq!(&buf[..len as usize], b"84");
        }
    });
    assert_eq!(n, 0, "{n} allocations for a warm simple answer");
}

#[test]
fn zones_and_rates_are_shared_and_outlive_their_handles() {
    let z = zones();
    let r = rates();
    let a = Calc::fixed();
    let b = Calc::new();
    for c in [&a, &b] {
        assert_eq!(slick_calc_set_zones(c.0, z), OK);
        assert_eq!(slick_calc_set_rates(c.0, r), OK);
    }
    assert_eq!(slick_calc_zones_free(z), OK);
    assert_eq!(slick_calc_rates_free(r), OK);
    std::thread::scope(|s| {
        for c in [&a, &b] {
            let p = c.0 as usize;
            s.spawn(move || {
                // Each calculator belongs to one thread at a time; the shared data is immutable.
                let c = p as *mut SlickCalc;
                for _ in 0..200 {
                    let mut r = SlickCalcResult::default();
                    let q = "50 euros in yen";
                    assert_eq!(slick_calc_evaluate(c, q.as_ptr(), q.len(), NOW_MS, &mut r), 1);
                    assert_eq!(r.kind, SLICK_CALC_KIND_CURRENCY);
                    let q = "time in london";
                    assert_eq!(slick_calc_evaluate(c, q.as_ptr(), q.len(), NOW_MS, &mut r), 1);
                    assert_eq!(r.kind, SLICK_CALC_KIND_TIME);
                }
            });
        }
    });
    assert_eq!(a.main("50 euros in yen"), "8,424 JPY");
    assert_eq!(b.main("time in london"), "2:30 PM, Sun 15 Nov");
}

#[test]
fn hostile_arguments_come_back_as_statuses() {
    const BAD: i32 = SlickStatus::InvalidArgument as i32;
    const NULL: i32 = SlickStatus::NullPointer as i32;
    const UTF8: i32 = SlickStatus::InvalidUtf8 as i32;
    const SMALL: i32 = SlickStatus::BufferTooSmall as i32;
    let c = Calc::fixed();
    let dangling = NonNull::<u8>::dangling().as_ptr();
    let mut r = SlickCalcResult {
        kind: 9,
        ..SlickCalcResult::default()
    };
    // NULL handles and output slots.
    assert_eq!(slick_calc_new(null_mut()), NULL);
    assert_eq!(
        slick_calc_evaluate(null_mut(), b"1+1".as_ptr(), 3, NOW_MS, &mut r),
        NULL
    );
    assert_eq!(slick_calc_evaluate(c.0, b"1+1".as_ptr(), 3, NOW_MS, null_mut()), NULL);
    assert_eq!(slick_calc_text(null(), 0, 0, null_mut(), 0), NULL);
    assert_eq!(slick_calc_set_zones(null_mut(), null()), NULL);
    assert_eq!(slick_calc_set_rates(null_mut(), null()), NULL);
    assert_eq!(slick_calc_rates_insert(null_mut(), b"EUR".as_ptr(), 3, 1.0), NULL);
    assert_eq!(slick_calc_rates_count(null()), NULL);
    assert_eq!(slick_calc_zones_load(null(), 0, null(), 0, null_mut()), NULL);
    assert_eq!(slick_calc_rates_new(b"USD".as_ptr(), 3, 0, null_mut()), NULL);
    for free in [
        slick_calc_free(null_mut()),
        slick_calc_zones_free(null_mut()),
        slick_calc_rates_free(null_mut()),
    ] {
        assert_eq!(free, OK);
    }
    // Queries: NULL with a length, invalid UTF-8, lengths no buffer has. Each leaves no answer.
    assert_eq!(c.main("2 + 2"), "4");
    assert_eq!(slick_calc_evaluate(c.0, null(), 3, NOW_MS, &mut r), NULL);
    assert_eq!(r, SlickCalcResult::default(), "a refused call zeroes the result");
    assert_eq!(text_of(c.0, SLICK_CALC_TEXT_MAIN, 0), "", "and leaves no answer behind");
    assert_eq!(slick_calc_evaluate(c.0, b"1+\xff".as_ptr(), 3, NOW_MS, &mut r), UTF8);
    assert_eq!(slick_calc_evaluate(c.0, dangling, usize::MAX, NOW_MS, &mut r), BAD);
    assert_eq!(slick_calc_evaluate(c.0, dangling, 0, NOW_MS, &mut r), 0, "empty");
    for now in [i64::MIN, i64::MAX, 0, -1] {
        for q in [
            "now",
            "today + 3 weeks",
            "time in tokyo",
            "now in unix",
            "days until christmas",
        ] {
            let rc = slick_calc_evaluate(c.0, q.as_ptr(), q.len(), now, &mut r);
            assert!(rc == 0 || rc == 1, "{q:?} at {now}: {rc}");
        }
    }
    // Text accessors: unknown which, missing alternates, short buffers, measuring.
    assert_eq!(c.main("0xff"), "255");
    assert_eq!(slick_calc_text(c.0, 99, 0, null_mut(), 0), BAD);
    assert_eq!(slick_calc_text(c.0, SLICK_CALC_TEXT_ALTERNATE, 99, null_mut(), 0), BAD);
    assert_eq!(
        slick_calc_text(c.0, SLICK_CALC_TEXT_ALTERNATE_LABEL, u32::MAX, null_mut(), 0),
        BAD
    );
    let mut one = [0u8; 1];
    assert_eq!(
        slick_calc_text(c.0, SLICK_CALC_TEXT_MAIN, 0, one.as_mut_ptr(), 1),
        SMALL
    );
    assert_eq!(slick_calc_text(c.0, SLICK_CALC_TEXT_MAIN, 0, null_mut(), 3), NULL);
    assert_eq!(
        slick_calc_text(c.0, SLICK_CALC_TEXT_MAIN, 0, null_mut(), 0),
        3,
        "cap 0 measures"
    );
    assert_eq!(slick_calc_text(c.0, SLICK_CALC_TEXT_MAIN, 0, dangling, usize::MAX), BAD);
    // Contexts that make no sense are refused and change nothing.
    let refused = [
        SlickCalcContext {
            date_order: 3,
            ..SlickCalcContext::default()
        },
        SlickCalcContext {
            hour_cycle: 2,
            ..SlickCalcContext::default()
        },
        SlickCalcContext {
            angle: 7,
            ..SlickCalcContext::default()
        },
        SlickCalcContext {
            decimal: 0xD800,
            ..SlickCalcContext::default()
        },
        SlickCalcContext {
            grouping: 0x11_0000,
            ..SlickCalcContext::default()
        },
        SlickCalcContext {
            decimal: ',' as u32,
            grouping: ',' as u32,
            ..SlickCalcContext::default()
        },
    ];
    for ctx in refused {
        assert_eq!(slick_calc_set_context(c.0, &ctx, null(), 0, null(), 0), BAD, "{ctx:?}");
    }
    let ok = SlickCalcContext::default();
    assert_eq!(slick_calc_set_context(c.0, null(), null(), 0, null(), 0), NULL);
    assert_eq!(slick_calc_set_context(c.0, &ok, null(), 0, b"dollars".as_ptr(), 7), BAD);
    assert_eq!(slick_calc_set_context(c.0, &ok, null(), 0, b"u$d".as_ptr(), 3), BAD);
    assert_eq!(slick_calc_set_context(c.0, &ok, b"\xff".as_ptr(), 1, null(), 0), UTF8);
    assert_eq!(c.main("1.5 + 1"), "2.5", "the old context stands");
    let extreme = SlickCalcContext {
        local_offset_s: i32::MIN,
        ..SlickCalcContext::default()
    };
    assert_eq!(
        slick_calc_set_context(c.0, &extreme, b"Not/AZone".as_ptr(), 9, null(), 0),
        OK
    );
    assert!(
        c.eval("now").is_some(),
        "an unknown local zone falls back to the offset"
    );
    // Rates and zones with bad input.
    let mut rates = null_mut();
    assert_eq!(slick_calc_rates_new(b"X".as_ptr(), 1, 0, &mut rates), BAD);
    assert_eq!(slick_calc_rates_new(b"\xff".as_ptr(), 1, 0, &mut rates), UTF8);
    assert_eq!(slick_calc_rates_new(b"eur".as_ptr(), 3, i64::MIN, &mut rates), OK);
    for (code, rate) in [
        ("USD", f64::NAN),
        ("USD", f64::INFINITY),
        ("USD", -1.0),
        ("USD", 0.0),
        ("X1Z", 1.0),
        ("TOOLONG", 1.0),
    ] {
        assert_eq!(
            slick_calc_rates_insert(rates, code.as_ptr(), code.len(), rate),
            0,
            "{code} {rate}"
        );
    }
    assert_eq!(slick_calc_rates_insert(rates, b"\xff".as_ptr(), 1, 1.0), UTF8);
    assert_eq!(slick_calc_rates_count(rates), 1);
    assert_eq!(slick_calc_rates_free(rates), OK);
    let mut z = null_mut();
    let missing = b"/nonexistent-zoneinfo";
    assert_eq!(
        slick_calc_zones_load(missing.as_ptr(), missing.len(), null(), 0, &mut z),
        0
    );
    assert_eq!(slick_calc_set_zones(c.0, z), OK);
    assert_eq!(
        c.eval("time in tokyo").expect("an error").problem,
        SLICK_CALC_PROBLEM_UNKNOWN_ZONE
    );
    assert_eq!(slick_calc_zones_free(z), OK);
    let mut z2 = null_mut();
    assert_eq!(slick_calc_zones_load(null(), 0, b"\xff".as_ptr(), 1, &mut z2), UTF8);
    assert!(z2.is_null(), "nothing is stored on a refusal");
}
