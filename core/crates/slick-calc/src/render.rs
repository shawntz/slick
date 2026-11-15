//! Turns a parsed outcome into an [`Answer`]: kind, confidence, main text, copy value, note and
//! alternate forms.

use crate::answer::{Answer, Kind, Problem};
use crate::cal;
use crate::currency::{self, Code};
use crate::format::{self, Seps, Style};
use crate::lexicon::Const;
use crate::num::Num;
use crate::parse::{Display, Outcome, Score};
use crate::places;
use crate::units::{self, NAMED, TIGHT, TIME, UnitRef};
use crate::value::{Env, Qty, Val, ZoneSel};
use core::fmt::Write as _;

/// How sure the engine is that the query is a calculation. None rejects it.
fn confidence(o: &Outcome) -> Option<u8> {
    let s: &Score = &o.score;
    let mut c = 0u8;
    if s.conv {
        c = 90;
    }
    if s.ops > 0 {
        c = c.max(if s.literals >= 2 || s.ops >= 2 || s.constant.is_some() {
            95
        } else {
            90
        });
    }
    if s.implicit > 0 {
        c = c.max(85);
    }
    c = c.max(s.form);
    if c == 0 {
        c = match o.val {
            Val::Qty(_) if s.compound => 70,
            Val::Qty(_) if s.glued_symbol => 30,
            Val::Qty(_) => 60,
            Val::Money(..) => 40,
            Val::Num(_) => match s.constant {
                Some(Const::Pi) => 70,
                Some(Const::E) => 0,
                Some(_) => 60,
                None if s.based => 75,
                None if s.sci => 60,
                None if s.scaled => 30,
                None => 0,
            },
            Val::Pct(_) | Val::Err(_) => 0,
            _ => 40,
        };
    }
    if c == 0 { None } else { Some(c) }
}

/// Fills `out` from an outcome. False when the outcome is not worth showing.
pub(crate) fn render(o: &Outcome, env: &Env, out: &mut Answer) -> bool {
    let Some(confidence) = confidence(o) else { return false };
    out.confidence = confidence;
    let seps = Seps::of(env.ctx);
    let r = match o.val {
        Val::Num(n) => number(o, n, env, &seps, out),
        Val::Pct(p) => percent(o, p, &seps, out),
        Val::Qty(q) => quantity(o, q, &seps, out),
        Val::Money(n, c) => money(o, n, c, env, &seps, out),
        Val::Date(d) => date(d, env, out),
        Val::Moment(t, z) => moment(t, z, env, out),
        Val::Clock(s, z) => match env.anchor_clock(s, z) {
            Ok(t) => moment(t, z, env, out),
            Err(p) => Err(p),
        },
        Val::Weekday(d) => {
            out.kind = Kind::Text;
            out.main
                .push_str(cal::WEEKDAYS.get(cal::weekday(d) as usize).copied().unwrap_or(""));
            out.copy.push_str(&out.main);
            format::date_long(&mut out.note, d, env.ctx.date_order);
            Ok(())
        }
        Val::ZoneDiff(a, b) => zone_diff(a, b, env, out),
        Val::Err(p) => Err(p),
    };
    if let Err(p) = r {
        // An error only shows for a query that is clearly a calculation.
        if confidence < 60 {
            out.clear();
            return false;
        }
        let keep = out.confidence;
        out.clear();
        out.confidence = keep;
        out.kind = Kind::Error;
        out.problem = p;
        out.main.push_str(p.message());
    }
    true
}

fn number(o: &Outcome, n: Num, env: &Env, seps: &Seps, out: &mut Answer) -> Result<(), Problem> {
    out.kind = Kind::Number;
    match o.display {
        Some(Display::Base(b)) => {
            if !format::radix(&mut out.main, n, b, true) {
                return Err(Problem::NotWhole);
            }
            if b != 2 && b != 8 && b != 16 {
                let _ = write!(out.main, " (base {b})");
            }
            format::radix(&mut out.copy, n, b, false);
            if b == 10 {
                out.main.clear();
                format::number(&mut out.main, n, Style::Number, seps);
            }
            if b != 10 {
                alt(out, "Decimal", |s| format::number(s, n, Style::Number, seps));
            }
            if b != 16 {
                alt(out, "Hex", |s| {
                    format::radix(s, n, 16, true);
                });
            }
            if b != 2 {
                alt(out, "Binary", |s| {
                    format::radix(s, n, 2, true);
                });
            }
            return Ok(());
        }
        Some(Display::Words) => {
            out.kind = Kind::Text;
            if !format::words(&mut out.main, n) {
                return Err(Problem::Overflow);
            }
            out.copy.push_str(&out.main);
            alt(out, "Number", |s| format::number(s, n, Style::Number, seps));
            return Ok(());
        }
        Some(Display::Fraction(mixed)) => {
            if !format::fraction(&mut out.main, n, mixed) {
                format::number(&mut out.main, n, Style::Number, seps);
            }
            out.copy.push_str(&out.main);
            alt(out, "Decimal", |s| format::number(s, n, Style::Number, seps));
            return Ok(());
        }
        Some(Display::Sci) => {
            sci(&mut out.main, n, seps, false);
            sci(&mut out.copy, n, seps, true);
            alt(out, "Decimal", |s| format::number(s, n, Style::Number, seps));
            return Ok(());
        }
        Some(Display::Percent) => {
            out.kind = Kind::Percent;
            let p = n.mul(Num::int(100))?;
            format::number(&mut out.main, p, Style::Number, seps);
            out.main.push('%');
            out.copy.push_str(&out.main);
            return Ok(());
        }
        Some(Display::Unix) | None if o.score.unix => {
            format::number(&mut out.main, n, Style::Plain, seps);
            out.copy.push_str(&out.main);
            if let Some(t) = n.as_exact_int().and_then(|v| i64::try_from(v).ok()) {
                alt(out, "Local", |s| moment_text(s, t, ZoneSel::Local, env));
                alt(out, "UTC", |s| moment_text(s, t, ZoneSel::Fixed(0, None), env));
            }
            return Ok(());
        }
        Some(Display::Unix) | None => {}
    }
    format::number(&mut out.main, n, Style::Number, seps);
    format::number(
        &mut out.copy,
        n,
        Style::Copy,
        &Seps {
            decimal: seps.decimal,
            grouping: None,
        },
    );
    if o.score.based && n.as_int().is_some() {
        alt(out, "Hex", |s| {
            format::radix(s, n, 16, true);
        });
        alt(out, "Binary", |s| {
            format::radix(s, n, 2, true);
        });
    }
    if let Num::Ratio(p, q) = n
        && q > 1
        && q <= 1000
        && !terminates(q)
    {
        alt(out, "Fraction", |s| {
            let _ = write!(s, "{p}/{q}");
        });
    }
    let x = n.to_f64().abs();
    if x >= 1e9 && !out.main.contains('×') {
        alt(out, "Scientific", |s| sci(s, n, seps, false));
    }
    // A long exact integer shows in scientific notation; keep every digit as an alternate.
    if let Some(v) = n.as_exact_int()
        && out.main.contains('×')
    {
        alt(out, "Exact", |s| {
            let mut digits = String::new();
            let _ = write!(digits, "{}", v.unsigned_abs());
            if v < 0 {
                s.push('-');
            }
            let len = digits.len();
            for (i, c) in digits.chars().enumerate() {
                if i > 0
                    && (len - i).is_multiple_of(3)
                    && let Some(g) = seps.grouping
                {
                    s.push(g);
                }
                s.push(c);
            }
        });
    }
    Ok(())
}

/// True when 1/q has a finite decimal expansion.
fn terminates(mut q: i128) -> bool {
    while q % 2 == 0 {
        q /= 2;
    }
    while q % 5 == 0 {
        q /= 5;
    }
    q == 1
}

fn sci(out: &mut String, n: Num, seps: &Seps, copy: bool) {
    let x = n.to_f64();
    if x == 0.0 {
        out.push('0');
        return;
    }
    let exp = x.abs().log10().floor() as i32;
    let mantissa = x / 10f64.powi(exp);
    // Guard against 9.9999 rounding up to 10.
    let (mantissa, exp) = if mantissa.abs() >= 9.999_999_999_999_5 {
        (mantissa / 10.0, exp + 1)
    } else {
        (mantissa, exp)
    };
    let m = Num::Float(mantissa);
    format::number(
        out,
        m,
        if copy { Style::Copy } else { Style::Number },
        &Seps {
            decimal: seps.decimal,
            grouping: None,
        },
    );
    if copy {
        let _ = write!(out, "e{exp}");
    } else {
        out.push_str(" × 10");
        let mut buf = String::new();
        let _ = write!(buf, "{exp}");
        for c in buf.chars() {
            out.push(match c {
                '-' => '⁻',
                '0' => '⁰',
                '1' => '¹',
                '2' => '²',
                '3' => '³',
                '4' => '⁴',
                '5' => '⁵',
                '6' => '⁶',
                '7' => '⁷',
                '8' => '⁸',
                _ => '⁹',
            });
        }
    }
}

fn percent(o: &Outcome, p: Num, seps: &Seps, out: &mut Answer) -> Result<(), Problem> {
    out.kind = Kind::Percent;
    let v = p.mul(Num::int(100))?;
    if o.score.signed_pct && !v.is_negative() && !v.is_zero() {
        out.main.push('+');
    }
    format::number(&mut out.main, v, Style::Number, seps);
    out.main.push('%');
    format::number(
        &mut out.copy,
        v,
        Style::Copy,
        &Seps {
            decimal: seps.decimal,
            grouping: None,
        },
    );
    out.copy.push('%');
    alt(out, "Decimal", |s| format::number(s, p, Style::Number, seps));
    Ok(())
}

/// The label for a unit after a value: "km", "°", "hours", "kilometres".
fn unit_label(out: &mut String, u: UnitRef, one: bool) {
    let (Some(d), Some(p)) = (u.def(), u.prefix_def()) else {
        return;
    };
    if d.flags & NAMED != 0 {
        out.push(' ');
        out.push_str(p.name);
        out.push_str(if one { d.one } else { d.many });
    } else {
        if d.flags & TIGHT == 0 {
            out.push(' ');
        }
        out.push_str(p.sym);
        out.push_str(d.sym);
    }
}

fn qty_text(out: &mut String, q: &Qty, u: UnitRef, seps: &Seps) -> Result<(), Problem> {
    let v = u.of_base(q.base)?;
    format::number(out, v, Style::Unit, seps);
    unit_label(out, u, format::is_one(v, Style::Unit));
    Ok(())
}

/// "5 ft 10.8661 in": the whole part in the first unit, the rest in the second.
fn mixed_text(out: &mut String, q: &Qty, first: UnitRef, second: UnitRef, seps: &Seps) -> Result<(), Problem> {
    let v = first.of_base(q.base)?;
    let neg = v.is_negative();
    let whole = v.abs().round_with(0, crate::num::Rounding::Floor)?;
    let rest_base = q.base.abs().sub(first.to_base(whole)?)?;
    let mut rest = second.of_base(rest_base)?;
    let mut whole = whole;
    // 11.99999 inches that rounds to 12 carries into the feet.
    let mut probe = String::new();
    format::number(&mut probe, rest, Style::Unit, seps);
    let full = second.of_base(first.to_base(Num::ONE)?)?;
    let mut full_text = String::new();
    format::number(&mut full_text, full, Style::Unit, seps);
    if probe == full_text {
        whole = whole.add(Num::ONE)?;
        rest = Num::ZERO;
    }
    if neg {
        out.push('-');
    }
    if !whole.is_zero() {
        format::number(out, whole, Style::Unit, seps);
        unit_label(out, first, format::is_one(whole, Style::Unit));
    }
    if !rest.is_zero() || whole.is_zero() {
        if !whole.is_zero() {
            out.push(' ');
        }
        format::number(out, rest, Style::Unit, seps);
        unit_label(out, second, format::is_one(rest, Style::Unit));
    }
    Ok(())
}

/// "3 h 15 min", "40 days", "1 d 2 h 3 min".
fn duration_text(out: &mut String, secs: Num, seps: &Seps) {
    let total = secs.to_f64();
    let neg = total < 0.0;
    let mut s = total.abs();
    if neg {
        out.push('-');
    }
    let days = (s / 86_400.0).floor();
    s -= days * 86_400.0;
    let hours = (s / 3600.0).floor();
    s -= hours * 3600.0;
    let minutes = (s / 60.0).floor();
    s -= minutes * 60.0;
    let seconds = (s * 1000.0).round() / 1000.0;
    let mut parts = 0;
    let mut part = |out: &mut String, v: f64, short: &str, one: &str, many: &str| {
        if v == 0.0 {
            return;
        }
        if parts > 0 {
            out.push(' ');
        }
        parts += 1;
        format::number(out, Num::Float(v), Style::Unit, seps);
        out.push(' ');
        out.push_str(if days > 0.0 || hours > 0.0 || minutes > 0.0 && seconds > 0.0 {
            short
        } else if v == 1.0 {
            one
        } else {
            many
        });
    };
    part(out, days, "d", "day", "days");
    part(out, hours, "h", "hour", "hours");
    part(out, minutes, "min", "minute", "minutes");
    part(out, seconds, "s", "second", "seconds");
    if parts == 0 {
        out.push_str("0 seconds");
    }
    if parts == 1 {
        // "40 d" reads better as "40 days".
        let fix = [(" d", " days"), (" h", " hours")];
        for (short, long) in fix {
            if out.ends_with(short) {
                let cut = out.len() - short.len();
                out.truncate(cut);
                out.push_str(if out.ends_with(" 1") || out == "1" {
                    &long[..long.len() - 1]
                } else {
                    long
                });
            }
        }
    }
}

fn quantity(o: &Outcome, q: Qty, seps: &Seps, out: &mut Answer) -> Result<(), Problem> {
    let time = q.dim == TIME;
    out.kind = if time { Kind::Duration } else { Kind::Quantity };
    let echo = o.score.compound && o.score.ops == 0 && !o.score.conv;
    let value = q.unit.of_base(q.base)?;
    match o.display {
        Some(Display::Words) => {
            out.kind = Kind::Text;
            format::words(&mut out.main, value);
            unit_label(&mut out.main, q.unit, format::is_one(value, Style::Unit));
            out.copy.push_str(&out.main);
            return Ok(());
        }
        Some(Display::Sci) => {
            sci(&mut out.main, value, seps, false);
            unit_label(&mut out.main, q.unit, false);
            sci(&mut out.copy, value, seps, true);
            return Ok(());
        }
        _ => {}
    }
    let copy_seps = Seps {
        decimal: seps.decimal,
        grouping: None,
    };
    match q.mixed {
        Some(second) if time && !echo => {
            duration_text(&mut out.main, q.base, seps);
            let hours = units::by_sym("h").ok_or(Problem::Unsupported)?;
            let minutes = units::by_sym("min").ok_or(Problem::Unsupported)?;
            let _ = second;
            out.copy.push_str(&out.main);
            if q.base.to_f64().abs() >= 3600.0 {
                alt(out, "Hours", |s| {
                    let _ = qty_text(s, &q, hours, seps);
                });
            }
            if q.base.to_f64().abs() >= 60.0 {
                alt(out, "Minutes", |s| {
                    let _ = qty_text(s, &q, minutes, seps);
                });
            }
            return Ok(());
        }
        Some(second) if !echo => {
            mixed_text(&mut out.main, &q, q.unit, second, seps)?;
            format::number(&mut out.copy, value, Style::Copy, &copy_seps);
            alt(out, "Single unit", |s| {
                let _ = qty_text(s, &q, q.unit, seps);
            });
            return Ok(());
        }
        Some(second) => {
            // "5 ft 11 in" alone: show it in the other system.
            let main_unit = if time {
                units::by_sym("h")
            } else {
                units::counterpart(q.unit)
            };
            let main_unit = main_unit.unwrap_or(q.unit);
            qty_text(&mut out.main, &q, main_unit, seps)?;
            format::number(&mut out.copy, main_unit.of_base(q.base)?, Style::Copy, &copy_seps);
            if time {
                alt(out, "Minutes", |s| {
                    if let Some(m) = units::by_sym("min") {
                        let _ = qty_text(s, &q, m, seps);
                    }
                });
            } else {
                alt(out, "Single unit", |s| {
                    let _ = qty_text(s, &q, q.unit, seps);
                });
                let _ = second;
            }
            return Ok(());
        }
        None => {}
    }
    qty_text(&mut out.main, &q, q.unit, seps)?;
    format::number(&mut out.copy, value, Style::Copy, &copy_seps);
    if time {
        let in_days = units::by_sym("d").is_some_and(|d| d == q.unit);
        if q.base.to_f64().abs() >= 60.0 && !in_days {
            alt(out, "Duration", |s| duration_text(s, q.base, seps));
        }
        // Whole days of a week or more also read as weeks and days.
        if in_days
            && let Ok(days) = q.base.div(Num::int(86_400))
            && let Some(days) = days.as_exact_int()
            && days.unsigned_abs() >= 7
        {
            alt(out, "Weeks", |s| {
                let (weeks, rest) = (days.unsigned_abs() / 7, days.unsigned_abs() % 7);
                let sign = if days < 0 { "-" } else { "" };
                let _ = write!(s, "{sign}{weeks} week{}", if weeks == 1 { "" } else { "s" });
                if rest > 0 {
                    let _ = write!(s, " {rest} day{}", if rest == 1 { "" } else { "s" });
                }
            });
        }
        return Ok(());
    }
    // After an explicit conversion the other system is usually what the user typed.
    if !o.score.conv
        && let Some(c) = units::counterpart(q.unit)
        && (c.dim() == q.dim || c.flags() & units::FUEL != 0)
    {
        let label = if c.flags() & units::METRIC != 0 {
            "Metric"
        } else if c.flags() & units::IMPERIAL != 0 {
            "Imperial"
        } else {
            "Other unit"
        };
        alt(out, label, |s| {
            if let Ok(cq) = crate::value::convert(q, c) {
                let _ = qty_text(s, &cq, c, seps);
            }
        });
    }
    Ok(())
}

fn money(o: &Outcome, n: Num, c: Code, env: &Env, seps: &Seps, out: &mut Answer) -> Result<(), Problem> {
    out.kind = Kind::Currency;
    let digits = currency::digits(c);
    format::number(&mut out.main, n, Style::Money(digits), seps);
    out.main.push(' ');
    out.main.push_str(c.as_str());
    format::number(
        &mut out.copy,
        n,
        Style::Money(digits),
        &Seps {
            decimal: seps.decimal,
            grouping: None,
        },
    );
    if env.rates_used.get()
        && let Some(rates) = env.ctx.rates
    {
        let day = cal::valid_day(rates.timestamp_ms().div_euclid(86_400_000)).unwrap_or(0);
        out.note.push_str("Rates from ");
        let (y, m, d) = cal::ymd(day);
        let month = cal::MONTHS.get((m - 1) as usize).copied().unwrap_or("");
        let _ = write!(out.note, "{d} {} {y}", month.get(..3).unwrap_or(month));
        if let Some(from) = o.score.from_currency
            && from != c
            && let Some(f) = rates.factor(from, c)
            && let Ok(rate) = Num::float(f)
        {
            alt(out, "Rate", |s| {
                let _ = write!(s, "1 {} = ", from.as_str());
                format::number(s, rate, Style::Unit, seps);
                let _ = write!(s, " {}", c.as_str());
            });
            if let Ok(inv) = rate.recip() {
                alt(out, "Inverse rate", |s| {
                    let _ = write!(s, "1 {} = ", c.as_str());
                    format::number(s, inv, Style::Unit, seps);
                    let _ = write!(s, " {}", from.as_str());
                });
            }
        }
    }
    Ok(())
}

fn date(d: i32, env: &Env, out: &mut Answer) -> Result<(), Problem> {
    out.kind = Kind::Date;
    format::date_long(&mut out.main, d, env.ctx.date_order);
    format::date_iso(&mut out.copy, d);
    let today = env.today();
    let delta = i64::from(d) - i64::from(today);
    alt(out, "Relative", |s| {
        let _ = match delta {
            0 => write!(s, "Today"),
            1 => write!(s, "Tomorrow"),
            -1 => write!(s, "Yesterday"),
            k if k > 0 => write!(s, "In {k} days"),
            k => write!(s, "{} days ago", -k),
        };
    });
    Ok(())
}

/// "3:00 PM, Mon 16 Nov".
fn moment_text(out: &mut String, t: i64, z: ZoneSel, env: &Env) {
    let Ok(tt) = env.at(z, t) else { return };
    let local = t + i64::from(tt.off);
    format::clock(out, local, env.ctx.hour_cycle);
    out.push_str(", ");
    let day = local.div_euclid(cal::SECS_PER_DAY) as i32;
    let this_year = cal::ymd(env.today()).0;
    format::date_short(out, day, env.ctx.date_order, this_year);
}

fn zone_name(out: &mut String, z: ZoneSel, abbr: &str, off: i32) {
    match z {
        ZoneSel::Local => out.push_str("Local time"),
        ZoneSel::Tz(id, place) => {
            let name = place
                .and_then(places::place)
                .map(|p| p.name)
                .or_else(|| places::zone_name(id))
                .unwrap_or("");
            out.push_str(name);
        }
        ZoneSel::Fixed(..) => {}
    }
    if !abbr.is_empty() && !abbr.starts_with('+') && !abbr.starts_with('-') {
        if !out.is_empty() {
            out.push_str(", ");
        }
        out.push_str(abbr);
    }
    if !out.is_empty() {
        out.push_str(", ");
    }
    format::utc_offset(out, off);
}

fn moment(t: i64, z: ZoneSel, env: &Env, out: &mut Answer) -> Result<(), Problem> {
    out.kind = Kind::Time;
    let tt = env.at(z, t)?;
    let local = t + i64::from(tt.off);
    moment_text(&mut out.main, t, z, env);
    format::clock(&mut out.copy, local, env.ctx.hour_cycle);
    zone_name(&mut out.note, z, tt.abbr.as_str(), tt.off);
    if z != ZoneSel::Local {
        alt(out, "Local", |s| moment_text(s, t, ZoneSel::Local, env));
    }
    if !matches!(z, ZoneSel::Fixed(0, _)) {
        alt(out, "UTC", |s| moment_text(s, t, ZoneSel::Fixed(0, None), env));
    }
    alt(out, "ISO 8601", |s| {
        let day = local.div_euclid(cal::SECS_PER_DAY) as i32;
        format::date_iso(s, day);
        let secs = local.rem_euclid(cal::SECS_PER_DAY);
        let _ = write!(s, "T{:02}:{:02}:{:02}", secs / 3600, (secs / 60) % 60, secs % 60);
        format::iso_offset(s, tt.off);
    });
    Ok(())
}

fn zone_diff(a: ZoneSel, b: ZoneSel, env: &Env, out: &mut Answer) -> Result<(), Problem> {
    out.kind = Kind::Text;
    let ta = env.at(a, env.now)?;
    let tb = env.at(b, env.now)?;
    let diff = ta.off - tb.off;
    let h = diff.unsigned_abs() / 3600;
    let m = (diff.unsigned_abs() % 3600) / 60;
    if diff == 0 {
        out.main.push_str("Same time");
    } else {
        if h > 0 {
            let _ = write!(out.main, "{h} hour{}", if h == 1 { "" } else { "s" });
        }
        if m > 0 {
            let _ = write!(out.main, "{}{m} minutes", if h > 0 { " " } else { "" });
        }
        out.main.push_str(if diff > 0 { " ahead" } else { " behind" });
    }
    let _ = write!(out.copy, "{}{}:{:02}", if diff < 0 { '-' } else { '+' }, h, m);
    let mut left = String::new();
    zone_name(&mut left, a, ta.abbr.as_str(), ta.off);
    let mut right = String::new();
    zone_name(&mut right, b, tb.abbr.as_str(), tb.off);
    let _ = write!(out.note, "{left} vs {right}");
    Ok(())
}

/// Adds an alternate form written by `f`.
fn alt(out: &mut Answer, label: &'static str, f: impl FnOnce(&mut String)) {
    if let Some(s) = out.next_alternate(label) {
        f(s);
        out.commit_alternate();
    }
}
