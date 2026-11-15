//! Values the parser computes with, and the arithmetic between them.
//!
//! Every value is `Copy` and lives on the stack. An error is a value too, so the parser can
//! finish reading the query and tell a calculation that fails from text that is not math.

use crate::answer::Problem;
use crate::cal;
use crate::context::Context;
use crate::currency::{Code, Rates};
use crate::num::{Num, NumError};
use crate::places::{self, ZONE_WORDS, ZoneWord};
use crate::tz::{Abbr, TType, Zone};
use crate::units::{self, Dim, FUEL, TIME, UnitRef};

/// Where a time is shown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ZoneSel {
    Local,
    /// A fixed offset in seconds east of UTC, named by an index into `ZONE_WORDS`, or unnamed
    /// for "utc+3".
    Fixed(i32, Option<u16>),
    /// A zone by id, reached through a place index when the user named a place.
    Tz(u16, Option<u16>),
}

/// A quantity: its value in SI base units, its dimension and the unit it is shown in.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Qty {
    pub base: Num,
    pub dim: Dim,
    pub unit: UnitRef,
    /// A second unit for mixed display, such as inches after feet.
    pub mixed: Option<UnitRef>,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum Val {
    Num(Num),
    /// A percentage as a fraction: 10% is 1/10.
    Pct(Num),
    Qty(Qty),
    Money(Num, Code),
    /// A calendar date as a day number.
    Date(i32),
    /// An instant in Unix seconds, shown in a zone.
    Moment(i64, ZoneSel),
    /// A wall-clock time in seconds after midnight, in a zone.
    Clock(i32, ZoneSel),
    /// The weekday of a date.
    Weekday(i32),
    /// How far zone `a` is ahead of zone `b`, at the current instant.
    ZoneDiff(ZoneSel, ZoneSel),
    Err(Problem),
}

impl From<NumError> for Problem {
    fn from(e: NumError) -> Problem {
        match e {
            NumError::DivisionByZero => Problem::DivisionByZero,
            NumError::Overflow => Problem::Overflow,
            NumError::Undefined => Problem::Undefined,
            NumError::NotReal => Problem::NotReal,
            NumError::NotWhole => Problem::NotWhole,
        }
    }
}

pub(crate) type VResult<T> = Result<T, Problem>;

/// The moment of evaluation and how to reach zone data.
pub(crate) struct Env<'a> {
    pub ctx: &'a Context<'a>,
    /// Now, in Unix seconds.
    pub now: i64,
    /// The local zone's rules, looked up on first use: most queries never need them.
    local: core::cell::OnceCell<Option<&'a Zone>>,
    /// Set when an exchange rate was used, so the answer can say how old the rates are.
    pub rates_used: core::cell::Cell<bool>,
}

impl<'a> Env<'a> {
    pub(crate) fn new(ctx: &'a Context<'a>) -> Env<'a> {
        let now = ctx.now_ms.div_euclid(1000);
        Env {
            ctx,
            now,
            local: core::cell::OnceCell::new(),
            rates_used: core::cell::Cell::new(false),
        }
    }

    fn local(&self) -> Option<&'a Zone> {
        let ctx = self.ctx;
        *self.local.get_or_init(|| {
            if ctx.local_zone.is_empty() {
                None
            } else {
                ctx.zones.and_then(|z| z.by_name(ctx.local_zone))
            }
        })
    }
    pub(crate) fn rates(&self) -> VResult<&'a Rates> {
        self.ctx.rates.ok_or(Problem::NoRates)
    }

    fn zone(&self, id: u16) -> VResult<&'a Zone> {
        let db = self.ctx.zones.ok_or(Problem::NoTimeZones)?;
        db.get(id).ok_or(Problem::UnknownZone)
    }

    /// The local time type of a zone at a UTC instant.
    pub(crate) fn at(&self, z: ZoneSel, utc: i64) -> VResult<TType> {
        Ok(match z {
            ZoneSel::Local => match self.local() {
                Some(zone) => zone.at(utc),
                None => TType {
                    off: self.ctx.local_offset_s,
                    abbr: Abbr::default(),
                },
            },
            ZoneSel::Fixed(off, name) => {
                let abbr = name
                    .and_then(|i| ZONE_WORDS.get(usize::from(i)))
                    .map(|(k, _)| *k)
                    .unwrap_or("");
                let mut upper = [0u8; 8];
                for (slot, c) in upper.iter_mut().zip(abbr.bytes()) {
                    *slot = c.to_ascii_uppercase();
                }
                let text = core::str::from_utf8(upper.get(..abbr.len().min(8)).unwrap_or(&[])).unwrap_or("");
                TType {
                    off,
                    abbr: Abbr::new(text),
                }
            }
            ZoneSel::Tz(id, _) => self.zone(id)?.at(utc),
        })
    }

    pub(crate) fn offset(&self, z: ZoneSel, utc: i64) -> VResult<i32> {
        Ok(self.at(z, utc)?.off)
    }

    /// The UTC instant of a wall-clock time in seconds in a zone.
    pub(crate) fn to_utc(&self, z: ZoneSel, local: i64) -> VResult<i64> {
        Ok(match z {
            ZoneSel::Local => match self.local() {
                Some(zone) => zone.to_utc(local),
                None => local - i64::from(self.ctx.local_offset_s),
            },
            ZoneSel::Fixed(off, _) => local - i64::from(off),
            ZoneSel::Tz(id, _) => self.zone(id)?.to_utc(local),
        })
    }

    /// Today's date in a zone.
    pub(crate) fn today_in(&self, z: ZoneSel) -> VResult<i32> {
        let off = self.offset(z, self.now)?;
        day_of(self.now + i64::from(off))
    }

    pub(crate) fn today(&self) -> i32 {
        self.today_in(ZoneSel::Local)
            .unwrap_or_else(|_| day_of(self.now).unwrap_or(0))
    }

    /// The instant of local midnight on a date.
    pub(crate) fn midnight(&self, day: i32) -> VResult<i64> {
        self.to_utc(ZoneSel::Local, i64::from(day) * cal::SECS_PER_DAY)
    }

    /// The instant a wall-clock time falls on today in its zone.
    pub(crate) fn anchor_clock(&self, secs: i32, z: ZoneSel) -> VResult<i64> {
        let day = self.today_in(z)?;
        self.to_utc(z, i64::from(day) * cal::SECS_PER_DAY + i64::from(secs))
    }
}

pub(crate) fn day_of(secs: i64) -> VResult<i32> {
    cal::valid_day(secs.div_euclid(cal::SECS_PER_DAY)).ok_or(Problem::InvalidDate)
}

/// The zone a place or zone word names.
pub(crate) fn zone_of_place(place: u16) -> Option<ZoneSel> {
    places::place(place).map(|p| ZoneSel::Tz(p.zone, Some(place)))
}

pub(crate) fn zone_of_word(i: u16) -> Option<ZoneSel> {
    match ZONE_WORDS.get(usize::from(i))?.1 {
        ZoneWord::Fixed(off) => Some(ZoneSel::Fixed(off, Some(i))),
        ZoneWord::Iana(name) => places::zone_id(name).map(|id| ZoneSel::Tz(id, None)),
    }
}

impl Qty {
    pub(crate) fn new(v: Num, unit: UnitRef) -> VResult<Qty> {
        Ok(Qty {
            base: unit.to_base(v)?,
            dim: unit.dim(),
            unit,
            mixed: None,
        })
    }

    /// The value in the display unit.
    pub(crate) fn value(&self) -> VResult<Num> {
        Ok(self.unit.of_base(self.base)?)
    }

    /// The value as a difference in its display unit: no temperature offset.
    fn delta(&self) -> VResult<Num> {
        Ok(self.base.sub(self.unit.offset())?)
    }
}

/// Converts a quantity to another unit, by reciprocal for fuel economy.
pub(crate) fn convert(q: Qty, to: UnitRef) -> VResult<Qty> {
    if q.dim == to.dim() {
        return Ok(Qty {
            unit: to,
            mixed: None,
            ..q
        });
    }
    let fuel = q.unit.flags() & FUEL != 0 && to.flags() & FUEL != 0;
    if fuel && q.dim.neg() == Some(to.dim()) {
        let v = q.base.recip()?;
        return Ok(Qty {
            base: v,
            dim: to.dim(),
            unit: to,
            mixed: None,
        });
    }
    Err(Problem::IncompatibleUnits)
}

fn scale(v: Val, k: Num) -> VResult<Val> {
    Ok(match v {
        Val::Num(n) => Val::Num(n.mul(k)?),
        Val::Pct(n) => Val::Pct(n.mul(k)?),
        Val::Qty(q) => {
            if q.unit.is_temperature() {
                let d = q.delta()?.mul(k)?;
                Val::Qty(Qty {
                    base: d.add(q.unit.offset())?,
                    ..q
                })
            } else {
                Val::Qty(Qty {
                    base: q.base.mul(k)?,
                    ..q
                })
            }
        }
        Val::Money(n, c) => Val::Money(n.mul(k)?, c),
        _ => return Err(Problem::Unsupported),
    })
}

/// Unwraps an error value so callers can use `?`.
pub(crate) fn ok(v: Val) -> VResult<Val> {
    if let Val::Err(p) = v { Err(p) } else { Ok(v) }
}

fn money_to(env: &Env, n: Num, from: Code, to: Code) -> VResult<Num> {
    if from == to {
        return Ok(n);
    }
    let rates = env.rates()?;
    let f = rates.factor(from, to).ok_or(Problem::NoRate)?;
    env.rates_used.set(true);
    Ok(n.mul(Num::float(f)?)?)
}

/// `a + b` or `a - b`.
pub(crate) fn add(env: &Env, a: Val, b: Val, sign: i8) -> VResult<Val> {
    let a = ok(a)?;
    let b = ok(b)?;
    let signed = |n: Num| if sign < 0 { n.neg() } else { n };
    Ok(match (a, b) {
        (Val::Num(x), Val::Num(y)) => Val::Num(x.add(signed(y))?),
        (Val::Pct(x), Val::Pct(y)) => Val::Pct(x.add(signed(y))?),
        // 50 + 10% is 55.
        (x @ (Val::Num(_) | Val::Qty(_) | Val::Money(..)), Val::Pct(p)) => scale(x, Num::ONE.add(signed(p))?)?,
        (Val::Qty(x), Val::Qty(y)) => {
            if x.dim != y.dim {
                return Err(Problem::IncompatibleUnits);
            }
            // Temperatures: the right side counts as a difference.
            let d = if y.unit.is_temperature() { y.delta()? } else { y.base };
            let base = x.base.add(signed(d))?;
            let mixed = x.mixed.or(y.mixed).or(if x.unit != y.unit && x.dim == TIME {
                Some(y.unit)
            } else {
                None
            });
            Val::Qty(Qty {
                base,
                mixed: if x.dim == TIME { mixed } else { x.mixed },
                ..x
            })
        }
        // 5 km + 3 is 8 km.
        (Val::Qty(x), Val::Num(y)) => {
            let v = x.value()?.add(signed(y))?;
            Val::Qty(Qty {
                base: x.unit.to_base(v)?,
                ..x
            })
        }
        (Val::Money(x, c), Val::Money(y, d)) => Val::Money(x.add(signed(money_to(env, y, d, c)?))?, c),
        (Val::Money(x, c), Val::Num(y)) => Val::Money(x.add(signed(y))?, c),
        (Val::Num(x), Val::Money(y, c)) if sign > 0 => Val::Money(x.add(y)?, c),
        (Val::Date(d), Val::Qty(q)) if q.dim == TIME => shift_date(env, d, q, sign)?,
        (Val::Qty(q), Val::Date(d)) if q.dim == TIME && sign > 0 => shift_date(env, d, q, 1)?,
        (Val::Moment(t, z), Val::Qty(q)) if q.dim == TIME => Val::Moment(shift_moment(env, t, z, q, sign)?, z),
        (Val::Clock(s, z), Val::Qty(q)) if q.dim == TIME => {
            let t = env.anchor_clock(s, z)?;
            Val::Moment(shift_moment(env, t, z, q, sign)?, z)
        }
        (Val::Date(x), Val::Date(y)) if sign < 0 => days_qty(i64::from(x) - i64::from(y))?,
        (Val::Moment(x, _), Val::Moment(y, _)) if sign < 0 => secs_qty(x - y)?,
        (Val::Moment(x, _), Val::Date(y)) if sign < 0 => secs_qty(x - env.midnight(y)?)?,
        (Val::Date(x), Val::Moment(y, _)) if sign < 0 => secs_qty(env.midnight(x)? - y)?,
        (Val::Clock(x, zx), Val::Clock(y, zy)) if sign < 0 => {
            secs_qty(env.anchor_clock(x, zx)? - env.anchor_clock(y, zy)?)?
        }
        (Val::Moment(x, _), Val::Clock(s, z)) if sign < 0 => secs_qty(x - env.anchor_clock(s, z)?)?,
        (Val::Clock(s, z), Val::Moment(y, _)) if sign < 0 => secs_qty(env.anchor_clock(s, z)? - y)?,
        _ => return Err(Problem::IncompatibleUnits),
    })
}

pub(crate) fn days_qty(days: i64) -> VResult<Val> {
    let u = units::by_sym("d").ok_or(Problem::Unsupported)?;
    Ok(Val::Qty(Qty::new(Num::int(i128::from(days)), u)?))
}

pub(crate) fn secs_qty(secs: i64) -> VResult<Val> {
    let s = units::by_sym("s").ok_or(Problem::Unsupported)?;
    let mut q = Qty::new(Num::int(i128::from(secs)), s)?;
    // Shown as "3 h 15 min"; the display picks the units.
    q.unit = pick_duration_unit(secs.unsigned_abs());
    q.mixed = Some(s);
    Ok(Val::Qty(q))
}

fn pick_duration_unit(secs: u64) -> UnitRef {
    let sym = if secs >= 86_400 {
        "d"
    } else if secs >= 3600 {
        "h"
    } else if secs >= 60 {
        "min"
    } else {
        "s"
    };
    units::by_sym(sym).unwrap_or(UnitRef::new(0))
}

/// Date plus a duration: calendar months for months and years, days when whole, else a moment.
fn shift_date(env: &Env, d: i32, q: Qty, sign: i8) -> VResult<Val> {
    let months = q.unit.months();
    if months > 0 && q.mixed.is_none() {
        let v = q.value()?;
        if let Some(n) = v.as_exact_int() {
            let total = i64::try_from(n)
                .map_err(|_| Problem::Overflow)?
                .saturating_mul(i64::from(months));
            let total = if sign < 0 { -total } else { total };
            return cal::add_months(d, total).map(Val::Date).ok_or(Problem::InvalidDate);
        }
    }
    let secs = q.base;
    let day = Num::int(i128::from(cal::SECS_PER_DAY));
    let days = secs.div(day)?;
    if let Some(n) = days.as_exact_int() {
        let n = i64::try_from(n).map_err(|_| Problem::InvalidDate)?;
        let n = if sign < 0 { -n } else { n };
        return cal::valid_day(i64::from(d) + n)
            .map(Val::Date)
            .ok_or(Problem::InvalidDate);
    }
    let t = env.midnight(d)?;
    Ok(Val::Moment(
        shift_moment(env, t, ZoneSel::Local, q, sign)?,
        ZoneSel::Local,
    ))
}

fn shift_moment(env: &Env, t: i64, z: ZoneSel, q: Qty, sign: i8) -> VResult<i64> {
    let months = q.unit.months();
    if months > 0
        && q.mixed.is_none()
        && let Some(n) = q.value()?.as_exact_int()
    {
        let total = i64::try_from(n)
            .map_err(|_| Problem::Overflow)?
            .saturating_mul(i64::from(months));
        let total = if sign < 0 { -total } else { total };
        let off = i64::from(env.offset(z, t)?);
        let local = t + off;
        let day = day_of(local)?;
        let secs = local.rem_euclid(cal::SECS_PER_DAY);
        let nd = cal::add_months(day, total).ok_or(Problem::InvalidDate)?;
        return env.to_utc(z, i64::from(nd) * cal::SECS_PER_DAY + secs);
    }
    let secs = q.base.to_f64().round();
    if !secs.is_finite() || secs.abs() > 3.0e11 {
        return Err(Problem::InvalidDate);
    }
    let s = secs as i64;
    let r = if sign < 0 { t - s } else { t + s };
    day_of(r)?;
    Ok(r)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MulOp {
    Mul,
    Div,
}

pub(crate) fn mul(a: Val, b: Val, op: MulOp) -> VResult<Val> {
    let a = ok(a)?;
    let b = ok(b)?;
    let combine = |x: Num, y: Num| -> VResult<Num> {
        Ok(match op {
            MulOp::Mul => x.mul(y)?,
            MulOp::Div => x.div(y)?,
        })
    };
    Ok(match (a, b) {
        (Val::Num(x), Val::Num(y)) => Val::Num(combine(x, y)?),
        (Val::Pct(x), Val::Pct(y)) => Val::Pct(combine(x, y)?),
        (Val::Num(x), Val::Pct(p)) => Val::Num(combine(x, p)?),
        (Val::Pct(p), Val::Num(x)) => Val::Num(combine(p, x)?),
        (x @ (Val::Qty(_) | Val::Money(..)), Val::Num(y)) => scale(x, if op == MulOp::Mul { y } else { y.recip()? })?,
        (x @ (Val::Qty(_) | Val::Money(..)), Val::Pct(y)) => scale(x, if op == MulOp::Mul { y } else { y.recip()? })?,
        (Val::Num(x), y @ (Val::Qty(_) | Val::Money(..))) if op == MulOp::Mul => scale(y, x)?,
        (Val::Pct(x), y @ (Val::Qty(_) | Val::Money(..))) if op == MulOp::Mul => scale(y, x)?,
        (Val::Money(x, c), Val::Money(y, d)) if op == MulOp::Div && c == d => Val::Num(x.div(y)?),
        (Val::Qty(x), Val::Qty(y)) => qty_product(x, y, op)?,
        (Val::Num(x), Val::Qty(y)) if op == MulOp::Div => {
            // 1 / 2 s is a frequency; only for dimensions the table can show.
            let dim = Dim::NONE.sub(y.dim).ok_or(Problem::Overflow)?;
            let u = units::default_for(dim).ok_or(Problem::Unsupported)?;
            Val::Qty(Qty {
                base: x.div(y.base)?,
                dim,
                unit: u,
                mixed: None,
            })
        }
        _ => return Err(Problem::IncompatibleUnits),
    })
}

fn qty_product(x: Qty, y: Qty, op: MulOp) -> VResult<Val> {
    if x.unit.is_temperature() || y.unit.is_temperature() {
        return Err(Problem::Unsupported);
    }
    let (dim, base) = match op {
        MulOp::Mul => (x.dim.add(y.dim).ok_or(Problem::Overflow)?, x.base.mul(y.base)?),
        MulOp::Div => (x.dim.sub(y.dim).ok_or(Problem::Overflow)?, x.base.div(y.base)?),
    };
    if dim == Dim::NONE {
        return Ok(Val::Num(base));
    }
    // Prefer a unit made of the operands' units: km / h is km/h, ft * ft is ft².
    let factor = match op {
        MulOp::Mul => x.unit.factor()?.mul(y.unit.factor()?)?,
        MulOp::Div => x.unit.factor()?.div(y.unit.factor()?)?,
    };
    let unit = units::with_factor(dim, factor)
        .or_else(|| units::default_for(dim))
        .ok_or(Problem::Unsupported)?;
    Ok(Val::Qty(Qty {
        base,
        dim,
        unit,
        mixed: None,
    }))
}

pub(crate) fn pow(a: Val, b: Val) -> VResult<Val> {
    let a = ok(a)?;
    let b = ok(b)?;
    Ok(match (a, b) {
        (Val::Num(x), Val::Num(y)) => Val::Num(x.pow(y)?),
        (Val::Qty(q), Val::Num(y)) if !q.unit.is_temperature() => {
            let k = y
                .as_exact_int()
                .and_then(|k| i8::try_from(k).ok())
                .ok_or(Problem::Unsupported)?;
            let dim = q.dim.scale(k).ok_or(Problem::Overflow)?;
            if dim == Dim::NONE {
                return Ok(Val::Num(Num::ONE));
            }
            let factor = q.unit.factor()?.powi(i128::from(k))?;
            let unit = units::with_factor(dim, factor)
                .or_else(|| units::default_for(dim))
                .ok_or(Problem::Unsupported)?;
            Val::Qty(Qty {
                base: q.base.powi(i128::from(k))?,
                dim,
                unit,
                mixed: None,
            })
        }
        _ => return Err(Problem::Unsupported),
    })
}

pub(crate) fn neg(v: Val) -> VResult<Val> {
    Ok(match ok(v)? {
        Val::Num(n) => Val::Num(n.neg()),
        Val::Pct(n) => Val::Pct(n.neg()),
        Val::Money(n, c) => Val::Money(n.neg(), c),
        Val::Qty(q) => {
            let v = q.value()?.neg();
            Val::Qty(Qty {
                base: q.unit.to_base(v)?,
                ..q
            })
        }
        _ => return Err(Problem::Unsupported),
    })
}

/// The plain number inside a value, for functions that take numbers.
pub(crate) fn number(v: Val) -> VResult<Num> {
    match ok(v)? {
        Val::Num(n) => Ok(n),
        Val::Pct(n) => Ok(n),
        _ => Err(Problem::Unsupported),
    }
}

/// Applies a numeric function to a number, or to a quantity or amount in its own unit.
pub(crate) fn map_num(v: Val, f: impl Fn(Num) -> VResult<Num>) -> VResult<Val> {
    Ok(match ok(v)? {
        Val::Num(n) => Val::Num(f(n)?),
        Val::Pct(n) => Val::Pct(f(n)?),
        Val::Money(n, c) => Val::Money(f(n)?, c),
        Val::Qty(q) => {
            let v = f(q.value()?)?;
            Val::Qty(Qty {
                base: q.unit.to_base(v)?,
                ..q
            })
        }
        _ => return Err(Problem::Unsupported),
    })
}

/// Orders two values of the same kind, for min and max.
pub(crate) fn compare(env: &Env, a: Val, b: Val) -> VResult<core::cmp::Ordering> {
    Ok(match (ok(a)?, ok(b)?) {
        (Val::Num(x), Val::Num(y)) | (Val::Pct(x), Val::Pct(y)) => x.cmp(y),
        (Val::Qty(x), Val::Qty(y)) if x.dim == y.dim => x.base.cmp(y.base),
        (Val::Money(x, c), Val::Money(y, d)) => x.cmp(money_to(env, y, d, c)?),
        _ => return Err(Problem::IncompatibleUnits),
    })
}

/// Converts money to another currency.
pub(crate) fn exchange(env: &Env, n: Num, from: Code, to: Code) -> VResult<Num> {
    money_to(env, n, from, to)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temperature_sums_treat_the_right_side_as_a_difference() {
        let ctx = Context::new(0);
        let env = Env::new(&ctx);
        let c = units::by_sym("°C").unwrap_or(UnitRef::new(0));
        let a = Val::Qty(Qty::new(Num::int(20), c).unwrap_or(Qty {
            base: Num::ZERO,
            dim: Dim::NONE,
            unit: c,
            mixed: None,
        }));
        let b = Val::Qty(Qty::new(Num::int(5), c).unwrap_or(Qty {
            base: Num::ZERO,
            dim: Dim::NONE,
            unit: c,
            mixed: None,
        }));
        let Ok(Val::Qty(sum)) = add(&env, a, b, 1) else {
            panic!("not a quantity")
        };
        assert!(sum.value().is_ok_and(|v| v.cmp(Num::int(25)).is_eq()));
    }
}
