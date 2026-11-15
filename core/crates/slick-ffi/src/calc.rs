//! C ABI for the calculator: the `slick_calc_*` functions over `slick-calc`.
//!
//! A calculator handle owns one answer and the context it evaluates in. It belongs to one thread
//! at a time. Time zone data and exchange rates are separate, immutable handles. Build them off
//! the main thread, then attach them to a calculator. One zones or rates handle can be attached to
//! many calculators, and it may be freed while attached: the calculator keeps its own reference.
//!
//! Per keystroke the caller makes one `slick_calc_evaluate` call. A query that is not math comes
//! back as 0 with a zeroed result and allocates nothing. An answer comes back as 1 with its kind,
//! confidence and the byte length of each text, which `slick_calc_text` then copies into caller
//! buffers.

use crate::args::{bytes, handle, handle_mut, out, text};
use crate::status::{SlickStatus, guard, guard_result};
use slick_calc::{AngleUnit, Answer, Context, DateOrder, HourCycle, Rates, ZoneDb};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::Arc;

/// `SlickCalcResult.kind`: not a calculation.
pub const SLICK_CALC_KIND_NONE: u8 = 0;
/// `SlickCalcResult.kind`: a plain number.
pub const SLICK_CALC_KIND_NUMBER: u8 = 1;
/// `SlickCalcResult.kind`: a percentage.
pub const SLICK_CALC_KIND_PERCENT: u8 = 2;
/// `SlickCalcResult.kind`: a number with a unit.
pub const SLICK_CALC_KIND_QUANTITY: u8 = 3;
/// `SlickCalcResult.kind`: a length of time.
pub const SLICK_CALC_KIND_DURATION: u8 = 4;
/// `SlickCalcResult.kind`: an amount of money.
pub const SLICK_CALC_KIND_CURRENCY: u8 = 5;
/// `SlickCalcResult.kind`: a date.
pub const SLICK_CALC_KIND_DATE: u8 = 6;
/// `SlickCalcResult.kind`: a moment or a time of day.
pub const SLICK_CALC_KIND_TIME: u8 = 7;
/// `SlickCalcResult.kind`: text, such as a number in words.
pub const SLICK_CALC_KIND_TEXT: u8 = 8;
/// `SlickCalcResult.kind`: a calculation without an answer. `problem` says why.
pub const SLICK_CALC_KIND_ERROR: u8 = 9;

/// `SlickCalcResult.problem`: no problem.
pub const SLICK_CALC_PROBLEM_NONE: u8 = 0;
/// `SlickCalcResult.problem`: division by zero.
pub const SLICK_CALC_PROBLEM_DIVISION_BY_ZERO: u8 = 1;
/// `SlickCalcResult.problem`: the number is too large.
pub const SLICK_CALC_PROBLEM_OVERFLOW: u8 = 2;
/// `SlickCalcResult.problem`: the result is undefined.
pub const SLICK_CALC_PROBLEM_UNDEFINED: u8 = 3;
/// `SlickCalcResult.problem`: the result is not a real number.
pub const SLICK_CALC_PROBLEM_NOT_REAL: u8 = 4;
/// `SlickCalcResult.problem`: the operation needs a whole number.
pub const SLICK_CALC_PROBLEM_NOT_WHOLE: u8 = 5;
/// `SlickCalcResult.problem`: the units do not convert into each other.
pub const SLICK_CALC_PROBLEM_INCOMPATIBLE_UNITS: u8 = 6;
/// `SlickCalcResult.problem`: no exchange rates are attached.
pub const SLICK_CALC_PROBLEM_NO_RATES: u8 = 7;
/// `SlickCalcResult.problem`: the rates lack this currency.
pub const SLICK_CALC_PROBLEM_NO_RATE: u8 = 8;
/// `SlickCalcResult.problem`: no time zone data is attached.
pub const SLICK_CALC_PROBLEM_NO_TIME_ZONES: u8 = 9;
/// `SlickCalcResult.problem`: the zone data lacks this zone.
pub const SLICK_CALC_PROBLEM_UNKNOWN_ZONE: u8 = 10;
/// `SlickCalcResult.problem`: not a valid date.
pub const SLICK_CALC_PROBLEM_INVALID_DATE: u8 = 11;
/// `SlickCalcResult.problem`: the calculator cannot do this.
pub const SLICK_CALC_PROBLEM_UNSUPPORTED: u8 = 12;

/// `slick_calc_text` which: the formatted answer.
pub const SLICK_CALC_TEXT_MAIN: u32 = 0;
/// `slick_calc_text` which: the value to copy.
pub const SLICK_CALC_TEXT_COPY: u32 = 1;
/// `slick_calc_text` which: the note, such as the rate date. Often empty.
pub const SLICK_CALC_TEXT_NOTE: u32 = 2;
/// `slick_calc_text` which: the label of alternate `index`, such as "Hex".
pub const SLICK_CALC_TEXT_ALTERNATE_LABEL: u32 = 3;
/// `slick_calc_text` which: the text of alternate `index`.
pub const SLICK_CALC_TEXT_ALTERNATE: u32 = 4;

/// `SlickCalcContext.date_order`: 25 December 2026.
pub const SLICK_CALC_DATE_DAY_MONTH_YEAR: u8 = 0;
/// `SlickCalcContext.date_order`: December 25, 2026.
pub const SLICK_CALC_DATE_MONTH_DAY_YEAR: u8 = 1;
/// `SlickCalcContext.date_order`: 2026 December 25.
pub const SLICK_CALC_DATE_YEAR_MONTH_DAY: u8 = 2;
/// `SlickCalcContext.hour_cycle`: 3:00 PM.
pub const SLICK_CALC_HOURS_12: u8 = 0;
/// `SlickCalcContext.hour_cycle`: 15:00.
pub const SLICK_CALC_HOURS_24: u8 = 1;
/// `SlickCalcContext.angle`: trigonometry in radians.
pub const SLICK_CALC_ANGLE_RADIANS: u8 = 0;
/// `SlickCalcContext.angle`: trigonometry in degrees.
pub const SLICK_CALC_ANGLE_DEGREES: u8 = 1;

/// An answer at or above this confidence should claim the top of root search.
pub const SLICK_CALC_CLAIMS_TOP: u8 = 80;
/// Queries longer than this many bytes, after trimming, are never calculations.
pub const SLICK_CALC_MAX_QUERY_LEN: u32 = 256;
/// The most alternate forms an answer carries.
pub const SLICK_CALC_MAX_ALTERNATES: u32 = 4;

/// The formats and the local zone a calculator uses, 24 bytes. The local zone's name and the
/// currency a bare "$" means are passed beside it as strings.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickCalcContext {
    /// The local zone's UTC offset now, in seconds east of UTC. Used only when the attached zone
    /// data lacks the local zone.
    pub local_offset_s: i32,
    /// The decimal separator, a Unicode scalar. Zero means '.'.
    pub decimal: u32,
    /// The grouping separator, a Unicode scalar. Zero means no grouping.
    pub grouping: u32,
    /// `SLICK_CALC_DATE_*`.
    pub date_order: u8,
    /// `SLICK_CALC_HOURS_*`.
    pub hour_cycle: u8,
    /// `SLICK_CALC_ANGLE_*`.
    pub angle: u8,
    /// Zero.
    pub reserved: [u8; 9],
}

/// What one evaluation found, 16 bytes. All zero for a query that is not math.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickCalcResult {
    /// `SLICK_CALC_KIND_*`.
    pub kind: u8,
    /// 1 to 100. At `SLICK_CALC_CLAIMS_TOP` or more the answer claims the top of the list.
    pub confidence: u8,
    /// `SLICK_CALC_PROBLEM_*`, set when `kind` is `SLICK_CALC_KIND_ERROR`.
    pub problem: u8,
    /// Number of alternate forms, at most `SLICK_CALC_MAX_ALTERNATES`.
    pub alternate_count: u8,
    /// Byte length of the formatted answer.
    pub main_len: u32,
    /// Byte length of the value to copy.
    pub copy_len: u32,
    /// Byte length of the note.
    pub note_len: u32,
}

/// The context a calculator owns. `slick_calc::Context` borrows its strings, so it is rebuilt
/// from this for every call, which costs a few stores.
#[derive(Clone, Debug)]
struct Settings {
    local_offset_s: i32,
    local_zone: String,
    decimal: char,
    grouping: Option<char>,
    date_order: DateOrder,
    hour_cycle: HourCycle,
    angle: AngleUnit,
    dollar: String,
}

impl Default for Settings {
    fn default() -> Self {
        let c = Context::new(0);
        Settings {
            local_offset_s: c.local_offset_s,
            local_zone: String::new(),
            decimal: c.decimal,
            grouping: c.grouping,
            date_order: c.date_order,
            hour_cycle: c.hour_cycle,
            angle: c.angle,
            dollar: c.dollar.to_string(),
        }
    }
}

/// An opaque calculator: one reusable answer, its context and the attached data.
pub struct SlickCalc {
    answer: Answer,
    /// False until an evaluation succeeds, and after any call that did not reach `evaluate`.
    holds_answer: bool,
    settings: Settings,
    zones: Option<Arc<ZoneDb>>,
    rates: Option<Arc<Rates>>,
}

/// Opaque, immutable time zone rules.
pub struct SlickCalcZones {
    inner: Arc<ZoneDb>,
}

/// Opaque exchange rates. Immutable once attached: an insert after that changes only this handle.
pub struct SlickCalcRates {
    inner: Arc<Rates>,
}

fn scalar(v: u32, default: Option<char>) -> Result<Option<char>, SlickStatus> {
    if v == 0 {
        return Ok(default);
    }
    char::from_u32(v).map(Some).ok_or(SlickStatus::InvalidArgument)
}

/// A currency code as `slick-calc` reads it: 2 to 6 ASCII letters, upper case. Empty means USD.
fn currency_code(s: &str) -> Result<String, SlickStatus> {
    if s.is_empty() {
        return Ok("USD".to_string());
    }
    if !(2..=6).contains(&s.len()) || !s.bytes().all(|b| b.is_ascii_alphabetic()) {
        return Err(SlickStatus::InvalidArgument);
    }
    Ok(s.to_ascii_uppercase())
}

/// Splits a list of names separated by `SLICK_LIST_SEPARATOR`, skipping empty ones.
fn names(list: &str) -> Vec<&str> {
    list.split(crate::args::SLICK_LIST_SEPARATOR as char)
        .filter(|s| !s.is_empty())
        .collect()
}

/// Copies `s` into the caller's buffer. With `cap` 0 it only measures and returns the length.
pub(crate) fn copy_text(s: &[u8], ptr: *mut u8, cap: usize) -> Result<i32, SlickStatus> {
    let len = i32::try_from(s.len()).map_err(|_| SlickStatus::InvalidArgument)?;
    if cap == 0 {
        return Ok(len);
    }
    let dst = out(ptr, cap)?;
    let dst = dst.get_mut(..s.len()).ok_or(SlickStatus::BufferTooSmall)?;
    dst.copy_from_slice(s);
    Ok(len)
}

fn length(s: &str) -> u32 {
    u32::try_from(s.len()).unwrap_or(u32::MAX)
}

/// Builds the calculator's lookup tables now, about 0.7 ms, so the first keystroke does not pay
/// for it. Safe from any thread, any number of times. Call it off the main thread at launch.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_prepare() -> i32 {
    guard(|| {
        slick_calc::prepare();
        SlickStatus::Ok as i32
    })
}

/// Creates a calculator with the default context (UTC, '.' and ',', day-month-year, 12-hour
/// clock, radians, US dollars, no zones, no rates) and stores it in `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_new(out: *mut *mut SlickCalc) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        *slot = Box::into_raw(Box::new(SlickCalc {
            answer: Answer::new(),
            holds_answer: false,
            settings: Settings::default(),
            zones: None,
            rates: None,
        }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Frees a calculator. NULL is allowed.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_free(calc: *mut SlickCalc) -> i32 {
    guard(|| {
        if !calc.is_null() {
            // SAFETY: a non-NULL calculator came from `slick_calc_new` and is freed once.
            drop(unsafe { Box::from_raw(calc) });
        }
        SlickStatus::Ok as i32
    })
}

/// Sets the formats, the local zone (an IANA name, UTF-8, may be empty) and the currency a bare
/// "$" means (an ISO 4217 code, empty for USD). Call it when the locale or the time zone
/// changes, not per keystroke. A refused context leaves the old one in place.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_set_context(
    calc: *mut SlickCalc,
    context: *const SlickCalcContext,
    local_zone: *const u8,
    local_zone_len: usize,
    dollar: *const u8,
    dollar_len: usize,
) -> i32 {
    guard_result(|| {
        let c = handle_mut(calc)?;
        let ctx = handle(context)?;
        let date_order = match ctx.date_order {
            SLICK_CALC_DATE_DAY_MONTH_YEAR => DateOrder::DayMonthYear,
            SLICK_CALC_DATE_MONTH_DAY_YEAR => DateOrder::MonthDayYear,
            SLICK_CALC_DATE_YEAR_MONTH_DAY => DateOrder::YearMonthDay,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        let hour_cycle = match ctx.hour_cycle {
            SLICK_CALC_HOURS_12 => HourCycle::H12,
            SLICK_CALC_HOURS_24 => HourCycle::H24,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        let angle = match ctx.angle {
            SLICK_CALC_ANGLE_RADIANS => AngleUnit::Radians,
            SLICK_CALC_ANGLE_DEGREES => AngleUnit::Degrees,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        let decimal = scalar(ctx.decimal, Some('.'))?.unwrap_or('.');
        let grouping = scalar(ctx.grouping, None)?;
        if grouping == Some(decimal) {
            return Err(SlickStatus::InvalidArgument);
        }
        let zone = text(local_zone, local_zone_len)?;
        let dollar = currency_code(text(dollar, dollar_len)?)?;
        c.settings = Settings {
            local_offset_s: ctx.local_offset_s.clamp(-18 * 3600, 18 * 3600),
            local_zone: zone.to_string(),
            decimal,
            grouping,
            date_order,
            hour_cycle,
            angle,
            dollar,
        };
        c.holds_answer = false;
        Ok(SlickStatus::Ok as i32)
    })
}

/// Attaches time zone rules, or detaches them with NULL. The calculator keeps its own reference,
/// so `zones` may be freed afterwards.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_set_zones(calc: *mut SlickCalc, zones: *const SlickCalcZones) -> i32 {
    guard_result(|| {
        let c = handle_mut(calc)?;
        c.zones = if zones.is_null() {
            None
        } else {
            Some(Arc::clone(&handle(zones)?.inner))
        };
        c.holds_answer = false;
        Ok(SlickStatus::Ok as i32)
    })
}

/// Attaches exchange rates, or detaches them with NULL. The calculator keeps its own reference
/// to the rates as they are now, so later inserts into `rates` do not reach it, and `rates` may
/// be freed afterwards.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_set_rates(calc: *mut SlickCalc, rates: *const SlickCalcRates) -> i32 {
    guard_result(|| {
        let c = handle_mut(calc)?;
        c.rates = if rates.is_null() {
            None
        } else {
            Some(Arc::clone(&handle(rates)?.inner))
        };
        c.holds_answer = false;
        Ok(SlickStatus::Ok as i32)
    })
}

/// Evaluates `query` (UTF-8) at `now_ms`, milliseconds since the Unix epoch, and writes what it
/// found into `*out`. Returns 1 for an answer or a calculation error, 0 for a query that is not
/// math, or a negative status. A query that is not math writes a zeroed result and allocates
/// nothing. Meant for every keystroke.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_evaluate(
    calc: *mut SlickCalc,
    query: *const u8,
    len: usize,
    now_ms: i64,
    out: *mut SlickCalcResult,
) -> i32 {
    guard_result(|| {
        let c = handle_mut(calc)?;
        let result = handle_mut(out)?;
        *result = SlickCalcResult::default();
        c.holds_answer = false;
        let q = text(query, len)?;
        let s = &c.settings;
        let ctx = Context {
            now_ms,
            local_offset_s: s.local_offset_s,
            local_zone: &s.local_zone,
            decimal: s.decimal,
            grouping: s.grouping,
            date_order: s.date_order,
            hour_cycle: s.hour_cycle,
            angle: s.angle,
            dollar: &s.dollar,
            rates: c.rates.as_deref(),
            zones: c.zones.as_deref(),
        };
        if !slick_calc::evaluate(q, &ctx, &mut c.answer) {
            return Ok(0);
        }
        let a = &c.answer;
        *result = SlickCalcResult {
            kind: a.kind as u8,
            confidence: a.confidence,
            problem: a.problem as u8,
            alternate_count: a.alternates().len() as u8,
            main_len: length(&a.main),
            copy_len: length(&a.copy),
            note_len: length(&a.note),
        };
        c.holds_answer = true;
        Ok(1)
    })
}

/// Copies one text of the last answer into `out` and returns its byte length (UTF-8, no NUL).
/// `which` is a `SLICK_CALC_TEXT_*`; `index` picks the alternate and is ignored otherwise. With
/// `cap` 0 nothing is written and the length comes back, so a caller can size its buffer. Returns
/// `SLICK_STATUS_BUFFER_TOO_SMALL` when `cap` is smaller than the text, and
/// `SLICK_STATUS_INVALID_ARGUMENT` for an unknown `which` or an alternate that does not exist.
/// Without an answer every text is empty.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_text(calc: *const SlickCalc, which: u32, index: u32, out: *mut u8, cap: usize) -> i32 {
    guard_result(|| {
        let c = handle(calc)?;
        let a = &c.answer;
        let alternate = |i: u32| -> Result<&slick_calc::Alternate, SlickStatus> {
            match c.holds_answer {
                true => a.alternates().get(i as usize).ok_or(SlickStatus::InvalidArgument),
                false => Err(SlickStatus::InvalidArgument),
            }
        };
        let s: &str = match which {
            _ if !c.holds_answer && which <= SLICK_CALC_TEXT_NOTE => "",
            SLICK_CALC_TEXT_MAIN => &a.main,
            SLICK_CALC_TEXT_COPY => &a.copy,
            SLICK_CALC_TEXT_NOTE => &a.note,
            SLICK_CALC_TEXT_ALTERNATE_LABEL => alternate(index)?.label,
            SLICK_CALC_TEXT_ALTERNATE => &alternate(index)?.text,
            _ => return Err(SlickStatus::InvalidArgument),
        };
        copy_text(s.as_bytes(), out, cap)
    })
}

/// Reads time zone rules for every zone the calculator names, plus `extra` zone names (UTF-8,
/// separated by `SLICK_LIST_SEPARATOR`, such as the local zone), from a compiled zoneinfo folder
/// and stores them in `*out`. With `dir_len` 0 it reads the system's zoneinfo. Returns the number
/// of zones loaded. Reads about 260 small files: call it off the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_zones_load(
    dir: *const u8,
    dir_len: usize,
    extra: *const u8,
    extra_len: usize,
    out: *mut *mut SlickCalcZones,
) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let dir = bytes(dir, dir_len)?;
        let extra = text(extra, extra_len)?;
        let extra = names(extra);
        let db = if dir.is_empty() {
            ZoneDb::load_system(&extra)
        } else {
            ZoneDb::load_dir(Path::new(OsStr::from_bytes(dir)), &extra)
        };
        let count = i32::try_from(db.len()).unwrap_or(i32::MAX);
        *slot = Box::into_raw(Box::new(SlickCalcZones { inner: Arc::new(db) }));
        Ok(count)
    })
}

/// Frees a zones handle. NULL is allowed. Calculators it is attached to keep their own reference.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_zones_free(zones: *mut SlickCalcZones) -> i32 {
    guard(|| {
        if !zones.is_null() {
            // SAFETY: a non-NULL zones handle came from `slick_calc_zones_load` and is freed once.
            drop(unsafe { Box::from_raw(zones) });
        }
        SlickStatus::Ok as i32
    })
}

/// Creates an empty rate table against the currency `base` (a code of 2 to 6 ASCII letters, such
/// as "USD"), fetched at `timestamp_ms` milliseconds since the Unix epoch, and stores it in
/// `*out`. Returns `SLICK_STATUS_INVALID_ARGUMENT` when `base` is not such a code.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_rates_new(
    base: *const u8,
    base_len: usize,
    timestamp_ms: i64,
    out: *mut *mut SlickCalcRates,
) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let base = text(base, base_len)?;
        let rates = Rates::new(&base.to_ascii_uppercase(), timestamp_ms).ok_or(SlickStatus::InvalidArgument)?;
        *slot = Box::into_raw(Box::new(SlickCalcRates { inner: Arc::new(rates) }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Sets how many units of `code` (2 to 6 ASCII letters, UTF-8) one unit of the base buys. Returns
/// 1 when stored, 0 for a malformed code or a rate that is not finite and positive. Calculators the table is already attached to do not see the change.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_rates_insert(
    rates: *mut SlickCalcRates,
    code: *const u8,
    len: usize,
    per_base: f64,
) -> i32 {
    guard_result(|| {
        let r = handle_mut(rates)?;
        let code = text(code, len)?;
        Ok(Arc::make_mut(&mut r.inner).insert(&code.to_ascii_uppercase(), per_base) as i32)
    })
}

/// Returns the number of currencies in the table, the base included.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_rates_count(rates: *const SlickCalcRates) -> i32 {
    guard_result(|| Ok(i32::try_from(handle(rates)?.inner.len()).unwrap_or(i32::MAX)))
}

/// Frees a rates handle. NULL is allowed. Calculators it is attached to keep their own reference.
#[unsafe(no_mangle)]
pub extern "C" fn slick_calc_rates_free(rates: *mut SlickCalcRates) -> i32 {
    guard(|| {
        if !rates.is_null() {
            // SAFETY: a non-NULL rates handle came from `slick_calc_rates_new` and is freed once.
            drop(unsafe { Box::from_raw(rates) });
        }
        SlickStatus::Ok as i32
    })
}
