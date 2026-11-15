//! Turns numbers, dates and times into text. Writes into caller strings; no locale logic beyond
//! the separators and orders in the context.

use crate::cal;
use crate::context::{Context, DateOrder, HourCycle};
use crate::num::Num;
use core::fmt::Write as _;

const MAX_DIGITS: usize = 64;

/// Decimal digits of a number: value = 0.d1 d2 d3 ... times 10^point.
#[derive(Clone, Copy)]
pub(crate) struct Digits {
    neg: bool,
    d: [u8; MAX_DIGITS],
    n: usize,
    point: i32,
    /// True when the digits are the whole value, not a rounded prefix.
    exact: bool,
}

impl Digits {
    fn zero() -> Digits {
        Digits {
            neg: false,
            d: [0; MAX_DIGITS],
            n: 0,
            point: 0,
            exact: true,
        }
    }

    fn push(&mut self, digit: u8) -> bool {
        match self.d.get_mut(self.n) {
            Some(slot) => {
                *slot = digit;
                self.n += 1;
                true
            }
            None => false,
        }
    }

    fn digit(&self, i: usize) -> u8 {
        self.d.get(i).copied().unwrap_or(0)
    }

    pub(crate) fn of(n: Num) -> Digits {
        match n {
            Num::Ratio(a, b) => Digits::of_ratio(a, b).unwrap_or_else(|| Digits::of_f64(n.to_f64())),
            Num::Float(x) => Digits::of_f64(x),
        }
    }

    fn of_ratio(a: i128, b: i128) -> Option<Digits> {
        let mut out = Digits::zero();
        out.neg = a < 0;
        let a = a.unsigned_abs();
        let b = u128::try_from(b).ok().filter(|&b| b > 0)?;
        let ip = a / b;
        let mut r = a % b;
        if ip > 0 {
            let mut tmp = [0u8; 40];
            let mut k = 0;
            let mut v = ip;
            while v > 0 {
                *tmp.get_mut(k)? = (v % 10) as u8;
                v /= 10;
                k += 1;
            }
            for i in (0..k).rev() {
                out.push(*tmp.get(i)?);
            }
            out.point = k as i32;
        }
        while r != 0 && out.n < MAX_DIGITS {
            r = r.checked_mul(10)?;
            let digit = (r / b) as u8;
            r %= b;
            if out.n == 0 && digit == 0 {
                out.point -= 1;
                if out.point < -400 {
                    return None;
                }
            } else {
                out.push(digit);
            }
        }
        out.exact = r == 0;
        out.trim_trailing_zeros();
        Some(out)
    }

    fn of_f64(x: f64) -> Digits {
        let mut out = Digits::zero();
        if x == 0.0 || !x.is_finite() {
            return out;
        }
        out.neg = x < 0.0;
        out.exact = false;
        let mut buf = StackBuf::<40>::new();
        let _ = write!(buf, "{:.16e}", x.abs());
        let s = buf.as_str();
        let (mant, exp) = s.split_once('e').unwrap_or((s, "0"));
        for c in mant.bytes().filter(u8::is_ascii_digit) {
            out.push(c - b'0');
        }
        out.point = exp.parse::<i32>().unwrap_or(0) + 1;
        out.trim_trailing_zeros();
        out
    }

    fn trim_trailing_zeros(&mut self) {
        while self.n > 0 && self.digit(self.n - 1) == 0 {
            self.n -= 1;
        }
        if self.n == 0 {
            self.point = 0;
            self.neg = false;
        }
    }

    pub(crate) fn is_zero(&self) -> bool {
        self.n == 0
    }

    /// Keeps `keep` leading digits, rounding half away from zero.
    fn round_at(&mut self, keep: i64) {
        if keep < 0 {
            *self = Digits::zero();
            return;
        }
        let keep = keep as usize;
        if keep >= self.n {
            return;
        }
        let up = self.digit(keep) >= 5;
        self.n = keep;
        self.exact = false;
        if up {
            let mut i = keep;
            loop {
                if i == 0 {
                    // 999 rounds to 1000.
                    let mut d = Digits::zero();
                    d.neg = self.neg;
                    d.push(1);
                    d.point = self.point + 1;
                    *self = d;
                    break;
                }
                i -= 1;
                let v = self.digit(i);
                if v < 9 {
                    if let Some(slot) = self.d.get_mut(i) {
                        *slot = v + 1;
                    }
                    break;
                }
                self.n = i;
            }
        }
        self.trim_trailing_zeros();
    }

    pub(crate) fn round_sig(&mut self, sig: usize) {
        self.round_at(sig as i64);
    }

    pub(crate) fn round_frac(&mut self, frac: usize) {
        self.round_at(i64::from(self.point) + frac as i64);
    }

    fn frac_len(&self) -> usize {
        (self.n as i64 - i64::from(self.point)).max(0) as usize
    }

    pub(crate) fn is_integer(&self) -> bool {
        self.frac_len() == 0
    }
}

/// A fixed-size string buffer on the stack.
pub(crate) struct StackBuf<const N: usize> {
    b: [u8; N],
    n: usize,
}

impl<const N: usize> StackBuf<N> {
    pub(crate) fn new() -> StackBuf<N> {
        StackBuf { b: [0; N], n: 0 }
    }

    pub(crate) fn as_str(&self) -> &str {
        core::str::from_utf8(self.b.get(..self.n).unwrap_or(&[])).unwrap_or("")
    }
}

impl<const N: usize> core::fmt::Write for StackBuf<N> {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        let bytes = s.as_bytes();
        let end = self.n + bytes.len();
        let slot = self.b.get_mut(self.n..end).ok_or(core::fmt::Error)?;
        slot.copy_from_slice(bytes);
        self.n = end;
        Ok(())
    }
}

/// How a number is laid out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Style {
    /// Arithmetic answers: 12 significant digits.
    Number,
    /// Unit conversions: 6 significant digits unless the exact value is short.
    Unit,
    /// Money with this many decimals.
    Money(u8),
    /// The value to copy: 15 significant digits, no grouping.
    Copy,
    /// Integers that should never be grouped, such as Unix timestamps.
    Plain,
}

pub(crate) struct Seps {
    pub decimal: char,
    pub grouping: Option<char>,
}

impl Seps {
    pub(crate) fn of(ctx: &Context) -> Seps {
        Seps {
            decimal: ctx.decimal,
            grouping: ctx.grouping,
        }
    }
}

fn superscript(out: &mut String, v: i32) {
    if v < 0 {
        out.push('⁻');
    }
    let mut buf = StackBuf::<12>::new();
    let _ = write!(buf, "{}", v.unsigned_abs());
    for c in buf.as_str().chars() {
        out.push(match c {
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

/// Writes a number.
pub(crate) fn number(out: &mut String, n: Num, style: Style, seps: &Seps) {
    let mut d = Digits::of(n);
    let exact_int = d.exact && d.is_integer() && n.is_exact();
    match style {
        Style::Number | Style::Copy => {
            let keep = if style == Style::Copy {
                15
            } else if d.point > 21 {
                12
            } else {
                (d.point.clamp(0, 15) as usize).max(12)
            };
            if !(d.exact && (d.is_integer() || d.n <= 15)) {
                d.round_sig(keep);
            }
        }
        Style::Unit => {
            // Six significant digits, but never fewer than the integer part: a light year is
            // 9,460,730,472,581 km, not 9,460,730,000,000 km.
            let keep = if d.point > 21 {
                6
            } else {
                (d.point.clamp(0, 15) as usize).max(6)
            };
            if !(d.exact && d.n <= 10) {
                d.round_sig(keep);
            }
        }
        Style::Money(places) => {
            let before = d;
            d.round_frac(usize::from(places));
            if d.is_zero() && !before.is_zero() {
                d = before;
                d.round_sig(4);
            }
        }
        Style::Plain => {
            d.round_frac(0);
        }
    }
    let grouping = if matches!(style, Style::Copy | Style::Plain) {
        None
    } else {
        seps.grouping
    };
    // Scientific notation outside the readable range, except for exact integers.
    let sci = !d.is_zero() && (d.point > 21 || d.point < -6) && style != Style::Plain;
    if sci && exact_int {
        d.round_sig(if style == Style::Copy { 15 } else { 12 });
    }
    if d.neg {
        out.push('-');
    }
    if sci {
        let exp = d.point - 1;
        let mut m = d;
        m.point = 1;
        m.neg = false;
        write_positional(out, &m, seps.decimal, None, 0);
        if style == Style::Copy {
            let _ = write!(out, "e{exp}");
        } else {
            out.push_str(" × 10");
            superscript(out, exp);
        }
        return;
    }
    let min_frac = if let Style::Money(p) = style { usize::from(p) } else { 0 };
    // Money: no ".00" padding when the amount is whole and has no cents to show.
    let min_frac = if min_frac > 0 && d.is_integer() { 0 } else { min_frac };
    write_positional(out, &d, seps.decimal, grouping, min_frac);
}

fn write_positional(out: &mut String, d: &Digits, decimal: char, grouping: Option<char>, min_frac: usize) {
    if d.is_zero() {
        out.push('0');
        if min_frac > 0 {
            out.push(decimal);
            for _ in 0..min_frac {
                out.push('0');
            }
        }
        return;
    }
    let int_len = d.point.max(0) as usize;
    if int_len == 0 {
        out.push('0');
    }
    for i in 0..int_len {
        if i > 0
            && (int_len - i).is_multiple_of(3)
            && int_len > 3
            && let Some(g) = grouping
        {
            out.push(g);
        }
        let digit = if i < d.n { d.digit(i) } else { 0 };
        out.push(char::from(b'0' + digit));
    }
    let frac = d.frac_len();
    if frac > 0 || min_frac > 0 {
        out.push(decimal);
        let lead = (-d.point).max(0) as usize;
        for _ in 0..lead {
            out.push('0');
        }
        let start = d.point.max(0) as usize;
        for i in start..d.n {
            out.push(char::from(b'0' + d.digit(i)));
        }
        for _ in frac..min_frac {
            out.push('0');
        }
    }
}

/// True when the number shows as exactly 1, so unit names stay singular.
pub(crate) fn is_one(n: Num, style: Style) -> bool {
    let mut s = String::new();
    number(
        &mut s,
        n.abs(),
        style,
        &Seps {
            decimal: '.',
            grouping: None,
        },
    );
    s == "1"
}

const ONES: [&str; 20] = [
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
];
const TENS: [&str; 10] = [
    "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
];
const SCALES: [&str; 12] = [
    "",
    "thousand",
    "million",
    "billion",
    "trillion",
    "quadrillion",
    "quintillion",
    "sextillion",
    "septillion",
    "octillion",
    "nonillion",
    "decillion",
];

fn words_below_1000(out: &mut String, v: u32) {
    let h = v / 100;
    let r = v % 100;
    if h > 0 {
        out.push_str(ONES.get(h as usize).copied().unwrap_or(""));
        out.push_str(" hundred");
        if r > 0 {
            out.push(' ');
        }
    }
    if r >= 20 {
        out.push_str(TENS.get((r / 10) as usize).copied().unwrap_or(""));
        if !r.is_multiple_of(10) {
            out.push('-');
            out.push_str(ONES.get((r % 10) as usize).copied().unwrap_or(""));
        }
    } else if r > 0 || h == 0 {
        out.push_str(ONES.get(r as usize).copied().unwrap_or(""));
    }
}

/// English words for a number: "one thousand two hundred thirty-four point five".
pub(crate) fn words(out: &mut String, n: Num) -> bool {
    let mut d = Digits::of(n);
    if !(d.exact && d.n <= 15) {
        d.round_sig(12);
    }
    if d.point > 36 {
        return false;
    }
    if d.neg {
        out.push_str("minus ");
    }
    // Integer part from the digits.
    let int_len = d.point.max(0) as usize;
    let mut int: u128 = 0;
    for i in 0..int_len {
        let digit = if i < d.n { d.digit(i) } else { 0 };
        int = int.saturating_mul(10).saturating_add(u128::from(digit));
    }
    if int == 0 {
        out.push_str("zero");
    } else {
        let mut groups = [0u32; 13];
        let mut k = 0;
        let mut v = int;
        while v > 0 && k < groups.len() {
            if let Some(g) = groups.get_mut(k) {
                *g = (v % 1000) as u32;
            }
            v /= 1000;
            k += 1;
        }
        let mut first = true;
        for i in (0..k).rev() {
            let g = groups.get(i).copied().unwrap_or(0);
            if g == 0 {
                continue;
            }
            if !first {
                out.push(' ');
            }
            first = false;
            words_below_1000(out, g);
            if i > 0 {
                out.push(' ');
                out.push_str(SCALES.get(i).copied().unwrap_or(""));
            }
        }
    }
    let frac = d.frac_len();
    if frac > 0 {
        out.push_str(" point");
        let lead = (-d.point).max(0) as usize;
        for _ in 0..lead {
            out.push_str(" zero");
        }
        for i in d.point.max(0) as usize..d.n {
            out.push(' ');
            out.push_str(ONES.get(usize::from(d.digit(i))).copied().unwrap_or(""));
        }
    }
    true
}

/// A simple fraction for a number, with a denominator up to 10,000: "3/4". Mixed numbers put the
/// whole part first: "1 3/4".
pub(crate) fn fraction(out: &mut String, n: Num, mixed: bool) -> bool {
    let Some((p, q)) = as_fraction(n) else { return false };
    if q == 1 {
        let _ = write!(out, "{p}");
        return true;
    }
    if mixed && p.abs() > q {
        let whole = p / q;
        let rest = (p % q).abs();
        let _ = write!(out, "{whole} {rest}/{q}");
    } else {
        let _ = write!(out, "{p}/{q}");
    }
    true
}

pub(crate) fn as_fraction(n: Num) -> Option<(i128, i128)> {
    match n {
        Num::Ratio(p, q) if q <= 10_000 => Some((p, q)),
        Num::Ratio(..) => None,
        Num::Float(x) => {
            // Continued fraction with a bounded denominator.
            let (mut h0, mut h1, mut k0, mut k1) = (0i128, 1i128, 1i128, 0i128);
            let mut v = x.abs();
            for _ in 0..40 {
                let a = v.floor();
                if a > 1e15 {
                    return None;
                }
                let a_i = a as i128;
                let h2 = a_i.checked_mul(h1)?.checked_add(h0)?;
                let k2 = a_i.checked_mul(k1)?.checked_add(k0)?;
                if k2 > 10_000 {
                    break;
                }
                (h0, h1, k0, k1) = (h1, h2, k1, k2);
                if k1 != 0 && ((h1 as f64 / k1 as f64) - x.abs()).abs() <= 1e-12 * x.abs().max(1.0) {
                    let sign = if x < 0.0 { -1 } else { 1 };
                    return Some((sign * h1, k1));
                }
                let f = v - a;
                if f < 1e-15 {
                    break;
                }
                v = 1.0 / f;
            }
            None
        }
    }
}

/// An integer in another base: "0xFF", "0b1010", "0o17", or digits with the base after them.
pub(crate) fn radix(out: &mut String, n: Num, base: u32, group: bool) -> bool {
    let Some(v) = n.as_int() else { return false };
    if !(2..=36).contains(&base) {
        return false;
    }
    if v < 0 {
        out.push('-');
    }
    match base {
        16 => out.push_str("0x"),
        2 => out.push_str("0b"),
        8 => out.push_str("0o"),
        _ => {}
    }
    let mut digits = [0u8; 130];
    let mut k = 0;
    let mut u = v.unsigned_abs();
    loop {
        let d = (u % u128::from(base)) as u32;
        if let Some(slot) = digits.get_mut(k) {
            *slot = char::from_digit(d, base).map_or(b'0', |c| c.to_ascii_uppercase() as u8);
        }
        k += 1;
        u /= u128::from(base);
        if u == 0 || k >= digits.len() {
            break;
        }
    }
    for i in (0..k).rev() {
        out.push(char::from(digits.get(i).copied().unwrap_or(b'0')));
        if group && base == 2 && i > 0 && i % 4 == 0 && k > 8 {
            out.push(' ');
        }
    }
    true
}

const MONTH_SHORT: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const WEEKDAY_SHORT: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// "Friday, 25 December 2026" in the caller's order.
pub(crate) fn date_long(out: &mut String, day: i32, order: DateOrder) {
    let (y, m, d) = cal::ymd(day);
    let wd = cal::WEEKDAYS.get(cal::weekday(day) as usize).copied().unwrap_or("");
    let month = cal::MONTHS.get((m - 1) as usize).copied().unwrap_or("");
    let _ = match order {
        DateOrder::DayMonthYear => write!(out, "{wd}, {d} {month} {y}"),
        DateOrder::MonthDayYear => write!(out, "{wd}, {month} {d}, {y}"),
        DateOrder::YearMonthDay => write!(out, "{wd}, {y} {month} {d}"),
    };
}

/// "Mon 16 Nov", with the year when it is not `this_year`.
pub(crate) fn date_short(out: &mut String, day: i32, order: DateOrder, this_year: i32) {
    let (y, m, d) = cal::ymd(day);
    let wd = WEEKDAY_SHORT.get(cal::weekday(day) as usize).copied().unwrap_or("");
    let month = MONTH_SHORT.get((m - 1) as usize).copied().unwrap_or("");
    let _ = match order {
        DateOrder::DayMonthYear => write!(out, "{wd} {d} {month}"),
        DateOrder::MonthDayYear => write!(out, "{wd} {month} {d}"),
        DateOrder::YearMonthDay => write!(out, "{wd} {m:02}-{d:02}"),
    };
    if y != this_year {
        let _ = match order {
            DateOrder::MonthDayYear => write!(out, ", {y}"),
            DateOrder::YearMonthDay => write!(out, " {y}"),
            DateOrder::DayMonthYear => write!(out, " {y}"),
        };
    }
}

pub(crate) fn date_iso(out: &mut String, day: i32) {
    let (y, m, d) = cal::ymd(day);
    let _ = write!(out, "{y:04}-{m:02}-{d:02}");
}

/// "3:05 PM" or "15:05", with seconds when they are not zero.
pub(crate) fn clock(out: &mut String, secs_of_day: i64, cycle: HourCycle) {
    let s = secs_of_day.rem_euclid(cal::SECS_PER_DAY);
    let (h, m, sec) = (s / 3600, (s / 60) % 60, s % 60);
    match cycle {
        HourCycle::H24 => {
            let _ = write!(out, "{h:02}:{m:02}");
            if sec != 0 {
                let _ = write!(out, ":{sec:02}");
            }
        }
        HourCycle::H12 => {
            let h12 = if h % 12 == 0 { 12 } else { h % 12 };
            let _ = write!(out, "{h12}:{m:02}");
            if sec != 0 {
                let _ = write!(out, ":{sec:02}");
            }
            out.push_str(if h < 12 { " AM" } else { " PM" });
        }
    }
}

/// "UTC+9", "UTC-3:30", "UTC+0".
pub(crate) fn utc_offset(out: &mut String, off: i32) {
    out.push_str("UTC");
    out.push(if off < 0 { '-' } else { '+' });
    let a = off.unsigned_abs();
    let _ = write!(out, "{}", a / 3600);
    if !a.is_multiple_of(3600) {
        let _ = write!(out, ":{:02}", (a % 3600) / 60);
    }
}

/// "+09:00" for ISO 8601.
pub(crate) fn iso_offset(out: &mut String, off: i32) {
    if off == 0 {
        out.push('Z');
        return;
    }
    let a = off.unsigned_abs();
    let _ = write!(
        out,
        "{}{:02}:{:02}",
        if off < 0 { '-' } else { '+' },
        a / 3600,
        (a % 3600) / 60
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fmt(n: Num, style: Style) -> String {
        let mut s = String::new();
        number(
            &mut s,
            n,
            style,
            &Seps {
                decimal: '.',
                grouping: Some(','),
            },
        );
        s
    }

    fn r(a: i128, b: i128) -> Num {
        Num::ratio(a, b).unwrap_or(Num::ZERO)
    }

    #[test]
    fn numbers() {
        assert_eq!(fmt(r(3, 10), Style::Number), "0.3");
        assert_eq!(fmt(r(1, 3), Style::Number), "0.333333333333");
        assert_eq!(fmt(r(2, 3), Style::Number), "0.666666666667");
        assert_eq!(fmt(Num::int(1_234_567), Style::Number), "1,234,567");
        assert_eq!(fmt(Num::int(-1000), Style::Number), "-1,000");
        assert_eq!(fmt(Num::Float(core::f64::consts::PI), Style::Number), "3.14159265359");
        assert_eq!(fmt(Num::Float(1e25), Style::Number), "1 × 10²⁵");
        assert_eq!(fmt(Num::Float(1.5e-9), Style::Copy), "1.5e-9");
        assert_eq!(fmt(r(2_000_000, 3), Style::Unit), "666,667");
        assert_eq!(fmt(r(1, 3), Style::Unit), "0.333333");
        assert_eq!(fmt(r(999_999_999, 1_000_000), Style::Unit), "999.999999");
        assert_eq!(fmt(r(1_609_344, 1_000_000), Style::Unit), "1.609344");
        assert_eq!(fmt(r(12_345, 100), Style::Money(2)), "123.45");
        assert_eq!(fmt(Num::int(5), Style::Money(2)), "5");
        assert_eq!(fmt(r(51, 10), Style::Money(2)), "5.10");
        assert_eq!(fmt(Num::Float(0.30000000000000004), Style::Number), "0.3");
    }

    #[test]
    fn words_and_fractions() {
        let mut s = String::new();
        words(&mut s, Num::int(1234));
        assert_eq!(s, "one thousand two hundred thirty-four");
        s.clear();
        words(&mut s, r(-21, 2));
        assert_eq!(s, "minus ten point five");
        s.clear();
        fraction(&mut s, r(7, 4), true);
        assert_eq!(s, "1 3/4");
        s.clear();
        fraction(&mut s, Num::Float(0.125), false);
        assert_eq!(s, "1/8");
    }

    #[test]
    fn bases() {
        let mut s = String::new();
        radix(&mut s, Num::int(255), 16, true);
        assert_eq!(s, "0xFF");
        s.clear();
        radix(&mut s, Num::int(10), 2, true);
        assert_eq!(s, "0b1010");
        s.clear();
        radix(&mut s, Num::int(4095), 2, true);
        assert_eq!(s, "0b1111 1111 1111");
    }
}
