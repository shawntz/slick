//! A fixed moment, zone, rate table and format for tests and benchmarks.
//!
//! The moment is Sunday 15 November 2026, 14:30 UTC, which is 09:30 in the local zone,
//! America/New_York. The rates are made up for tests and are not real market data.

#![allow(dead_code)]

use slick_calc::{AngleUnit, Context, DateOrder, HourCycle, Rates, ZoneDb};
use std::sync::OnceLock;

/// 2026-11-15T14:30:00Z.
pub const NOW_MS: i64 = 1_794_753_000_000;
pub const LOCAL_ZONE: &str = "America/New_York";
/// EST, the local offset at `NOW_MS`.
pub const LOCAL_OFFSET: i32 = -5 * 3600;

pub fn zones() -> &'static ZoneDb {
    static ZONES: OnceLock<ZoneDb> = OnceLock::new();
    ZONES.get_or_init(|| ZoneDb::load_system(&[LOCAL_ZONE]))
}

pub fn rates() -> &'static Rates {
    static RATES: OnceLock<Rates> = OnceLock::new();
    RATES.get_or_init(|| {
        // 2026-11-15T12:00:00Z. Units per US dollar.
        let mut r = Rates::new("USD", 1_794_744_000_000).unwrap_or_else(|| unreachable!());
        for (code, rate) in [
            ("EUR", 0.92),
            ("GBP", 0.80),
            ("JPY", 155.0),
            ("CAD", 1.40),
            ("AUD", 1.50),
            ("CHF", 0.88),
            ("CNY", 7.20),
            ("INR", 84.0),
            ("MXN", 18.5),
            ("BRL", 5.80),
            ("KRW", 1400.0),
            ("SEK", 10.5),
            ("PLN", 4.0),
            ("TRY", 34.0),
            ("ZAR", 18.0),
            ("BTC", 0.00001),
        ] {
            r.insert(code, rate);
        }
        r
    })
}

/// Options a test file can change.
#[derive(Clone, Copy, Debug)]
pub struct Options {
    pub decimal: char,
    pub grouping: Option<char>,
    pub rates: bool,
    pub zones: bool,
    pub angle: AngleUnit,
    pub hours: HourCycle,
    pub order: DateOrder,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            decimal: '.',
            grouping: Some(','),
            rates: true,
            zones: true,
            angle: AngleUnit::Radians,
            hours: HourCycle::H12,
            order: DateOrder::DayMonthYear,
        }
    }
}

pub fn context(o: Options) -> Context<'static> {
    let mut c = Context::new(NOW_MS);
    c.local_zone = LOCAL_ZONE;
    c.local_offset_s = LOCAL_OFFSET;
    c.decimal = o.decimal;
    c.grouping = o.grouping;
    c.angle = o.angle;
    c.hour_cycle = o.hours;
    c.date_order = o.order;
    c.rates = if o.rates { Some(rates()) } else { None };
    c.zones = if o.zones { Some(zones()) } else { None };
    c
}
