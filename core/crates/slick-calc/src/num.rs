//! Numbers: an exact rational while the arithmetic allows it, a float after that.
//!
//! Decimal literals become exact fractions, so `0.1 + 0.2` is exactly `3/10`. Sums, products,
//! quotients and integer powers stay exact until a numerator or denominator would leave `i128`.
//! Then the value falls back to `f64` and stays there. Transcendental functions always return a
//! float.

use core::cmp::Ordering;

/// A number.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Num {
    /// `n / d` in lowest terms with `d > 0`.
    Ratio(i128, i128),
    /// A finite float.
    Float(f64),
}

/// Why an operation has no number for an answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum NumError {
    DivisionByZero,
    Overflow,
    Undefined,
    NotReal,
    NotWhole,
}

pub(crate) type NumResult = Result<Num, NumError>;

/// Largest exponent for exact powers; larger ones go through floats.
const MAX_EXACT_EXPONENT: u32 = 256;

fn gcd(a: u128, b: u128) -> u128 {
    let (mut a, mut b) = (a, b);
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    a
}

/// A finite float, or the error its non-finite value stands for.
pub(crate) fn finite(x: f64) -> NumResult {
    if x.is_nan() {
        Err(NumError::Undefined)
    } else if x.is_infinite() {
        Err(NumError::Overflow)
    } else if x == 0.0 {
        // Folds -0.0 into 0.0 so it never prints as "-0".
        Ok(Num::Float(0.0))
    } else {
        Ok(Num::Float(x))
    }
}

impl Num {
    pub(crate) const ZERO: Num = Num::Ratio(0, 1);
    pub(crate) const ONE: Num = Num::Ratio(1, 1);

    pub(crate) const fn int(v: i128) -> Num {
        Num::Ratio(v, 1)
    }

    /// `n / d` reduced. None when `d` is zero or the reduction overflows.
    pub(crate) fn ratio(n: i128, d: i128) -> Option<Num> {
        if d == 0 {
            return None;
        }
        let g = gcd(n.unsigned_abs(), d.unsigned_abs());
        let g = i128::try_from(g).ok()?;
        let (mut n, mut d) = (n.checked_div(g)?, d.checked_div(g)?);
        if d < 0 {
            n = n.checked_neg()?;
            d = d.checked_neg()?;
        }
        Some(Num::Ratio(n, d))
    }

    /// `n / d`, as a float when the exact value does not fit.
    pub(crate) fn ratio_or_float(n: i128, d: i128) -> NumResult {
        if d == 0 {
            return Err(NumError::DivisionByZero);
        }
        match Num::ratio(n, d) {
            Some(v) => Ok(v),
            None => finite(n as f64 / d as f64),
        }
    }

    pub(crate) fn float(x: f64) -> NumResult {
        finite(x)
    }

    pub(crate) fn to_f64(self) -> f64 {
        match self {
            Num::Ratio(n, d) => n as f64 / d as f64,
            Num::Float(x) => x,
        }
    }

    pub(crate) fn is_exact(self) -> bool {
        matches!(self, Num::Ratio(..))
    }

    pub(crate) fn is_zero(self) -> bool {
        match self {
            Num::Ratio(n, _) => n == 0,
            Num::Float(x) => x == 0.0,
        }
    }

    pub(crate) fn is_negative(self) -> bool {
        match self {
            Num::Ratio(n, _) => n < 0,
            Num::Float(x) => x < 0.0,
        }
    }

    /// The value as an integer, when it is one exactly. Floats count when they are whole and fit.
    pub(crate) fn as_int(self) -> Option<i128> {
        match self {
            Num::Ratio(n, 1) => Some(n),
            Num::Ratio(..) => None,
            Num::Float(x) => {
                if x.fract() == 0.0 && x.abs() < 9.0e15 {
                    Some(x as i128)
                } else {
                    None
                }
            }
        }
    }

    /// The value as an exact integer only, with no float rounding.
    pub(crate) fn as_exact_int(self) -> Option<i128> {
        match self {
            Num::Ratio(n, 1) => Some(n),
            _ => None,
        }
    }

    pub(crate) fn neg(self) -> Num {
        match self {
            Num::Ratio(n, d) => match n.checked_neg() {
                Some(m) => Num::Ratio(m, d),
                None => Num::Float(-(n as f64) / d as f64),
            },
            Num::Float(x) => Num::Float(if x == 0.0 { 0.0 } else { -x }),
        }
    }

    pub(crate) fn abs(self) -> Num {
        if self.is_negative() { self.neg() } else { self }
    }

    pub(crate) fn add(self, o: Num) -> NumResult {
        if let (Num::Ratio(a, b), Num::Ratio(c, d)) = (self, o)
            && let Some(v) = add_ratio(a, b, c, d)
        {
            return Ok(v);
        }
        finite(self.to_f64() + o.to_f64())
    }

    pub(crate) fn sub(self, o: Num) -> NumResult {
        self.add(o.neg())
    }

    pub(crate) fn mul(self, o: Num) -> NumResult {
        if let (Num::Ratio(a, b), Num::Ratio(c, d)) = (self, o)
            && let Some(v) = mul_ratio(a, b, c, d)
        {
            return Ok(v);
        }
        finite(self.to_f64() * o.to_f64())
    }

    pub(crate) fn recip(self) -> NumResult {
        match self {
            Num::Ratio(0, _) => Err(NumError::DivisionByZero),
            Num::Ratio(n, d) => Num::ratio_or_float(d, n),
            Num::Float(0.0) => Err(NumError::DivisionByZero),
            Num::Float(x) => finite(1.0 / x),
        }
    }

    pub(crate) fn div(self, o: Num) -> NumResult {
        if o.is_zero() {
            return Err(NumError::DivisionByZero);
        }
        if let (Num::Ratio(a, b), Num::Ratio(c, d)) = (self, o)
            && let Some(v) = mul_ratio(a, b, d, c)
        {
            return Ok(v);
        }
        finite(self.to_f64() / o.to_f64())
    }

    /// Remainder with the sign of the divisor, as people expect from `mod`: `-7 mod 3` is 2.
    pub(crate) fn modulo(self, o: Num) -> NumResult {
        if o.is_zero() {
            return Err(NumError::DivisionByZero);
        }
        if let (Num::Ratio(a, b), Num::Ratio(c, d)) = (self, o) {
            // a/b mod c/d = (a*d mod c*b) / (b*d)
            if let (Some(x), Some(y), Some(den)) = (a.checked_mul(d), c.checked_mul(b), b.checked_mul(d))
                && let Some(r) = x.checked_rem_euclid(y)
            {
                let r = if y < 0 && r != 0 { r.checked_add(y) } else { Some(r) };
                if let Some(r) = r {
                    return Num::ratio_or_float(r, den);
                }
            }
        }
        let (x, y) = (self.to_f64(), o.to_f64());
        let r = x % y;
        finite(if r != 0.0 && (r < 0.0) != (y < 0.0) { r + y } else { r })
    }

    pub(crate) fn cmp(self, o: Num) -> Ordering {
        if let (Num::Ratio(a, b), Num::Ratio(c, d)) = (self, o)
            && let (Some(x), Some(y)) = (a.checked_mul(d), c.checked_mul(b))
        {
            return x.cmp(&y);
        }
        self.to_f64().total_cmp(&o.to_f64())
    }

    /// `self ^ e`.
    pub(crate) fn pow(self, e: Num) -> NumResult {
        if let Some(k) = e.as_exact_int() {
            return self.powi(k);
        }
        if let (Num::Ratio(n, d), Num::Ratio(p, q)) = (self, e)
            && (2..=3).contains(&q)
            && let Ok(q32) = u32::try_from(q)
        {
            // Exact roots: 8^(1/3) is 2, (9/4)^(1/2) is 3/2.
            if let (Some(rn), Some(rd)) = (exact_root(n, q32), exact_root(d, q32)) {
                return Num::Ratio(rn, rd).powi(p);
            }
        }
        let b = self.to_f64();
        if b < 0.0 {
            return Err(NumError::NotReal);
        }
        if b == 0.0 && e.is_negative() {
            return Err(NumError::DivisionByZero);
        }
        finite(b.powf(e.to_f64()))
    }

    pub(crate) fn powi(self, k: i128) -> NumResult {
        if k < 0 {
            if self.is_zero() {
                return Err(NumError::DivisionByZero);
            }
            let k = k.checked_neg().ok_or(NumError::Overflow)?;
            return self.powi(k)?.recip();
        }
        if let Num::Ratio(n, d) = self
            && let Ok(k32) = u32::try_from(k)
            && k32 <= MAX_EXACT_EXPONENT
            && let (Some(pn), Some(pd)) = (n.checked_pow(k32), d.checked_pow(k32))
        {
            return Ok(Num::Ratio(pn, pd));
        }
        let b = self.to_f64();
        let r = match i32::try_from(k) {
            Ok(k) => b.powi(k),
            Err(_) => b.powf(k as f64),
        };
        finite(r)
    }

    pub(crate) fn sqrt(self) -> NumResult {
        if self.is_negative() {
            return Err(NumError::NotReal);
        }
        if let Num::Ratio(n, d) = self
            && let (Some(a), Some(b)) = (exact_root(n, 2), exact_root(d, 2))
        {
            return Ok(Num::Ratio(a, b));
        }
        finite(self.to_f64().sqrt())
    }

    pub(crate) fn cbrt(self) -> NumResult {
        if let Num::Ratio(n, d) = self
            && let (Some(a), Some(b)) = (exact_root(n, 3), exact_root(d, 3))
        {
            return Ok(Num::Ratio(a, b));
        }
        finite(self.to_f64().cbrt())
    }

    pub(crate) fn factorial(self) -> NumResult {
        let n = self.as_int().ok_or(NumError::NotWhole)?;
        if n < 0 {
            return Err(NumError::Undefined);
        }
        if n > 170 {
            return Err(NumError::Overflow);
        }
        let mut exact: Option<i128> = Some(1);
        let mut approx = 1.0f64;
        for i in 2..=n {
            exact = exact.and_then(|v| v.checked_mul(i));
            approx *= i as f64;
        }
        match exact {
            Some(v) => Ok(Num::int(v)),
            None => finite(approx),
        }
    }

    pub(crate) fn round_with(self, places: i32, mode: Rounding) -> NumResult {
        if !(-30..=30).contains(&places) {
            return Err(NumError::Overflow);
        }
        if let Num::Ratio(n, d) = self {
            let scale = 10i128.checked_pow(places.unsigned_abs());
            if let Some(scale) = scale {
                // Scale by 10^places, round, then scale back. Negative places divide.
                let (sn, sd) = if places >= 0 {
                    (n.checked_mul(scale), Some(d))
                } else {
                    (Some(n), d.checked_mul(scale))
                };
                if let (Some(sn), Some(sd)) = (sn, sd) {
                    let r = round_div(sn, sd, mode);
                    let back = if places >= 0 {
                        Num::ratio(r, scale)
                    } else {
                        r.checked_mul(scale).map(Num::int)
                    };
                    if let Some(v) = back {
                        return Ok(v);
                    }
                }
            }
        }
        let x = self.to_f64();
        let f = 10f64.powi(places);
        let s = x * f;
        let r = match mode {
            Rounding::HalfAway => s.round(),
            Rounding::Floor => s.floor(),
            Rounding::Ceil => s.ceil(),
            Rounding::Trunc => s.trunc(),
        };
        finite(r / f)
    }
}

/// How to round.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Rounding {
    HalfAway,
    Floor,
    Ceil,
    Trunc,
}

/// `n / d` rounded to an integer, with `d > 0`.
fn round_div(n: i128, d: i128, mode: Rounding) -> i128 {
    let q = n.div_euclid(d);
    let r = n.rem_euclid(d);
    match mode {
        Rounding::Floor => q,
        Rounding::Ceil => {
            if r == 0 {
                q
            } else {
                q.saturating_add(1)
            }
        }
        Rounding::Trunc => {
            if n < 0 && r != 0 {
                q.saturating_add(1)
            } else {
                q
            }
        }
        Rounding::HalfAway => {
            // Compare 2r with d without overflow: r < d, so r >= d - r decides.
            let half_or_more = r >= d - r;
            let exactly_half = r == d - r;
            if exactly_half {
                if n < 0 { q } else { q.saturating_add(1) }
            } else if half_or_more {
                q.saturating_add(1)
            } else {
                q
            }
        }
    }
}

fn add_ratio(a: i128, b: i128, c: i128, d: i128) -> Option<Num> {
    let g = i128::try_from(gcd(b.unsigned_abs(), d.unsigned_abs())).ok()?;
    let bg = b.checked_div(g)?;
    let dg = d.checked_div(g)?;
    let n = a.checked_mul(dg)?.checked_add(c.checked_mul(bg)?)?;
    let den = bg.checked_mul(d)?;
    Num::ratio(n, den)
}

fn mul_ratio(a: i128, b: i128, c: i128, d: i128) -> Option<Num> {
    let g1 = i128::try_from(gcd(a.unsigned_abs(), d.unsigned_abs())).ok()?.max(1);
    let g2 = i128::try_from(gcd(c.unsigned_abs(), b.unsigned_abs())).ok()?.max(1);
    let n = a.checked_div(g1)?.checked_mul(c.checked_div(g2)?)?;
    let den = b.checked_div(g2)?.checked_mul(d.checked_div(g1)?)?;
    Num::ratio(n, den)
}

/// The exact `k`th root of `v` when `v` is a perfect power. Odd roots of negatives are negative.
fn exact_root(v: i128, k: u32) -> Option<i128> {
    if v < 0 {
        if k.is_multiple_of(2) {
            return None;
        }
        return exact_root(v.checked_neg()?, k)?.checked_neg();
    }
    if v < 2 {
        return Some(v);
    }
    let guess = (v as f64).powf(1.0 / f64::from(k)).round() as i128;
    [guess.saturating_sub(1), guess, guess.saturating_add(1)]
        .into_iter()
        .find(|&c| c >= 0 && c.checked_pow(k) == Some(v))
}

/// Parses an unsigned decimal literal into an exact number when it fits, else a float.
///
/// `int` and `frac` hold ASCII digits only. `exp` is the power of ten from scientific notation.
pub(crate) fn from_decimal(int: &[u8], frac: &[u8], exp: i32) -> NumResult {
    let mut n: Option<i128> = Some(0);
    for &c in int.iter().chain(frac.iter()) {
        let digit = i128::from(c.wrapping_sub(b'0'));
        n = n.and_then(|v| v.checked_mul(10)).and_then(|v| v.checked_add(digit));
    }
    let scale = i64::from(exp) - frac.len() as i64;
    if let Some(n) = n
        && let Ok(s) = u32::try_from(scale.unsigned_abs())
        && s <= 38
        && let Some(p) = 10i128.checked_pow(s)
    {
        let v = if scale >= 0 {
            n.checked_mul(p).map(Num::int)
        } else {
            Num::ratio(n, p)
        };
        if let Some(v) = v {
            return Ok(v);
        }
    }
    // Too large for an exact value: build "<int>.<frac>e<exp>" on the stack and parse it.
    let mut buf = [0u8; 160];
    let mut len = 0;
    let mut push = |c: u8| {
        if let Some(slot) = buf.get_mut(len) {
            *slot = c;
            len += 1;
        }
    };
    for &c in int.iter().take(60) {
        push(c);
    }
    push(b'.');
    for &c in frac.iter().take(60) {
        push(c);
    }
    push(b'0');
    push(b'e');
    let mut e = [0u8; 12];
    let elen = write_i64(i64::from(exp), &mut e);
    for &c in e.iter().take(elen) {
        push(c);
    }
    let text = core::str::from_utf8(buf.get(..len).unwrap_or(&[])).unwrap_or("0");
    let x: f64 = text.parse().unwrap_or(f64::NAN);
    finite(x)
}

/// Writes `v` in decimal into `out`, returning the length.
fn write_i64(v: i64, out: &mut [u8; 12]) -> usize {
    let mut tmp = [0u8; 24];
    let mut i = 0;
    let neg = v < 0;
    let mut u = v.unsigned_abs();
    loop {
        if let Some(slot) = tmp.get_mut(i) {
            *slot = b'0' + (u % 10) as u8;
        }
        i += 1;
        u /= 10;
        if u == 0 || i >= tmp.len() {
            break;
        }
    }
    let mut len = 0;
    if neg && let Some(slot) = out.get_mut(0) {
        *slot = b'-';
        len = 1;
    }
    for k in (0..i).rev() {
        if let (Some(slot), Some(&c)) = (out.get_mut(len), tmp.get(k)) {
            *slot = c;
            len += 1;
        }
    }
    len
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(n: i128, d: i128) -> Num {
        Num::ratio(n, d).unwrap_or(Num::ZERO)
    }

    #[test]
    fn decimal_sums_are_exact() {
        let a = from_decimal(b"0", b"1", 0).unwrap_or(Num::ZERO);
        let b = from_decimal(b"0", b"2", 0).unwrap_or(Num::ZERO);
        assert!(matches!(a.add(b), Ok(Num::Ratio(3, 10))));
    }

    #[test]
    fn overflow_falls_back_to_float() {
        let big = Num::int(i128::MAX / 2);
        assert!(matches!(big.mul(Num::int(4)), Ok(Num::Float(_))));
    }

    #[test]
    fn modulo_takes_the_sign_of_the_divisor() {
        assert!(matches!(Num::int(-7).modulo(Num::int(3)), Ok(Num::Ratio(2, 1))));
        assert!(matches!(Num::int(7).modulo(Num::int(-3)), Ok(Num::Ratio(-2, 1))));
    }

    #[test]
    fn exact_roots() {
        assert!(matches!(Num::int(8).pow(r(1, 3)), Ok(Num::Ratio(2, 1))));
        assert!(matches!(r(9, 4).sqrt(), Ok(Num::Ratio(3, 2))));
        assert!(matches!(Num::int(-8).cbrt(), Ok(Num::Ratio(-2, 1))));
    }

    #[test]
    fn rounding_is_half_away_from_zero() {
        let half = Rounding::HalfAway;
        assert!(matches!(r(5, 2).round_with(0, half), Ok(Num::Ratio(3, 1))));
        assert!(matches!(r(-5, 2).round_with(0, half), Ok(Num::Ratio(-3, 1))));
        assert!(matches!(r(31415, 10000).round_with(2, half), Ok(Num::Ratio(157, 50))));
    }
}
