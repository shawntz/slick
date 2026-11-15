//! Decayed conditional counts `c_f(v, i)`: how often item i was executed while feature f had value v.

use crate::context::{F_HOUR, F_HOURDT, NF, NONE};
use crate::hash::FxMap;

/// One feature value's counts.
#[derive(Default, Clone, Debug, PartialEq)]
pub struct Row {
    /// Sum of every item's count in this row.
    pub total: f32,
    /// (item, count) pairs.
    pub items: Vec<(u32, f32)>,
}

impl Row {
    fn add(&mut self, item: u32, w: f32) {
        self.total += w;
        match self.items.iter_mut().find(|e| e.0 == item) {
            Some(e) => e.1 += w,
            None => self.items.push((item, w)),
        }
    }
}

/// The rows of one feature, keyed by feature value.
pub type Table = FxMap<u32, Row>;

/// What an update changed in one row, for undo: the old total and the item's old count.
#[derive(Clone, Copy, Debug)]
pub struct RowUndo {
    feature: usize,
    value: u32,
    item: u32,
    total: f32,
    /// The item's count before, or `None` when the update added its entry.
    count: Option<f32>,
}

/// Counts are stored pre-multiplied by `S(t) = 2^((t - t0)/h)`, so adding at time t is O(1) and
/// every count decays implicitly: ratios are scale-free, and pseudo-counts are multiplied by S(t)
/// when read.
#[derive(Clone, Debug, PartialEq)]
pub struct CondCounts {
    /// Half-life in minutes.
    pub h: f64,
    /// Time the scale is relative to.
    pub t0: f64,
    /// Share of an hour count also added to the neighbouring hours.
    pub hour_spread: f32,
    /// One table per feature.
    pub tables: Vec<Table>,
}

impl CondCounts {
    /// Empty counts with half-life `h` minutes.
    pub fn new(h: f64, hour_spread: f32) -> Self {
        CondCounts {
            h,
            t0: 0.0,
            hour_spread,
            tables: vec![Table::default(); NF],
        }
    }

    /// The scale `S(t)`.
    #[inline]
    pub fn scale(&self, t: f64) -> f64 {
        ((t - self.t0) / self.h).exp2()
    }

    /// The (feature, value, share) rows an update for `vals` touches, including spread hours.
    fn touched(&self, vals: &[u32; NF]) -> Vec<(usize, u32, f32)> {
        let mut out = Vec::with_capacity(NF + 4);
        for (f, &v) in vals.iter().enumerate() {
            if v == NONE {
                continue;
            }
            out.push((f, v, 1.0));
            if (f == F_HOUR || f == F_HOURDT) && self.hour_spread > 0.0 {
                let base = v - v % 24;
                let h = v % 24;
                out.push((f, base + (h + 1) % 24, self.hour_spread));
                out.push((f, base + (h + 23) % 24, self.hour_spread));
            }
        }
        out
    }

    /// Adds weight `w` for item `y` at time `t` under the feature values `vals`. Returns the rows
    /// as they were before, so the update can be undone; `None` when a rescale happened, which
    /// cannot be undone.
    pub fn add(&mut self, vals: &[u32; NF], y: u32, t: f64, w: f64) -> Option<Vec<RowUndo>> {
        let mut undo = Some(Vec::with_capacity(NF + 4));
        if (t - self.t0) / self.h > 60.0 {
            self.rescale(t);
            undo = None;
        }
        let s = (self.scale(t) * w) as f32;
        let touched = self.touched(vals);
        for (f, v, share) in touched {
            let row = self.tables[f].entry(v).or_default();
            if let Some(u) = undo.as_mut() {
                u.push(RowUndo {
                    feature: f,
                    value: v,
                    item: y,
                    total: row.total,
                    count: row.items.iter().find(|e| e.0 == y).map(|e| e.1),
                });
            }
            row.add(y, s * share);
        }
        undo
    }

    /// Puts back what an `add` changed, exactly: totals and counts are restored, not subtracted.
    pub fn restore(&mut self, undo: Vec<RowUndo>) {
        for r in undo.into_iter().rev() {
            let table = &mut self.tables[r.feature];
            let Some(row) = table.get_mut(&r.value) else { continue };
            row.total = r.total;
            match r.count {
                Some(c) => {
                    if let Some(e) = row.items.iter_mut().find(|e| e.0 == r.item) {
                        e.1 = c;
                    }
                }
                None => {
                    // The update appended the entry, so it is the last one.
                    if row.items.last().is_some_and(|e| e.0 == r.item) {
                        row.items.pop();
                    }
                    if row.items.is_empty() {
                        table.remove(&r.value);
                    }
                }
            }
        }
    }

    /// Divides everything by S(t), moves t0 to t and drops entries that decayed below 1e-3 events.
    pub fn rescale(&mut self, t: f64) {
        let inv = (1.0 / self.scale(t)) as f32;
        for table in self.tables.iter_mut() {
            table.retain(|_, r| {
                r.total *= inv;
                r.items.retain_mut(|e| {
                    e.1 *= inv;
                    e.1 > 1e-3
                });
                !r.items.is_empty()
            });
        }
        self.t0 = t;
    }

    /// Removes every count of `item`, and every row keyed by it (the previous-item features).
    pub fn forget(&mut self, item: u32) {
        for table in self.tables.iter_mut() {
            table.remove(&item);
            table.retain(|_, r| {
                if let Some(p) = r.items.iter().position(|e| e.0 == item) {
                    r.total -= r.items[p].1;
                    r.items.swap_remove(p);
                }
                !r.items.is_empty()
            });
        }
    }

    /// Number of stored (value, item) counts.
    pub fn entries(&self) -> usize {
        self.tables
            .iter()
            .map(|t| t.values().map(|r| r.items.len()).sum::<usize>())
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_then_restore_is_exact() {
        let mut c = CondCounts::new(60.0 * 1440.0, 0.5);
        let mut vals = [NONE; NF];
        vals[F_HOUR] = 23;
        vals[3] = 7;
        c.add(&vals, 1, 10.0, 1.0);
        let before = c.clone();
        let undo = c.add(&vals, 2, 20.0, 1.0);
        assert_ne!(c, before);
        c.restore(undo.unwrap_or_default());
        assert_eq!(c, before);
    }

    #[test]
    fn forget_removes_counts_and_rows() {
        let mut c = CondCounts::new(60.0 * 1440.0, 0.0);
        let mut vals = [NONE; NF];
        vals[4] = 9;
        c.add(&vals, 1, 0.0, 1.0);
        c.add(&vals, 2, 0.0, 1.0);
        c.forget(9);
        assert_eq!(c.entries(), 0);
        vals[4] = NONE;
        vals[3] = 5;
        c.add(&vals, 1, 0.0, 1.0);
        c.add(&vals, 2, 0.0, 1.0);
        c.forget(1);
        assert_eq!(c.entries(), 1);
        assert!((c.tables[3][&5].total - 1.0).abs() < 1e-6);
    }
}
