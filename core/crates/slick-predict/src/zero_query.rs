//! The zero-query model behind the Suggested list: a log-linear product of experts.
//!
//! For each candidate item i the model computes features
//!
//! ```text
//! phi0 = ln P0(i)                 3-day frecency share
//! phi1 = ln Pshort(i)             1-day frecency share
//! phi2 = exp(-(t - t_last)/5 min) recency
//! phi3 = exp(-(t - t_first)/2 d)  novelty
//! phi4+f = ln(1 + c_f(v_f, i) / (mu S(t) P0(i)))   log-lift of each context feature
//! ```
//!
//! and scores `s(i) = sum_k w_k phi_k(i)`. With every exponent at 1 this is naive Bayes smoothed
//! toward P0. The exponents start at population priors and are learned online by softmax SGD, which
//! keeps the model from overcounting correlated features and lets it follow drift.

use crate::context::{Ctx, NF, NONE, feature_values};
use crate::counts::{CondCounts, RowUndo};
use crate::decay::DecayCounter;
use crate::time::DAY;

/// Number of experts: four item terms plus one log-lift per context feature.
pub const K: usize = 4 + NF;
/// Index of the first log-lift expert.
pub const KF: usize = 4;
/// Names of the item experts, for the inspector.
pub const ITEM_EXPERTS: [&str; KF] = ["frecency 3 d", "frecency 1 d", "recency", "novelty"];
/// Most candidates scored per prediction: the most frecent by 3-day frecency. Less frecent items
/// have negligible probability, and the cap bounds the cost for users with thousands of items.
pub const MAX_SCORED: usize = 256;

/// Constants of the zero-query model.
#[derive(Clone, Debug, PartialEq)]
pub struct ZqParams {
    /// Half-life of P0, minutes.
    pub h_prior: f64,
    /// Half-life of Pshort, minutes.
    pub h_short: f64,
    /// Half-life of the conditional counts, minutes.
    pub h_counts: f64,
    /// Pseudo-count strength of the log-lifts.
    pub mu: f64,
    /// Recency time constant, minutes.
    pub tau_rec: f64,
    /// Novelty time constant, minutes.
    pub tau_novel: f64,
    /// Additive floor of the frecency shares.
    pub eps: f64,
    /// SGD learning rate after warm-up.
    pub lr: f64,
    /// Pull of each exponent toward its prior.
    pub l2: f64,
    /// Updates over which the learning rate ramps up from 0.
    pub warmup: f64,
    /// Population-prior exponents, in expert order.
    pub w_init: [f64; K],
    /// Lowest exponent.
    pub w_min: f64,
    /// Highest exponent.
    pub w_max: f64,
    /// Share of an hour count added to the neighbouring hours.
    pub hour_spread: f32,
}

impl Default for ZqParams {
    fn default() -> Self {
        ZqParams {
            h_prior: 3.0 * DAY,
            h_short: 1.0 * DAY,
            h_counts: 60.0 * DAY,
            mu: 10.0,
            tau_rec: 5.0,
            tau_novel: 2.0 * DAY,
            eps: 0.05,
            lr: 0.01,
            l2: 0.01,
            warmup: 300.0,
            // Mean of the exponents learned by 30 simulated tuning users. Order: frecency 3 d,
            // frecency 1 d, recency, novelty, then the features in `context::FEATURE_NAMES` order.
            w_init: [
                0.5, 0.55, 0.25, 0.0, 0.1, 0.5, 0.0, 0.4, 0.25, 0.08, 0.3, 0.25, 0.1, 0.05, 0.0,
            ],
            w_min: -1.0,
            w_max: 4.0,
            hour_spread: 0.5,
        }
    }
}

/// Everything one `update` changed, so it can be undone exactly.
#[derive(Clone, Debug)]
pub struct ZqUndo {
    w: [f64; K],
    n_updates: f64,
    item: u32,
    item_state: ItemState,
    was_candidate: bool,
    rows: Option<Vec<RowUndo>>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct ItemState {
    prior: DecayCounter,
    short: DecayCounter,
    last_used: f64,
    first_used: f64,
}

/// The zero-query model over items numbered by learn id.
#[derive(Clone, Debug)]
pub struct ZqModel {
    /// Constants.
    pub p: ZqParams,
    /// Per item: 3-day frecency.
    pub prior: Vec<DecayCounter>,
    /// Per item: 1-day frecency.
    pub short: Vec<DecayCounter>,
    /// Per item: time of the last use, minutes (negative infinity when never).
    pub last_used: Vec<f64>,
    /// Per item: time of the first use, minutes (negative infinity when never).
    pub first_used: Vec<f64>,
    /// Updates so far (drives the learning-rate warm-up).
    pub n_updates: f64,
    /// Items with any use or seed.
    pub cands: Vec<u32>,
    pos: Vec<u32>,
    /// The candidates scored by `compute` (at most `MAX_SCORED`, plus one forced item).
    work: Vec<u32>,
    /// Index into `work` per item, or `NONE`.
    wpos: Vec<u32>,
    work_dirty: bool,
    select: Vec<(f32, u32)>,
    /// Conditional counts.
    pub cc: CondCounts,
    /// Current exponents.
    pub w: [f64; K],
    phi: Vec<[f32; K]>,
    fbuf: Vec<f64>,
    sbuf: Vec<f64>,
    p0: Vec<f64>,
    scores: Vec<f64>,
}

impl ZqModel {
    /// An empty model.
    pub fn new(p: ZqParams) -> Self {
        let w = p.w_init;
        let cc = CondCounts::new(p.h_counts, p.hour_spread);
        ZqModel {
            p,
            prior: Vec::new(),
            short: Vec::new(),
            last_used: Vec::new(),
            first_used: Vec::new(),
            n_updates: 0.0,
            cands: Vec::new(),
            pos: Vec::new(),
            work: Vec::new(),
            wpos: Vec::new(),
            work_dirty: true,
            select: Vec::new(),
            cc,
            w,
            phi: Vec::new(),
            fbuf: Vec::new(),
            sbuf: Vec::new(),
            p0: Vec::new(),
            scores: Vec::new(),
        }
    }

    /// Grows the per-item arrays to hold item ids below `n`.
    pub fn ensure_items(&mut self, n: usize) {
        if self.prior.len() < n {
            self.prior.resize(n, DecayCounter::default());
            self.short.resize(n, DecayCounter::default());
            self.last_used.resize(n, f64::NEG_INFINITY);
            self.first_used.resize(n, f64::NEG_INFINITY);
            self.pos.resize(n, NONE);
            self.wpos.resize(n, NONE);
        }
    }

    fn ensure_cand(&mut self, i: u32) -> bool {
        self.ensure_items(i as usize + 1);
        if self.pos[i as usize] != NONE {
            return true;
        }
        self.pos[i as usize] = self.cands.len() as u32;
        self.cands.push(i);
        self.work_dirty = true;
        false
    }

    fn remove_cand(&mut self, i: u32) {
        let Some(&p) = self.pos.get(i as usize) else { return };
        if p == NONE {
            return;
        }
        self.cands.swap_remove(p as usize);
        if let Some(&moved) = self.cands.get(p as usize) {
            self.pos[moved as usize] = p;
        }
        self.pos[i as usize] = NONE;
        self.work_dirty = true;
    }

    /// Chooses the candidates `compute` scores: all of them, or the `MAX_SCORED` most frecent.
    /// `extra` is scored as well (the item being learned from).
    fn ensure_work(&mut self, extra: u32) {
        if self.work_dirty {
            for &i in &self.work {
                self.wpos[i as usize] = NONE;
            }
            self.work.clear();
            if self.cands.len() <= MAX_SCORED {
                self.work.extend_from_slice(&self.cands);
            } else {
                self.select.clear();
                self.select
                    .extend(self.cands.iter().map(|&i| (self.prior[i as usize].l, i)));
                let by_frecency = |a: &(f32, u32), b: &(f32, u32)| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1));
                self.select.select_nth_unstable_by(MAX_SCORED - 1, by_frecency);
                self.select.truncate(MAX_SCORED);
                self.select.sort_unstable_by_key(|e| e.1);
                self.work.extend(self.select.iter().map(|e| e.1));
            }
            for (j, &i) in self.work.iter().enumerate() {
                self.wpos[i as usize] = j as u32;
            }
            self.work_dirty = false;
        }
        if extra != NONE && self.wpos[extra as usize] == NONE {
            self.wpos[extra as usize] = self.work.len() as u32;
            self.work.push(extra);
            self.work_dirty = true;
        }
    }

    /// First-run seeding: a virtual use of weight `w` at time `t`, counted in P0 only, never in
    /// the context tables.
    pub fn seed(&mut self, i: u32, t: f64, w: f64) {
        self.ensure_cand(i);
        self.prior[i as usize].add(t, w, self.p.h_prior);
        self.work_dirty = true;
    }

    /// Scores the candidates for `ctx`. Cost: O(scored candidates + context row sizes). Read the
    /// result with `top` and `probabilities`.
    pub fn compute(&mut self, ctx: &Ctx) {
        self.compute_with(ctx, NONE);
    }

    fn compute_with(&mut self, ctx: &Ctx, extra: u32) {
        self.ensure_work(extra);
        let t = ctx.t;
        let n = self.work.len();
        self.phi.clear();
        self.phi.resize(n, [0f32; K]);
        self.fbuf.resize(n, 0.0);
        self.sbuf.resize(n, 0.0);
        self.p0.resize(n, 0.0);
        self.scores.resize(n, 0.0);
        let (mut sum_f, mut sum_s) = (0.0, 0.0);
        for (j, &i) in self.work.iter().enumerate() {
            let f = self.prior[i as usize].value(t, self.p.h_prior);
            let s = self.short[i as usize].value(t, self.p.h_short);
            self.fbuf[j] = f;
            self.sbuf[j] = s;
            sum_f += f;
            sum_s += s;
        }
        let eps = self.p.eps;
        let df = sum_f + eps * n as f64;
        let ds = sum_s + eps * n as f64;
        for (j, &i) in self.work.iter().enumerate() {
            let p0 = (self.fbuf[j] + eps) / df;
            self.p0[j] = p0;
            let phi = &mut self.phi[j];
            phi[0] = p0.ln() as f32;
            phi[1] = ((self.sbuf[j] + eps) / ds).ln() as f32;
            let since = t - self.last_used[i as usize];
            phi[2] = if since.is_finite() {
                (-since.max(0.0) / self.p.tau_rec).exp() as f32
            } else {
                0.0
            };
            let age = t - self.first_used[i as usize];
            phi[3] = if age.is_finite() {
                (-age.max(0.0) / self.p.tau_novel).exp() as f32
            } else {
                0.0
            };
        }
        let vals = feature_values(ctx);
        let mus = self.p.mu * self.cc.scale(t);
        for (f, &v) in vals.iter().enumerate() {
            if v == NONE {
                continue;
            }
            let Some(row) = self.cc.tables[f].get(&v) else { continue };
            for &(item, c) in &row.items {
                let Some(&j) = self.wpos.get(item as usize) else {
                    continue;
                };
                if j != NONE {
                    let j = j as usize;
                    self.phi[j][KF + f] = (1.0 + c as f64 / (mus * self.p0[j])).ln() as f32;
                }
            }
        }
        for (score, phi) in self.scores.iter_mut().zip(&self.phi) {
            *score = self.w.iter().zip(phi).map(|(w, &x)| w * x as f64).sum();
        }
    }

    /// The top `k` items by score among those `allowed` accepts, best first, into `out`. Ties break
    /// by lower id. Call `compute` first.
    pub fn top(&self, k: usize, allowed: impl Fn(u32) -> bool, out: &mut Vec<(u32, f64)>) {
        out.clear();
        if k == 0 {
            return;
        }
        for (j, &i) in self.work.iter().enumerate() {
            if !allowed(i) {
                continue;
            }
            let s = self.scores[j];
            let better = |o: &(u32, f64)| s > o.1 || (s == o.1 && i < o.0);
            if out.len() == k && !out.last().is_some_and(better) {
                continue;
            }
            let at = out.iter().position(better).unwrap_or(out.len());
            out.insert(at, (i, s));
            out.truncate(k);
        }
    }

    /// Softmax probabilities of the allowed candidates, written as (item, p) into `out`, and the
    /// largest p. Call `compute` first.
    pub fn probabilities(&self, allowed: impl Fn(u32) -> bool, out: &mut Vec<(u32, f64)>) -> f64 {
        out.clear();
        let max = self
            .work
            .iter()
            .zip(&self.scores)
            .filter(|&(&i, _)| allowed(i))
            .map(|(_, &s)| s)
            .fold(f64::NEG_INFINITY, f64::max);
        if max == f64::NEG_INFINITY {
            return 0.0;
        }
        let mut z = 0.0;
        for (&i, &s) in self.work.iter().zip(&self.scores) {
            if allowed(i) {
                let e = (s - max).exp();
                z += e;
                out.push((i, e));
            }
        }
        let mut pmax: f64 = 0.0;
        for e in out.iter_mut() {
            e.1 /= z;
            pmax = pmax.max(e.1);
        }
        pmax
    }

    /// Learns from executing `y` in `ctx`: one softmax SGD step on the exponents (the frontmost
    /// app excluded, as in prediction), then the counts. Returns what it changed, for undo.
    pub fn update(&mut self, ctx: &Ctx, y: u32) -> ZqUndo {
        let was_candidate = self.ensure_cand(y);
        let before = ZqUndo {
            w: self.w,
            n_updates: self.n_updates,
            item: y,
            item_state: ItemState {
                prior: self.prior[y as usize],
                short: self.short[y as usize],
                last_used: self.last_used[y as usize],
                first_used: self.first_used[y as usize],
            },
            was_candidate,
            rows: None,
        };
        if self.cands.len() > 1 {
            self.sgd_step(ctx, y);
        }
        self.work_dirty = true;
        let vals = feature_values(ctx);
        let rows = self.cc.add(&vals, y, ctx.t, 1.0);
        let i = y as usize;
        self.prior[i].add(ctx.t, 1.0, self.p.h_prior);
        self.short[i].add(ctx.t, 1.0, self.p.h_short);
        self.last_used[i] = ctx.t;
        if !self.first_used[i].is_finite() {
            self.first_used[i] = ctx.t;
        }
        self.n_updates += 1.0;
        ZqUndo { rows, ..before }
    }

    fn sgd_step(&mut self, ctx: &Ctx, y: u32) {
        self.compute_with(ctx, y);
        let front = ctx.front;
        let max = self
            .work
            .iter()
            .zip(&self.scores)
            .filter(|&(&i, _)| i != front)
            .map(|(_, &s)| s)
            .fold(f64::NEG_INFINITY, f64::max);
        let mut z = 0.0;
        let mut expect = [0f64; K];
        for (j, &i) in self.work.iter().enumerate() {
            if i == front {
                continue;
            }
            let e = (self.scores[j] - max).exp();
            z += e;
            for (k, x) in expect.iter_mut().enumerate() {
                *x += e * self.phi[j][k] as f64;
            }
        }
        let jy = self.wpos[y as usize] as usize;
        let lr = self.p.lr * (self.n_updates / self.p.warmup).min(1.0);
        for k in 0..K {
            let g = self.phi[jy][k] as f64 - expect[k] / z;
            self.w[k] += lr * (g - self.p.l2 * (self.w[k] - self.p.w_init[k]));
            self.w[k] = self.w[k].clamp(self.p.w_min, self.p.w_max);
        }
    }

    /// Reverts an `update`. Returns false when the update cannot be undone (a count rescale
    /// happened in between), in which case nothing changes.
    pub fn undo(&mut self, u: ZqUndo) -> bool {
        let Some(rows) = u.rows else { return false };
        self.cc.restore(rows);
        self.w = u.w;
        self.n_updates = u.n_updates;
        let i = u.item as usize;
        self.prior[i] = u.item_state.prior;
        self.short[i] = u.item_state.short;
        self.last_used[i] = u.item_state.last_used;
        self.first_used[i] = u.item_state.first_used;
        if !u.was_candidate {
            self.remove_cand(u.item);
        }
        self.work_dirty = true;
        true
    }

    /// Forgets item `i`: its counters, its candidacy and every context count that mentions it.
    /// The exponents keep what they learned, which is aggregate and names no item.
    pub fn forget(&mut self, i: u32) {
        if (i as usize) < self.prior.len() {
            let i = i as usize;
            self.prior[i] = DecayCounter::default();
            self.short[i] = DecayCounter::default();
            self.last_used[i] = f64::NEG_INFINITY;
            self.first_used[i] = f64::NEG_INFINITY;
        }
        self.remove_cand(i);
        self.cc.forget(i);
        self.work_dirty = true;
    }

    /// Replaces the candidate list, keeping the given order (after loading a snapshot, so sums
    /// over candidates run in the same order as before the save).
    pub fn set_candidates(&mut self, cands: Vec<u32>) {
        self.pos.iter_mut().for_each(|p| *p = NONE);
        self.cands.clear();
        for i in cands {
            self.ensure_cand(i);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(t: f64, hour: u8, front: u32) -> Ctx {
        Ctx {
            t,
            hour,
            front,
            ..Ctx::default()
        }
    }

    #[test]
    fn learns_hour_habits_and_skips_the_frontmost_app() {
        let mut m = ZqModel::new(ZqParams::default());
        let mut t = 0.0;
        for day in 0..20 {
            t = day as f64 * DAY;
            m.update(&ctx(t + 9.0 * 60.0, 9, NONE), 1);
            m.update(&ctx(t + 20.0 * 60.0, 20, NONE), 2);
        }
        let mut out = Vec::new();
        m.compute(&ctx(t + DAY + 9.0 * 60.0, 9, NONE));
        m.top(1, |_| true, &mut out);
        assert_eq!(out[0].0, 1);
        m.compute(&ctx(t + DAY + 20.0 * 60.0, 20, NONE));
        m.top(1, |_| true, &mut out);
        assert_eq!(out[0].0, 2);
        m.top(1, |i| i != 2, &mut out);
        assert_eq!(out[0].0, 1);
    }

    #[test]
    fn undo_restores_the_model_exactly() {
        let mut m = ZqModel::new(ZqParams::default());
        for k in 0..400 {
            m.update(&ctx(k as f64 * 30.0, (k % 24) as u8, 3), k % 5);
        }
        let before = m.clone();
        let u = m.update(&ctx(400.0 * 30.0, 4, 3), 9);
        assert!(m.undo(u));
        assert_eq!(m.w, before.w);
        assert_eq!(m.cands, before.cands);
        assert_eq!(m.cc, before.cc);
        assert_eq!(m.prior[..before.prior.len()], before.prior[..]);
        assert!(m.prior[before.prior.len()..].iter().all(|c| c.is_empty()));
        assert_eq!(m.n_updates, before.n_updates);
    }

    #[test]
    fn only_the_most_frecent_candidates_are_scored() {
        let mut m = ZqModel::new(ZqParams::default());
        for i in 0..(MAX_SCORED as u32 + 100) {
            m.seed(i, 0.0, 1.0 + i as f64);
        }
        m.compute(&ctx(10.0, 9, NONE));
        assert_eq!(m.work.len(), MAX_SCORED);
        assert!(m.work.iter().all(|&i| i >= 100), "the least frecent are left out");
        let mut out = Vec::new();
        m.top(1, |_| true, &mut out);
        assert_eq!(out[0].0, MAX_SCORED as u32 + 99);
        // The item being learned from is scored even when it is not among them.
        m.update(&ctx(11.0, 9, NONE), 5);
        m.compute(&ctx(12.0, 9, NONE));
        assert!(m.work.len() <= MAX_SCORED + 1);
    }

    #[test]
    fn forget_removes_the_item_everywhere() {
        let mut m = ZqModel::new(ZqParams::default());
        m.update(&ctx(0.0, 9, NONE), 1);
        m.update(
            &Ctx {
                prev: 1,
                since_prev: 1.0,
                ..ctx(1.0, 9, NONE)
            },
            2,
        );
        m.forget(1);
        assert!(!m.cands.contains(&1));
        assert!(
            m.cc.tables
                .iter()
                .all(|t| t.values().all(|r| r.items.iter().all(|e| e.0 != 1)))
        );
        assert!(!m.cc.tables[4].contains_key(&1));
    }
}
