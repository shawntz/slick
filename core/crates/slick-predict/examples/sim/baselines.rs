//! Baselines the production models are compared with: MRU, MFU, frecency and zoxide-style
//! zero-query rankers, an interpolated mixture, kNN over contexts, and typed rankers that add
//! recency or popularity to the text tier.

use crate::generator::DAY;
use slick_predict::context::{Ctx, F_HOUR, NF, NONE, feature_values};
use slick_predict::counts::CondCounts;
use slick_predict::decay::DecayCounter;

/// The best `k` (at most 8) of `cands` by `scores`, skipping `exclude`.
pub fn top_k_excluding(cands: &[u32], scores: &[f64], exclude: u32, k: usize, out: &mut Vec<u32>) {
    out.clear();
    let k = k.min(8);
    let mut best: [(f64, u32); 8] = [(f64::NEG_INFINITY, NONE); 8];
    for (j, &i) in cands.iter().enumerate() {
        let s = scores[j];
        if i == exclude || s <= best[k - 1].0 {
            continue;
        }
        let mut p = k - 1;
        while p > 0 && best[p - 1].0 < s {
            best[p] = best[p - 1];
            p -= 1;
        }
        best[p] = (s, i);
    }
    out.extend(best.iter().take(k).filter(|b| b.1 != NONE).map(|b| b.1));
}

/// One-signal zero-query rankers.
#[derive(Clone, Copy, Debug)]
pub enum SimpleKind {
    Mru,
    Mfu,
    /// Half-life in minutes.
    Frecency(f64),
    Zoxide,
}

pub struct Simple {
    kind: SimpleKind,
    last_used: Vec<f64>,
    count: Vec<f64>,
    frec: Vec<DecayCounter>,
    cands: Vec<u32>,
    seen: Vec<bool>,
    scores: Vec<f64>,
}

impl Simple {
    pub fn new(n: usize, kind: SimpleKind) -> Self {
        Simple {
            kind,
            last_used: vec![f64::NEG_INFINITY; n],
            count: vec![0.0; n],
            frec: vec![DecayCounter::default(); n],
            cands: Vec::new(),
            seen: vec![false; n],
            scores: Vec::new(),
        }
    }

    pub fn predict(&mut self, ctx: &Ctx, k: usize, out: &mut Vec<u32>) {
        let t = ctx.t;
        self.scores.clear();
        for &i in &self.cands {
            let i = i as usize;
            let s = match self.kind {
                SimpleKind::Mru => self.last_used[i],
                SimpleKind::Mfu => self.count[i] + 1e-15 * self.last_used[i].max(0.0),
                SimpleKind::Frecency(_) => self.frec[i].l as f64,
                SimpleKind::Zoxide => {
                    let dt = t - self.last_used[i];
                    let m = if dt < 60.0 {
                        4.0
                    } else if dt < DAY {
                        2.0
                    } else if dt < 7.0 * DAY {
                        0.5
                    } else {
                        0.25
                    };
                    self.count[i] * m
                }
            };
            self.scores.push(s);
        }
        top_k_excluding(&self.cands, &self.scores, ctx.front, k, out);
    }

    pub fn update(&mut self, ctx: &Ctx, y: u32) {
        let i = y as usize;
        if !self.seen[i] {
            self.seen[i] = true;
            self.cands.push(y);
        }
        self.last_used[i] = ctx.t;
        self.count[i] += 1.0;
        if let SimpleKind::Zoxide = self.kind {
            // zoxide ages counts once their total passes a cap (launcher scale: 1,000)
            let total: f64 = self.cands.iter().map(|&c| self.count[c as usize]).sum();
            if total > 1000.0 {
                for &c in &self.cands {
                    self.count[c as usize] *= 0.9;
                }
            }
        }
        if let SimpleKind::Frecency(h) = self.kind {
            self.frec[i].add(ctx.t, 1.0, h);
        }
    }
}

/// Interpolated conditional mixture: P(i|x) = sum_f lambda_f P_f(i|v_f) + lambda_0 P0(i), with
/// the lambdas updated by a Bayesian mixture with fixed-share forgetting.
pub struct Icm {
    cc: CondCounts,
    prior: Vec<DecayCounter>,
    h_prior: f64,
    mu: f64,
    lam: [f64; NF + 1],
    cands: Vec<u32>,
    pos: Vec<u32>,
    p0: Vec<f64>,
    mix: Vec<f64>,
    comp: Vec<[f64; NF + 1]>,
}

impl Icm {
    pub fn new(n: usize) -> Self {
        Icm {
            cc: CondCounts::new(30.0 * DAY, 0.5),
            prior: vec![DecayCounter::default(); n],
            h_prior: 14.0 * DAY,
            mu: 3.0,
            lam: [1.0 / (NF as f64 + 1.0); NF + 1],
            cands: Vec::new(),
            pos: vec![NONE; n],
            p0: Vec::new(),
            mix: Vec::new(),
            comp: Vec::new(),
        }
    }

    fn compute(&mut self, ctx: &Ctx) {
        let t = ctx.t;
        let n = self.cands.len();
        self.p0.resize(n, 0.0);
        self.mix.resize(n, 0.0);
        self.comp.resize(n, [0.0; NF + 1]);
        let mut sum = 0.0;
        for (j, &i) in self.cands.iter().enumerate() {
            let f = self.prior[i as usize].value(t, self.h_prior);
            self.p0[j] = f;
            sum += f;
        }
        let eps = 0.05;
        for p0 in &mut self.p0[..n] {
            *p0 = (*p0 + eps) / (sum + eps * n as f64);
        }
        let vals = feature_values(ctx);
        let mus = self.mu * self.cc.scale(t);
        for j in 0..n {
            self.comp[j][NF] = self.p0[j];
        }
        for (f, &v) in vals.iter().enumerate() {
            let row = if v == NONE { None } else { self.cc.tables[f].get(&v) };
            let total = row.map_or(0.0, |r| r.total as f64);
            for j in 0..n {
                self.comp[j][f] = mus * self.p0[j] / (total + mus);
            }
            if let Some(r) = row {
                for &(item, c) in &r.items {
                    let j = self.pos[item as usize];
                    if j != NONE {
                        let j = j as usize;
                        self.comp[j][f] = (c as f64 + mus * self.p0[j]) / (total + mus);
                    }
                }
            }
        }
        for j in 0..n {
            self.mix[j] = (0..=NF).map(|f| self.lam[f] * self.comp[j][f]).sum();
        }
    }

    pub fn predict(&mut self, ctx: &Ctx, k: usize, out: &mut Vec<u32>) {
        self.compute(ctx);
        top_k_excluding(&self.cands, &self.mix, ctx.front, k, out);
    }

    pub fn update(&mut self, ctx: &Ctx, y: u32) {
        if self.pos[y as usize] == NONE {
            self.pos[y as usize] = self.cands.len() as u32;
            self.cands.push(y);
        }
        self.compute(ctx);
        let jy = self.pos[y as usize] as usize;
        let mut z = 0.0;
        for f in 0..=NF {
            self.lam[f] *= self.comp[jy][f].max(1e-9);
            z += self.lam[f];
        }
        let alpha = 0.02;
        for lam in &mut self.lam[..=NF] {
            *lam = (1.0 - alpha) * *lam / z + alpha / (NF as f64 + 1.0);
        }
        self.cc.add(&feature_values(ctx), y, ctx.t, 1.0);
        self.prior[y as usize].add(ctx.t, 1.0, self.h_prior);
    }
}

/// kNN over recent contexts: vote_i = sum over past events e with item i of
/// exp(beta * sim(x, x_e)) * 2^(-age/H).
pub struct Knn {
    buf: std::collections::VecDeque<(f64, [u32; NF], u32)>,
    cap: usize,
    h_age: f64,
    beta: f64,
    a: [f64; NF],
    votes: Vec<f64>,
    cands: Vec<u32>,
    seen: Vec<bool>,
    scores: Vec<f64>,
}

impl Knn {
    pub fn new(n: usize) -> Self {
        Knn {
            buf: std::collections::VecDeque::new(),
            cap: 2000,
            h_age: 14.0 * DAY,
            beta: 1.0,
            a: [1.0, 1.0, 0.5, 1.5, 2.0, 1.0, 0.5, 0.5, 0.3, 0.3, 0.7],
            votes: vec![0.0; n],
            cands: Vec::new(),
            seen: vec![false; n],
            scores: Vec::new(),
        }
    }

    pub fn predict(&mut self, ctx: &Ctx, k: usize, out: &mut Vec<u32>) {
        let vals = feature_values(ctx);
        for &c in &self.cands {
            self.votes[c as usize] = 0.0;
        }
        for (te, ve, y) in self.buf.iter() {
            let mut s = 0.0;
            for f in 0..NF {
                if f == F_HOUR {
                    let d = (vals[f] as i32 - ve[f] as i32).rem_euclid(24);
                    let d = d.min(24 - d) as f64;
                    s += self.a[f] * (-(d * d) / 4.5).exp();
                } else if vals[f] != NONE && vals[f] == ve[f] {
                    s += self.a[f];
                }
            }
            self.votes[*y as usize] += (self.beta * s).exp() * (-(ctx.t - te) / self.h_age).exp2();
        }
        self.scores.clear();
        self.scores.extend(self.cands.iter().map(|&c| self.votes[c as usize]));
        top_k_excluding(&self.cands, &self.scores, ctx.front, k, out);
    }

    pub fn update(&mut self, ctx: &Ctx, y: u32) {
        if !self.seen[y as usize] {
            self.seen[y as usize] = true;
            self.cands.push(y);
        }
        self.buf.push_back((ctx.t, feature_values(ctx), y));
        if self.buf.len() > self.cap {
            self.buf.pop_front();
        }
    }
}

/// Typed rankers without learned affinity: the text tier plus one popularity signal.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TypedMode {
    Text,
    Mru,
    Mfu,
    Frecency,
    /// Text score multiplied by popularity, which lets popularity cross tiers.
    PopularityDominant,
}

/// One matched item for a typed query: its tier (0..=6) and text quality in [0, 1).
#[derive(Clone, Copy, Debug)]
pub struct Cand {
    pub item: u32,
    pub tier: u8,
    pub m: f32,
}

pub struct TypedBaseline {
    mode: TypedMode,
    frec: Vec<DecayCounter>,
    last_used: Vec<f64>,
    count: Vec<f64>,
    max_l: f64,
}

impl TypedBaseline {
    const H_FREC: f64 = 7.0 * DAY;

    pub fn new(n: usize, mode: TypedMode) -> Self {
        TypedBaseline {
            mode,
            frec: vec![DecayCounter::default(); n],
            last_used: vec![f64::NEG_INFINITY; n],
            count: vec![0.0; n],
            max_l: f64::NEG_INFINITY,
        }
    }

    fn frec01(&self, i: usize) -> f64 {
        let l = self.frec[i].l as f64;
        if l.is_finite() {
            (1.0 + (l - self.max_l) / 8.0).clamp(0.0, 1.0)
        } else {
            0.0
        }
    }

    /// Scores `cands` into `out`, best first, ties by lower id.
    pub fn rank(&self, t: f64, cands: &[Cand], out: &mut Vec<(f64, u32)>) {
        out.clear();
        for c in cands {
            let i = c.item as usize;
            let base = c.tier as f64 * 1000.0 + 100.0 * c.m as f64;
            let s = match self.mode {
                TypedMode::Text => base,
                TypedMode::Mru => {
                    let dt = t - self.last_used[i];
                    base + if dt.is_finite() { 900.0 / (1.0 + dt / 60.0) } else { 0.0 }
                }
                TypedMode::Mfu => base + 400.0 * (1.0 + self.count[i]).ln() / 501f64.ln(),
                TypedMode::Frecency => base + 400.0 * self.frec01(i),
                TypedMode::PopularityDominant => base * (1.0 + 2.0 * self.frec01(i)),
            };
            out.push((s, c.item));
        }
        out.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
    }

    pub fn learn(&mut self, y: u32, t: f64) {
        let i = y as usize;
        self.frec[i].add(t, 1.0, Self::H_FREC);
        self.max_l = self.max_l.max(self.frec[i].l as f64);
        self.last_used[i] = t;
        self.count[i] += 1.0;
    }
}
