//! Time zone rules from the system zoneinfo: daylight saving, transitions and far-future dates.

mod support;

use slick_calc::{Answer, Context, Kind, ZoneDb, evaluate, zone_names};
use support::Options;

/// Milliseconds at a UTC date and time.
fn at(y: i64, m: i64, d: i64, h: i64, min: i64) -> i64 {
    // Days from civil, Howard Hinnant's algorithm.
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    ((days * 24 + h) * 60 + min) * 60_000
}

fn ctx_at(now_ms: i64, local_offset_s: i32) -> Context<'static> {
    let mut c = support::context(Options::default());
    c.now_ms = now_ms;
    c.local_offset_s = local_offset_s;
    c
}

fn main_of(q: &str, ctx: &Context) -> String {
    let mut a = Answer::new();
    assert!(evaluate(q, ctx, &mut a), "{q} was rejected");
    assert_ne!(a.kind, Kind::Error, "{q}: {}", a.main);
    a.main
}

#[test]
fn every_named_zone_loads_from_the_system() {
    let db = support::zones();
    if db.is_empty() {
        return;
    }
    let missing: Vec<&str> = zone_names().iter().copied().filter(|z| !db.contains(z)).collect();
    assert!(missing.is_empty(), "zones that did not load: {missing:?}");
    assert!(zone_names().len() > 200, "{} zones", zone_names().len());
}

#[test]
fn summer_time_follows_each_region() {
    if support::zones().is_empty() {
        return;
    }
    // 2026-07-01 12:00 UTC: New York is on EDT, London on BST, Sydney on AEST.
    let ctx = ctx_at(at(2026, 7, 1, 12, 0), -4 * 3600);
    assert_eq!(main_of("time in london", &ctx), "1:00 PM, Wed 1 Jul");
    assert_eq!(main_of("time in new york", &ctx), "8:00 AM, Wed 1 Jul");
    assert_eq!(main_of("time in sydney", &ctx), "10:00 PM, Wed 1 Jul");
    assert_eq!(main_of("3pm new york in london", &ctx), "8:00 PM, Wed 1 Jul");
    // A fixed abbreviation stays fixed: PST is UTC-8 even in July.
    assert_eq!(main_of("9am pst to utc", &ctx), "5:00 PM, Wed 1 Jul");
    // A generic region name follows the region: PT is PDT in July.
    assert_eq!(main_of("9am pt to utc", &ctx), "4:00 PM, Wed 1 Jul");
}

#[test]
fn dates_past_the_last_transition_use_the_footer_rule() {
    if support::zones().is_empty() {
        return;
    }
    // 2045 is past the 2037 end of the transitions in the compiled files.
    let ctx = ctx_at(at(2045, 7, 1, 12, 0), -4 * 3600);
    assert_eq!(main_of("time in new york", &ctx), "8:00 AM, Sat 1 Jul");
    assert_eq!(main_of("time in paris", &ctx), "2:00 PM, Sat 1 Jul");
    let winter = ctx_at(at(2045, 1, 15, 12, 0), -5 * 3600);
    assert_eq!(main_of("time in new york", &winter), "7:00 AM, Sun 15 Jan");
}

#[test]
fn a_wall_time_in_the_spring_gap_resolves() {
    if support::zones().is_empty() {
        return;
    }
    // US clocks jump from 2:00 to 3:00 on 2026-03-08. 2:30 does not exist in New York; the
    // answer must still be a time, not an error or a panic.
    let ctx = ctx_at(at(2026, 3, 8, 12, 0), -4 * 3600);
    let got = main_of("2:30am new york in utc", &ctx);
    assert!(got == "6:30 AM, Sun 8 Mar" || got == "7:30 AM, Sun 8 Mar", "{got}");
    // An hour later the offset is the summer one.
    assert_eq!(main_of("4:00am new york in utc", &ctx), "8:00 AM, Sun 8 Mar");
}

#[test]
fn an_empty_database_says_so() {
    let mut c = support::context(Options::default());
    let empty = Box::leak(Box::new(ZoneDb::new()));
    c.zones = Some(empty);
    let mut a = Answer::new();
    assert!(evaluate("time in tokyo", &c, &mut a));
    assert_eq!(a.kind, Kind::Error);
    assert_eq!(a.main, "Unknown time zone");
}
