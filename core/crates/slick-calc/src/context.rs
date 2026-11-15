//! What the caller tells the engine about the moment, the user's formats and the data it holds.

use crate::currency::Rates;
use crate::tz::ZoneDb;

/// The order of day, month and year when a date is written out.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum DateOrder {
    /// 25 December 2026.
    #[default]
    DayMonthYear,
    /// December 25, 2026.
    MonthDayYear,
    /// 2026 December 25.
    YearMonthDay,
}

/// 12-hour or 24-hour clock in answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum HourCycle {
    /// 3:00 PM.
    #[default]
    H12,
    /// 15:00.
    H24,
}

/// The unit trigonometric functions take and their inverses return, when the query names none.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum AngleUnit {
    #[default]
    Radians,
    Degrees,
}

/// Everything the engine knows about the outside world. It holds no locale logic of its own:
/// the caller passes the separators, orders and data it should use.
#[derive(Clone, Copy, Debug)]
pub struct Context<'a> {
    /// The current instant, in milliseconds since the Unix epoch.
    pub now_ms: i64,
    /// The local zone's UTC offset at `now_ms`, in seconds east of UTC. Used when `zones` lacks
    /// the local zone.
    pub local_offset_s: i32,
    /// The local IANA zone name, such as "Europe/Paris". May be empty.
    pub local_zone: &'a str,
    /// The decimal separator, usually '.' or ','.
    pub decimal: char,
    /// The grouping separator, or None for no grouping.
    pub grouping: Option<char>,
    pub date_order: DateOrder,
    pub hour_cycle: HourCycle,
    pub angle: AngleUnit,
    /// The currency that a bare "$" and "dollars" mean, as an ISO 4217 code. Default "USD".
    pub dollar: &'a str,
    /// Exchange rates, when the caller has them.
    pub rates: Option<&'a Rates>,
    /// Time zone rules, when the caller has loaded them.
    pub zones: Option<&'a ZoneDb>,
}

impl<'a> Context<'a> {
    /// A context at `now_ms` in UTC, with '.' for decimals, ',' for grouping and no data.
    pub fn new(now_ms: i64) -> Context<'a> {
        Context {
            now_ms,
            local_offset_s: 0,
            local_zone: "",
            decimal: '.',
            grouping: Some(','),
            date_order: DateOrder::DayMonthYear,
            hour_cycle: HourCycle::H12,
            angle: AngleUnit::Radians,
            dollar: "USD",
            rates: None,
            zones: None,
        }
    }
}
