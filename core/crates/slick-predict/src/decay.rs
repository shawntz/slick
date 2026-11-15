//! Exponentially decayed counters stored in the log2 domain.

/// A count that halves every `h` minutes, stored as `l` so that `value(t) = 2^(l - t/h)`.
///
/// Adding weight `w` at time `t` is `l <- log2(2^l + 2^(log2 w + t/h))`. Every counter shares the
/// `t/h` term, so ordering counters by `l` orders them by current value, and no decay pass is ever
/// needed (the trick Firefox uses for frecency).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DecayCounter {
    /// log2 of the value at time 0. Negative infinity means empty.
    pub l: f32,
}

impl Default for DecayCounter {
    fn default() -> Self {
        DecayCounter { l: f32::NEG_INFINITY }
    }
}

/// log2(2^a + 2^b) without overflow.
#[inline]
pub(crate) fn logaddexp2(a: f64, b: f64) -> f64 {
    if a == f64::NEG_INFINITY {
        return b;
    }
    if b == f64::NEG_INFINITY {
        return a;
    }
    let (hi, lo) = if a > b { (a, b) } else { (b, a) };
    hi + (1.0 + (lo - hi).exp2()).log2()
}

impl DecayCounter {
    /// Adds weight `w` (> 0) at time `t` for half-life `h`.
    #[inline]
    pub fn add(&mut self, t: f64, w: f64, h: f64) {
        if w > 0.0 && w.is_finite() {
            self.l = logaddexp2(self.l as f64, w.log2() + t / h) as f32;
        }
    }

    /// log2 of the value at time `t`.
    #[inline]
    pub fn log2_value(&self, t: f64, h: f64) -> f64 {
        self.l as f64 - t / h
    }

    /// The value at time `t`.
    #[inline]
    pub fn value(&self, t: f64, h: f64) -> f64 {
        if self.is_empty() {
            0.0
        } else {
            self.log2_value(t, h).exp2()
        }
    }

    /// True when nothing was ever added.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.l == f32::NEG_INFINITY
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn halves_every_half_life_and_adds() {
        let mut c = DecayCounter::default();
        assert!(c.is_empty());
        c.add(0.0, 1.0, 60.0);
        assert!((c.value(60.0, 60.0) - 0.5).abs() < 1e-6);
        c.add(60.0, 1.0, 60.0);
        assert!((c.value(60.0, 60.0) - 1.5).abs() < 1e-5);
        c.add(60.0, 0.0, 60.0);
        assert!((c.value(60.0, 60.0) - 1.5).abs() < 1e-5);
    }
}
