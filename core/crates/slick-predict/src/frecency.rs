//! Typed-ranking frecency: a 7-day decayed use count per item, normalised for ranking.

use crate::decay::DecayCounter;
use crate::time::DAY;

/// Per-item frecency in the log2 domain, plus the running maximum.
#[derive(Clone, Debug, PartialEq)]
pub struct Frecency {
    /// Half-life, minutes.
    pub half_life: f64,
    /// Items this many binary orders of magnitude below the most frecent item score 0.
    pub range: f64,
    /// Per item.
    pub counters: Vec<DecayCounter>,
    /// Largest `l` seen.
    pub max_l: f64,
}

impl Default for Frecency {
    fn default() -> Self {
        Frecency {
            half_life: 7.0 * DAY,
            range: 8.0,
            counters: Vec::new(),
            max_l: f64::NEG_INFINITY,
        }
    }
}

impl Frecency {
    /// Adds weight `w` for item `i` at time `t`.
    pub fn add(&mut self, i: u32, t: f64, w: f64) {
        let i = i as usize;
        if self.counters.len() <= i {
            self.counters.resize(i + 1, DecayCounter::default());
        }
        self.counters[i].add(t, w, self.half_life);
        self.max_l = self.max_l.max(self.counters[i].l as f64);
    }

    /// Item `i`'s frecency in [0, 1]: 1 for the most frecent item, falling linearly to 0 over
    /// `range` halvings. Both terms decay alike, so the score does not depend on the current time.
    pub fn score(&self, i: u32) -> f64 {
        match self.counters.get(i as usize) {
            Some(c) if !c.is_empty() => (1.0 + (c.l as f64 - self.max_l) / self.range).clamp(0.0, 1.0),
            _ => 0.0,
        }
    }

    /// Item `i`'s counter, for undo.
    pub fn get(&self, i: u32) -> DecayCounter {
        self.counters.get(i as usize).copied().unwrap_or_default()
    }

    /// Restores item `i`'s counter and the maximum after an undo.
    pub fn set(&mut self, i: u32, c: DecayCounter, max_l: f64) {
        if let Some(slot) = self.counters.get_mut(i as usize) {
            *slot = c;
        }
        self.max_l = max_l;
    }

    /// Clears item `i`.
    pub fn forget(&mut self, i: u32) {
        if let Some(slot) = self.counters.get_mut(i as usize) {
            *slot = DecayCounter::default();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_most_frecent_item_scores_one() {
        let mut f = Frecency::default();
        f.add(0, 0.0, 1.0);
        f.add(1, 0.0, 1.0);
        f.add(1, 10.0, 1.0);
        assert_eq!(f.score(1), 1.0);
        assert!(f.score(0) > 0.8 && f.score(0) < 1.0);
        assert_eq!(f.score(9), 0.0);
    }
}
