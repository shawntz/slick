//! Query affinity: which item the user runs after typing each query.
//!
//! When item y runs after query q, every prefix p of q gets credit c: 1 for q itself, `eta` for
//! shorter prefixes. A row is an exponential moving histogram: all weights are multiplied by
//! `gamma^c`, then c is added to y. Weights therefore stay bounded (at most 1/(1 - gamma)). Weights
//! also decay with a 60-day half-life, and a row keeps at most 8 items.
//!
//! Each row also names the item that holds its learned band, and the item its last credit went
//! to. That is what makes rule 4 of the ranking contract exact from any history:
//!
//! - With no holder, the strongest entry takes the band once its weight reaches `band_weight`
//!   (rule 2).
//! - The holder changes only when another item gets two credits in a row on this row and is then
//!   the strongest entry with at least `band_weight`, or when the holder's own weight falls below
//!   `band_weight` (it decays away, by time or by other items' credits). Then the strongest entry
//!   with at least `band_weight`, if any, takes over.
//!
//! Weights alone cannot do this: after a long habit of B, two picks of A make A the strongest
//! entry, and one more pick of B makes B the strongest again.

use crate::context::NONE;
use crate::hash::{FxMap, fnv1a};
use crate::time::DAY;

/// Constants of the affinity table.
#[derive(Clone, Debug, PartialEq)]
pub struct AffinityParams {
    /// Self-decay per unit of credit.
    pub gamma: f64,
    /// Credit for a strict prefix of the query.
    pub eta: f64,
    /// Time half-life, minutes.
    pub half_life: f64,
    /// Items kept per row.
    pub max_entries: usize,
    /// Entries below this weight are dropped.
    pub min_weight: f32,
    /// Longest query learned, in bytes of the normalized query.
    pub max_query_bytes: usize,
    /// Decayed weight from which an item holds the learned band, and below which the holder lets
    /// it go. One pick weighs 1, two picks 1 + gamma, and two picks followed by one stray pick
    /// gamma + gamma^2 (1.19). The threshold sits above the first and at most the last, so one pick
    /// never enters the band and one stray pick never drops a fresh two-pick habit.
    pub band_weight: f64,
}

impl Default for AffinityParams {
    fn default() -> Self {
        AffinityParams {
            gamma: 0.7,
            eta: 0.5,
            half_life: 60.0 * DAY,
            max_entries: 8,
            min_weight: 0.02,
            max_query_bytes: 32,
            band_weight: 1.1,
        }
    }
}

/// One item's weight in a row.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Entry {
    /// Learn id.
    pub item: u32,
    /// Weight at time `t`.
    pub w: f32,
    /// Minutes since the epoch when `w` was last written.
    pub t: f32,
}

/// The affinity row of one query prefix.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    /// At most `max_entries` entries. Every write stamps all of them with the same time.
    pub entries: Vec<Entry>,
    /// The item that held the learned band at the last write, `NONE` for none. Whether it still
    /// holds it now depends on its decayed weight; see [`Row::band`].
    pub holder: u32,
    /// The item the last credit to this row went to, `NONE` for none.
    pub last: u32,
}

impl Default for Row {
    fn default() -> Self {
        Row {
            entries: Vec::new(),
            holder: NONE,
            last: NONE,
        }
    }
}

impl Row {
    /// The strongest entry decayed to `t` and its weight. Ties go to the earlier entry.
    fn strongest(&self, half_life: f64, t: f64) -> Option<(u32, f64)> {
        let mut top: Option<(u32, f64)> = None;
        for e in &self.entries {
            let w = e.w as f64 * decay(half_life, t, e.t);
            if top.is_none_or(|(_, best)| w > best) {
                top = Some((e.item, w));
            }
        }
        top
    }

    /// The decayed weight of `item` at `t`, if it has an entry.
    fn weight(&self, item: u32, half_life: f64, t: f64) -> Option<f64> {
        self.entries
            .iter()
            .find(|e| e.item == item)
            .map(|e| e.w as f64 * decay(half_life, t, e.t))
    }

    /// The item that holds the learned band at `t`, with its decayed weight: the holder while its
    /// weight is at least `band`, else the strongest entry when its weight is at least `band`.
    pub fn band(&self, half_life: f64, band: f64, t: f64) -> Option<(u32, f64)> {
        if self.holder != NONE
            && let Some(w) = self.weight(self.holder, half_life, t)
            && w >= band
        {
            return Some((self.holder, w));
        }
        self.strongest(half_life, t).filter(|&(_, w)| w >= band)
    }
}

/// A row decayed to a point in time.
#[derive(Clone, Copy, Debug, Default)]
pub struct Summary {
    entries: [(u32, f64); 8],
    n: usize,
    /// Sum of the decayed weights.
    pub total: f64,
    /// The strongest item and its decayed weight.
    pub top: Option<(u32, f64)>,
    /// The item that holds the learned band and its decayed weight (see [`Row::band`]).
    pub band: Option<(u32, f64)>,
}

impl Summary {
    /// The decayed weight of `item` in this row (0 when absent).
    pub fn weight(&self, item: u32) -> f64 {
        self.entries[..self.n].iter().find(|e| e.0 == item).map_or(0.0, |e| e.1)
    }

    /// The (item, decayed weight) pairs of the row.
    pub fn entries(&self) -> &[(u32, f64)] {
        &self.entries[..self.n]
    }
}

/// Rows a `learn` changed, as they were before, for undo.
#[derive(Clone, Debug, Default)]
pub struct AffinityUndo {
    rows: Vec<(u64, Option<Row>)>,
}

/// The affinity table, keyed by the FNV-1a hash of each normalized query prefix.
#[derive(Clone, Debug, Default)]
pub struct Affinity {
    /// Constants.
    pub p: AffinityParams,
    /// Rows by prefix hash.
    pub rows: FxMap<u64, Row>,
}

impl Affinity {
    /// An empty table.
    pub fn new(p: AffinityParams) -> Self {
        Affinity {
            p,
            rows: FxMap::default(),
        }
    }

    /// The row for the normalized query `q`, decayed to time `t`. Allocation-free.
    pub fn summary(&self, q: &[u8], t: f64) -> Summary {
        let mut s = Summary::default();
        let Some(row) = self.rows.get(&fnv1a(q)) else { return s };
        for e in row.entries.iter().take(8) {
            let w = e.w as f64 * decay(self.p.half_life, t, e.t);
            s.entries[s.n] = (e.item, w);
            s.n += 1;
            s.total += w;
            if s.top.is_none_or(|(_, best)| w > best) {
                s.top = Some((e.item, w));
            }
        }
        s.band = row.band(self.p.half_life, self.p.band_weight, t);
        s
    }

    /// The row of the normalized query `q`, cut the way rows are keyed, if it exists.
    pub fn row(&self, q: &str) -> Option<&Row> {
        self.rows.get(&row_key(q, self.p.max_query_bytes))
    }

    /// Credits `item` for the normalized query `q` at time `t`, every prefix included. Queries are
    /// cut at `max_query_bytes` on a char boundary. Returns the changed rows for undo.
    pub fn learn(&mut self, q: &str, item: u32, t: f64) -> AffinityUndo {
        let mut undo = AffinityUndo::default();
        let q = truncate(q, self.p.max_query_bytes);
        if q.is_empty() {
            return undo;
        }
        let bytes = q.as_bytes();
        for (start, ch) in q.char_indices() {
            let end = start + ch.len_utf8();
            let credit = if end == q.len() { 1.0 } else { self.p.eta };
            if credit <= 0.0 {
                continue;
            }
            let key = fnv1a(&bytes[..end]);
            let half_life = self.p.half_life;
            let band = self.p.band_weight;
            let row = self.rows.entry(key).or_default();
            undo.rows.push((key, (!row.entries.is_empty()).then(|| row.clone())));
            let g = self.p.gamma.powf(credit);
            // A row's clock never runs backwards: a pick stamped before the row's last write (a
            // clock set back) counts as made at that write, so no weight grows by decay.
            let t = row.entries.iter().fold(t, |newest, e| newest.max(e.t as f64));
            // The band as it stands at this pick, before the pick changes any weight. A holder
            // whose weight decayed below the threshold since the last write has already let go.
            let holder = row.band(half_life, band, t).map_or(NONE, |(id, _)| id);
            for e in row.entries.iter_mut() {
                e.w = (e.w as f64 * decay(half_life, t, e.t) * g) as f32;
                e.t = t as f32;
            }
            match row.entries.iter_mut().find(|e| e.item == item) {
                Some(e) => e.w += credit as f32,
                None => row.entries.push(Entry {
                    item,
                    w: credit as f32,
                    t: t as f32,
                }),
            }
            let min = self.p.min_weight;
            row.entries.retain(|e| e.w >= min);
            if row.entries.len() > self.p.max_entries {
                row.entries
                    .sort_by(|a, b| b.w.total_cmp(&a.w).then(a.item.cmp(&b.item)));
                row.entries.truncate(self.p.max_entries);
            }
            // Rule 4: another item takes the band only on its second credit in a row, and only as
            // the strongest entry. The holder also lets go when its weight falls below the
            // threshold; `band` then hands the band to the strongest entry, if it is strong enough.
            row.holder = holder;
            if item != holder
                && row.last == item
                && row
                    .strongest(half_life, t)
                    .is_some_and(|(id, w)| id == item && w >= band)
            {
                row.holder = item;
            }
            row.holder = row.band(half_life, band, t).map_or(NONE, |(id, _)| id);
            row.last = item;
        }
        undo
    }

    /// Puts back the rows a `learn` changed.
    pub fn restore(&mut self, undo: AffinityUndo) {
        for (key, row) in undo.rows.into_iter().rev() {
            match row {
                Some(r) => {
                    self.rows.insert(key, r);
                }
                None => {
                    self.rows.remove(&key);
                }
            }
        }
    }

    /// Removes `item` from every row. A row it held the band of has no holder until the next
    /// write or query hands the band on; a row whose last credit it had starts a new run.
    pub fn forget(&mut self, item: u32) {
        self.rows.retain(|_, r| {
            r.entries.retain(|e| e.item != item);
            if r.holder == item {
                r.holder = NONE;
            }
            if r.last == item {
                r.last = NONE;
            }
            !r.entries.is_empty()
        });
    }

    /// Removes the row of the normalized query `q`, cut the way rows are keyed. Returns whether a
    /// row was removed. The rows of its prefixes keep their credit.
    pub fn forget_row(&mut self, q: &str) -> bool {
        self.forget_row_key(row_key(q, self.p.max_query_bytes))
    }

    /// Removes the row with key `key`. Returns whether a row was removed.
    pub fn forget_row_key(&mut self, key: u64) -> bool {
        self.rows.remove(&key).is_some()
    }
}

/// The key of the row of the normalized query `q`: the FNV-1a hash of `q` cut to `max` bytes.
pub fn row_key(q: &str, max: usize) -> u64 {
    fnv1a(truncate(q, max).as_bytes())
}

/// The decay factor from `written` to `t` (minutes), at most 1: an earlier `t` than the write
/// leaves the weight as it is instead of growing it.
fn decay(half_life: f64, t: f64, written: f32) -> f64 {
    (-(t - written as f64).max(0.0) / half_life).exp2()
}

/// `q` cut to at most `max` bytes without splitting a char. Rows exist only for queries cut this
/// way, so callers looking a row up cut the query the same way.
pub fn truncate(q: &str, max: usize) -> &str {
    if q.len() <= max {
        return q;
    }
    let mut end = max;
    while !q.is_char_boundary(end) {
        end -= 1;
    }
    &q[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_habit_flips_in_two_selections_and_not_one() {
        let mut a = Affinity::new(AffinityParams::default());
        let mut t = 0.0;
        for _ in 0..20 {
            t += 60.0;
            a.learn("s", 1, t);
        }
        t += 60.0;
        a.learn("s", 2, t);
        assert_eq!(a.summary(b"s", t).top.map(|x| x.0), Some(1));
        t += 60.0;
        a.learn("s", 2, t);
        assert_eq!(a.summary(b"s", t).top.map(|x| x.0), Some(2));
    }

    #[test]
    fn prefixes_get_partial_credit_and_weights_stay_bounded() {
        let mut a = Affinity::new(AffinityParams::default());
        for k in 0..100 {
            a.learn("safari", 7, k as f64);
        }
        let full = a.summary(b"safari", 100.0).weight(7);
        let prefix = a.summary(b"saf", 100.0).weight(7);
        assert!(full > prefix && prefix > 0.0);
        assert!(full <= 1.0 / (1.0 - 0.7) + 1e-3);
    }

    #[test]
    fn undo_restores_rows_and_forget_clears_an_item() {
        let mut a = Affinity::new(AffinityParams::default());
        a.learn("term", 1, 0.0);
        let before = a.rows.clone();
        let u = a.learn("tex", 2, 1.0);
        a.restore(u);
        assert_eq!(a.rows, before);
        a.forget(1);
        assert!(a.rows.is_empty());
    }

    /// A clock that jumps back, or a query asked at an earlier time than the last pick, must not
    /// grow weights: the bound keeps rule 4 (a habit flips in two selections) and the band
    /// threshold meaningful.
    #[test]
    fn a_clock_that_runs_backwards_never_inflates_weights() {
        let bound = 1.0 / (1.0 - 0.7) + 1e-3;
        let mut a = Affinity::new(AffinityParams::default());
        let later = 400.0 * DAY;
        for k in 0..30 {
            a.learn("term", 1, later + k as f64);
        }
        assert!(a.summary(b"term", 0.0).weight(1) <= bound, "query before the picks");
        // Two picks with a clock set a year back still flip the habit.
        a.learn("term", 2, 10.0);
        assert_eq!(a.summary(b"term", 10.0).top.map(|x| x.0), Some(1), "one stray pick");
        a.learn("term", 2, 20.0);
        let s = a.summary(b"term", 20.0);
        assert_eq!(s.top.map(|x| x.0), Some(2), "second pick");
        assert!(s.total <= bound);
        // And back to the right time: the row decays from its newest write, not from the past.
        let s = a.summary(b"term", later + 60.0);
        assert!(s.total <= bound && s.top.map(|x| x.0) == Some(2));
    }

    /// The verifier's case: after a long habit of B, a new two-pick habit of A survives one pick
    /// of B, and a second pick of B flips it back.
    #[test]
    fn a_new_two_pick_habit_survives_one_pick_of_a_long_old_habit() {
        let mut a = Affinity::new(AffinityParams::default());
        let mut t = 0.0;
        let mut pick = |a: &mut Affinity, item| {
            t += 1.0;
            a.learn("term", item, t);
            a.summary(b"term", t).band.map(|b| b.0)
        };
        for _ in 0..30 {
            pick(&mut a, 2);
        }
        assert_eq!(pick(&mut a, 1), Some(2), "one pick of A");
        assert_eq!(pick(&mut a, 1), Some(1), "two picks of A");
        assert_eq!(pick(&mut a, 2), Some(1), "one pick of B");
        assert_eq!(pick(&mut a, 2), Some(2), "two picks of B");
    }

    #[test]
    fn forgetting_a_row_leaves_its_prefixes() {
        let mut a = Affinity::new(AffinityParams::default());
        a.learn("term", 1, 0.0);
        assert!(a.forget_row("term"));
        assert!(!a.forget_row("term"));
        assert!(a.row("term").is_none());
        assert!(a.row("ter").is_some_and(|r| !r.entries.is_empty()));
        let long = "x".repeat(40);
        a.learn(&long, 2, 1.0);
        assert!(a.forget_row(&long), "a long query's row is found through the same cut");
    }

    /// A small deterministic generator, so the property test needs no dependency.
    struct Rng(u64);

    impl Rng {
        fn below(&mut self, n: usize) -> usize {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            (self.0 % n as u64) as usize
        }
    }

    /// What a pick changed, the rows before it and the test's run record before it.
    type Undoable = (AffinityUndo, FxMap<u64, Row>, FxMap<u64, u32>);

    /// Rule 4 from any history, at the level of the rows. Random picks over queries that share
    /// prefixes (so rows also get prefix credit), clocks that jump both ways, undo and forget. For
    /// every row, after every step:
    /// - the band changes hands only when the new holder got its second credit in a row on that
    ///   row, or when the old holder's weight is below the threshold;
    /// - whoever takes the band is the strongest entry and at least at the threshold (rule 2);
    /// - two picks of the same item for the same query in a row put it in that query's band;
    /// - undo restores every row exactly.
    #[test]
    fn rule_4_holds_on_every_row_after_random_histories() {
        const QUERIES: &[&str] = &["t", "te", "term", "terminal", "x", "xy", "é", "éa", "termx"];
        let p = AffinityParams::default();
        let (hl, band) = (p.half_life, p.band_weight);
        let keys: Vec<u64> = {
            let mut k: Vec<u64> = QUERIES
                .iter()
                .flat_map(|q| q.char_indices().map(|(i, c)| fnv1a(&q.as_bytes()[..i + c.len_utf8()])))
                .collect();
            k.sort_unstable();
            k.dedup();
            k
        };
        let mut checked_changes = 0;
        for seed in 1..=200u64 {
            let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
            let mut a = Affinity::new(p.clone());
            // The item each row's last credit went to, kept by the test from what it did.
            let mut last: FxMap<u64, u32> = FxMap::default();
            let mut t = 1_000.0;
            let mut previous: Option<(&str, u32, f64)> = None;
            let mut undo: Option<Undoable> = None;
            for _ in 0..300 {
                t += match rng.below(30) {
                    0 => -40.0 * DAY,
                    1 => 400.0 * DAY,
                    2 => 70.0 * DAY,
                    _ => (1 + rng.below(3 * 24 * 60)) as f64,
                };
                let op = rng.below(20);
                let rows_before = a.rows.clone();
                let last_before = last.clone();
                // Each row's own clock: a pick stamped before a row's last write counts at that write.
                let at = |rows: &FxMap<u64, Row>, k: u64| {
                    rows.get(&k)
                        .map_or(t, |r| r.entries.iter().fold(t, |n, e| n.max(e.t as f64)))
                };
                let mut credited: Vec<u64> = Vec::new();
                let mut picked = None;
                match op {
                    0 => {
                        let item = rng.below(6) as u32;
                        a.forget(item);
                        last.retain(|_, l| *l != item);
                        previous = None;
                        undo = None;
                    }
                    1 if undo.is_some() => {
                        let Some((u, rows, l)) = undo.take() else {
                            unreachable!()
                        };
                        a.restore(u);
                        assert_eq!(a.rows, rows, "seed {seed}: undo restores every row");
                        last = l;
                        previous = None;
                        continue;
                    }
                    _ => {
                        // Mostly a few habits, so runs and stray picks both happen.
                        let item = [0, 0, 0, 1, 1, 2, 3, 4, 5][rng.below(9)];
                        let q = QUERIES[rng.below(QUERIES.len())];
                        let u = a.learn(q, item, t);
                        for (i, c) in q.char_indices() {
                            credited.push(fnv1a(&q.as_bytes()[..i + c.len_utf8()]));
                        }
                        picked = Some((q, item));
                        undo = Some((u, rows_before.clone(), last_before.clone()));
                    }
                }
                // Rows a forget emptied are gone, and so is their run.
                last.retain(|k, _| a.rows.contains_key(k));
                for &k in &keys {
                    let at = at(&rows_before, k).max(at(&a.rows, k));
                    let before = rows_before.get(&k).and_then(|r| r.band(hl, band, at));
                    let after = a.rows.get(&k).and_then(|r| r.band(hl, band, at));
                    if before.map(|b| b.0) != after.map(|b| b.0) {
                        if let Some((z, w)) = after {
                            let row = &a.rows[&k];
                            assert!(w >= band, "seed {seed}: band below the threshold");
                            assert_eq!(
                                row.strongest(hl, at).map(|s| s.0),
                                Some(z),
                                "seed {seed}: not the strongest"
                            );
                        }
                        if let Some((h, _)) = before {
                            let run = credited.contains(&k)
                                && picked.is_some_and(|(_, item)| Some(item) == after.map(|b| b.0))
                                && last_before.get(&k) == after.map(|b| b.0).as_ref();
                            let gone = a
                                .rows
                                .get(&k)
                                .and_then(|r| r.weight(h, hl, at))
                                .is_none_or(|w| w < band);
                            assert!(run || gone, "seed {seed}: the band left a holder that kept its weight");
                            checked_changes += 1;
                        }
                    }
                }
                if let Some((q, item)) = picked {
                    for &k in &credited {
                        last.insert(k, item);
                    }
                    // Two picks within three days (or with the clock set back) weigh at least
                    // 1 + 0.7 * 0.966, well above the threshold.
                    if let Some((pq, pitem, pt)) = previous
                        && (pq, pitem) == (q, item)
                        && t - pt <= 3.0 * DAY
                    {
                        let s = a.summary(q.as_bytes(), at(&a.rows, fnv1a(q.as_bytes())));
                        assert_eq!(
                            s.band.map(|b| b.0),
                            Some(item),
                            "seed {seed}: two picks in a row of {q:?}"
                        );
                    }
                    previous = Some((q, item, t));
                }
            }
        }
        assert!(
            checked_changes > 100,
            "the histories change hands often enough: {checked_changes}"
        );
    }

    #[test]
    fn long_queries_are_cut_on_a_char_boundary() {
        let mut a = Affinity::new(AffinityParams::default());
        let q = "é".repeat(40);
        a.learn(&q, 1, 0.0);
        assert_eq!(a.rows.len(), 16);
    }
}
