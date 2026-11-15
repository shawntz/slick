//! Prequential evaluation: for every simulated summon, predict, then learn. Zero-query models are
//! scored on hit rate; typed rankers on the keystrokes it takes to reach the target. The typed
//! rankers run the real engine (slick-engine) with slick-match as the matcher.

use crate::baselines::{Cand, Icm, Knn, Simple, SimpleKind, TypedBaseline, TypedMode};
use crate::catalog::{Item, Kind, qwerty_neighbor};
use crate::generator::{DRIFT_DAY, Ev, N_DAYS, NEWAPP_DAY, build_persona, generate};
use crate::rng::Rng;
use slick_engine::{Context, Engine, EngineParams, Session, Source, audio, hit_flags, kind};
use slick_match::{Arena, Opts, Query, Scratch, search};
use slick_predict::context::NONE;
use slick_predict::hash::{FxMap, fnv1a};
use slick_predict::time::EPOCH_UNIX;
use slick_predict::zero_query::{K, ZqModel, ZqParams};
use std::collections::HashMap;
use std::sync::Arc;

/// Hits at ranks 1, 3 and 5.
#[derive(Default, Clone)]
pub struct Acc {
    pub n: f64,
    pub h1: f64,
    pub h3: f64,
    pub h5: f64,
}

impl Acc {
    fn add(&mut self, top: &[u32], y: u32) {
        self.n += 1.0;
        let at = top.iter().position(|&x| x == y);
        self.h1 += at.is_some_and(|p| p < 1) as u8 as f64;
        self.h3 += at.is_some_and(|p| p < 3) as u8 as f64;
        self.h5 += at.is_some_and(|p| p < 5) as u8 as f64;
    }

    fn merge(&mut self, o: &Acc) {
        self.n += o.n;
        self.h1 += o.h1;
        self.h3 += o.h3;
        self.h5 += o.h5;
    }
}

/// Evaluation periods: all, cold start, steady state, drift week, after the new app.
pub const PERIODS: [(&str, u32, u32); 5] = [
    ("all", 0, N_DAYS),
    ("d0-2 cold", 0, 3),
    ("d3-27", 3, 28),
    ("d28-34 drift", 28, 35),
    ("d35-55 newapp", 35, N_DAYS),
];

#[derive(Default, Clone)]
pub struct ZqRes {
    pub per: Vec<Acc>,
    pub newapp: Acc,
}

impl ZqRes {
    fn new() -> Self {
        ZqRes {
            per: vec![Acc::default(); PERIODS.len()],
            newapp: Acc::default(),
        }
    }

    fn add(&mut self, ev: &Ev, top: &[u32], new_app: u32) {
        for (pi, (_, a, b)) in PERIODS.iter().enumerate() {
            if ev.day >= *a && ev.day < *b {
                self.per[pi].add(top, ev.y);
            }
        }
        if ev.y == new_app && ev.day < NEWAPP_DAY + 3 {
            self.newapp.add(top, ev.y);
        }
    }

    fn merge(&mut self, o: &ZqRes) {
        for (a, b) in self.per.iter_mut().zip(&o.per) {
            a.merge(b);
        }
        self.newapp.merge(&o.newapp);
    }
}

#[derive(Default, Clone)]
pub struct TyRes {
    pub events: f64,
    pub kss: f64,
    pub first_key_top1: f64,
    pub shown: f64,
    pub flips: f64,
    pub flip_base: f64,
    pub violations: f64,
    pub typo_n: f64,
    pub typo_top3: f64,
    pub drift_kss: f64,
    pub drift_n: f64,
    pub completions: f64,
    pub completions_right: f64,
}

impl TyRes {
    fn merge(&mut self, o: &TyRes) {
        self.events += o.events;
        self.kss += o.kss;
        self.first_key_top1 += o.first_key_top1;
        self.shown += o.shown;
        self.flips += o.flips;
        self.flip_base += o.flip_base;
        self.violations += o.violations;
        self.typo_n += o.typo_n;
        self.typo_top3 += o.typo_top3;
        self.drift_kss += o.drift_kss;
        self.drift_n += o.drift_n;
        self.completions += o.completions;
        self.completions_right += o.completions_right;
    }
}

#[derive(Clone)]
#[expect(clippy::large_enum_variant, reason = "a few values per evaluation")]
pub enum ZqSpec {
    Simple(SimpleKind),
    Model(ZqParams),
    Icm,
    Knn,
    Oracle,
}

#[expect(clippy::large_enum_variant, reason = "a few values per simulated user")]
enum Zq {
    Simple(Simple),
    Model(ZqModel),
    Icm(Icm),
    Knn(Knn),
    Oracle,
}

impl Zq {
    fn new(n: usize, s: &ZqSpec) -> Zq {
        match s {
            ZqSpec::Simple(k) => Zq::Simple(Simple::new(n, *k)),
            ZqSpec::Model(p) => Zq::Model(ZqModel::new(p.clone())),
            ZqSpec::Icm => Zq::Icm(Icm::new(n)),
            ZqSpec::Knn => Zq::Knn(Knn::new(n)),
            ZqSpec::Oracle => Zq::Oracle,
        }
    }

    fn predict(&mut self, ev: &Ev, out: &mut Vec<u32>, buf: &mut Vec<(u32, f64)>) {
        match self {
            Zq::Simple(m) => m.predict(&ev.ctx, 5, out),
            Zq::Model(m) => {
                m.compute(&ev.ctx);
                m.top(5, |i| i != ev.ctx.front, buf);
                out.clear();
                out.extend(buf.iter().map(|e| e.0));
            }
            Zq::Icm(m) => m.predict(&ev.ctx, 5, out),
            Zq::Knn(m) => m.predict(&ev.ctx, 5, out),
            Zq::Oracle => {
                out.clear();
                out.extend(ev.oracle.iter().copied().filter(|&x| x != NONE));
            }
        }
    }

    fn update(&mut self, ev: &Ev) {
        match self {
            Zq::Simple(m) => m.update(&ev.ctx, ev.y),
            Zq::Model(m) => {
                m.update(&ev.ctx, ev.y);
            }
            Zq::Icm(m) => m.update(&ev.ctx, ev.y),
            Zq::Knn(m) => m.update(&ev.ctx, ev.y),
            Zq::Oracle => {}
        }
    }

    fn weights(&self) -> Option<[f64; K]> {
        match self {
            Zq::Model(m) => Some(m.w),
            _ => None,
        }
    }
}

/// What one evaluation runs.
#[derive(Clone)]
pub struct Config {
    pub zq: Vec<(String, ZqSpec)>,
    pub baselines: Vec<(String, TypedMode)>,
    pub engines: Vec<(String, EngineParams)>,
}

pub struct UserOut {
    pub zq: Vec<ZqRes>,
    pub engine_zq: Vec<ZqRes>,
    pub ty: Vec<TyRes>,
    pub weights: Vec<Option<[f64; K]>>,
}

/// The query style a user habitually types for an item.
fn intent_for(it: &Item, rng: &mut Rng) -> String {
    let r = rng.f64();
    if it.words.len() >= 2 && r < 0.15 {
        it.initials.clone()
    } else if it.words.len() >= 2 && r < 0.30 {
        let k = 1 + rng.below(it.words.len() - 1);
        it.words[k].clone()
    } else {
        it.lower.clone()
    }
}

fn engine_kind(k: Kind) -> u8 {
    match k {
        Kind::App => kind::APP,
        Kind::Command => kind::COMMAND,
        Kind::File => kind::FILE,
    }
}

fn context(ev: &Ev, keys: &[u64]) -> Context {
    let c = &ev.ctx;
    Context {
        now: EPOCH_UNIX + c.t * 60.0,
        hour: c.hour,
        weekday: c.weekday,
        frontmost: if c.front == NONE { 0 } else { keys[c.front as usize] },
        display_count: if c.ext_display { 2 } else { 1 },
        audio_route: if c.headphones {
            audio::HEADPHONES
        } else {
            audio::BUILT_IN
        },
        on_battery: c.on_battery,
        session_start: c.session_start,
        focus: c.focus,
        ..Context::default()
    }
}

/// Typing session results for one ranker on one event.
struct Typed {
    kss: f64,
    final_query: String,
}

pub fn run_user(cat: &[Item], arena: &Arena, cfg: &Config, seed: u64) -> UserOut {
    let n = cat.len();
    let mut rng = Rng::new(seed);
    let mut persona = build_persona(cat, &mut rng);
    let evs = generate(cat, &mut persona, &mut rng);
    let keys: Vec<u64> = cat.iter().map(|i| fnv1a(format!("sim:{}", i.id).as_bytes())).collect();
    let id_of: HashMap<u64, u32> = keys.iter().enumerate().map(|(i, &k)| (k, i as u32)).collect();
    let items: Vec<slick_engine::Item> = cat
        .iter()
        .map(|it| slick_engine::Item {
            key: keys[it.id as usize],
            title: it.name.clone(),
            kind: engine_kind(it.kind),
            ..slick_engine::Item::default()
        })
        .collect();
    let mut zqs: Vec<Zq> = cfg.zq.iter().map(|(_, s)| Zq::new(n, s)).collect();
    let mut zres = vec![ZqRes::new(); zqs.len()];
    let mut baselines: Vec<TypedBaseline> = cfg.baselines.iter().map(|(_, m)| TypedBaseline::new(n, *m)).collect();
    let engines: Vec<Engine> = cfg
        .engines
        .iter()
        .map(|(_, p)| {
            let e = Engine::in_memory(p.clone());
            e.replace_source(1, items.clone()).expect("catalog");
            e
        })
        .collect();
    let mut sessions: Vec<Session> = engines.iter().map(|_| Session::new()).collect();
    let mut engine_zq = vec![ZqRes::new(); engines.len()];
    let mut tres = vec![TyRes::default(); baselines.len() + engines.len()];
    let mut flipstate: Vec<FxMap<u64, (u32, u32)>> = vec![FxMap::default(); tres.len()];
    let mut intents: HashMap<u32, String> = HashMap::new();
    let mut irng = Rng::new(seed ^ 0x1234);
    let swapped_in: Vec<u32> = persona.swaps.iter().map(|x| x.1).collect();
    let mut cands_cache: HashMap<String, Arc<Vec<Cand>>> = HashMap::new();
    let mut scratch = Scratch::default();
    let mut hits = Vec::new();
    let mut matcher_cands = |q: &str, scratch: &mut Scratch| -> Arc<Vec<Cand>> {
        if let Some(c) = cands_cache.get(q) {
            return c.clone();
        }
        let opts = Opts {
            k: n,
            ..Opts::default()
        };
        search(arena, &Query::new(q), &opts, None, None, scratch, &mut hits);
        let v: Vec<Cand> = hits
            .iter()
            .map(|h| Cand {
                item: h.idx,
                tier: h.tier(),
                m: (h.rank % 10_000 - 2_000).clamp(0, 999) as f32 / 1000.0,
            })
            .collect();
        let v = Arc::new(v);
        cands_cache.insert(q.to_string(), v.clone());
        v
    };
    let (mut top, mut buf, mut ranked, mut sugg) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for ev in &evs {
        for (zi, z) in zqs.iter_mut().enumerate() {
            z.predict(ev, &mut top, &mut buf);
            zres[zi].add(ev, &top, persona.new_app);
        }
        let intent = intents
            .entry(ev.y)
            .or_insert_with(|| intent_for(&cat[ev.y as usize], &mut irng))
            .clone();
        let ends: Vec<usize> = intent.char_indices().map(|(i, c)| i + c.len_utf8()).collect();
        let typo_q: Option<String> = (irng.chance(0.1) && intent.len() >= 4).then(|| {
            let l = intent.len().min(6);
            let mut b = intent.as_bytes()[..l].to_vec();
            let pos = 1 + irng.below(l - 1);
            b[pos] = qwerty_neighbor(b[pos], irng.next_u64());
            String::from_utf8_lossy(&b).into_owned()
        });
        let drift = ev.day >= DRIFT_DAY && ev.day < DRIFT_DAY + 7 && swapped_in.contains(&ev.y);
        // Typed baselines.
        for (bi, b) in baselines.iter_mut().enumerate() {
            let tr = &mut tres[bi];
            let fs = &mut flipstate[bi];
            let typed = type_until_top(&intent, &ends, ev.y, tr, fs, |q| {
                let c = matcher_cands(q, &mut scratch);
                b.rank(ev.ctx.t, &c, &mut ranked);
                let max_tier = c.iter().map(|x| x.tier).max().unwrap_or(0);
                let tops: Vec<(u32, bool)> = ranked
                    .iter()
                    .take(8)
                    .map(|&(_, i)| (i, c.iter().find(|x| x.item == i).is_some_and(|x| x.tier < max_tier)))
                    .collect();
                tops
            });
            finish(tr, typed.kss, drift);
            if let Some(tq) = &typo_q {
                let c = matcher_cands(tq, &mut scratch);
                b.rank(ev.ctx.t, &c, &mut ranked);
                tr.typo_n += 1.0;
                tr.typo_top3 += ranked.iter().take(3).any(|x| x.1 == ev.y) as u8 as f64;
            }
            b.learn(ev.y, ev.ctx.t);
        }
        // The engine, the way the app drives it.
        let now = EPOCH_UNIX + ev.ctx.t * 60.0;
        for (ei, e) in engines.iter().enumerate() {
            let ri = baselines.len() + ei;
            e.set_context(context(ev, &keys)).expect("context");
            e.suggestions(&mut sugg).expect("suggestions");
            let tops: Vec<u32> = sugg.iter().take(5).filter_map(|(k, _)| id_of.get(k).copied()).collect();
            engine_zq[ei].add(ev, &tops, persona.new_app);
            let s = &mut sessions[ei];
            s.reset();
            let tr = &mut tres[ri];
            let fs = &mut flipstate[ri];
            let mut completions = (0.0, 0.0);
            let typed = type_until_top(&intent, &ends, ev.y, tr, fs, |q| {
                let hits = e.query(s, q, 8).expect("query");
                let max_tier = hits.iter().filter(|h| h.tier <= 6).map(|h| h.tier).max().unwrap_or(0);
                let tops: Vec<(u32, bool)> = hits
                    .iter()
                    .map(|h| {
                        let learned = h.flags & (hit_flags::AFFINITY | hit_flags::LEARNED) != 0;
                        (id_of[&h.key], h.tier <= 6 && h.tier < max_tier && !learned)
                    })
                    .collect();
                if let Ok(Some((k, _))) = e.completion(s) {
                    completions.0 += 1.0;
                    completions.1 += (id_of[&k] == ev.y) as u8 as f64;
                }
                tops
            });
            tr.completions += completions.0;
            tr.completions_right += completions.1;
            finish(tr, typed.kss, drift);
            if let Some(tq) = &typo_q {
                let hits = e.query(s, tq, 3).expect("query");
                tr.typo_n += 1.0;
                tr.typo_top3 += hits.iter().any(|h| id_of[&h.key] == ev.y) as u8 as f64;
            }
            e.record(keys[ev.y as usize], &typed.final_query, Source::Typed, 0, now)
                .expect("record");
        }
        for z in zqs.iter_mut() {
            z.update(ev);
        }
    }
    UserOut {
        zq: zres,
        engine_zq,
        ty: tres,
        weights: zqs.iter().map(Zq::weights).collect(),
    }
}

/// Types `intent` one char at a time until `target` is the top hit. `rank(q)` returns the top
/// hits as (item, weaker tier than the best without learned affinity).
fn type_until_top(
    intent: &str,
    ends: &[usize],
    target: u32,
    tr: &mut TyRes,
    flipstate: &mut FxMap<u64, (u32, u32)>,
    mut rank: impl FnMut(&str) -> Vec<(u32, bool)>,
) -> Typed {
    let mut last = Vec::new();
    for (k, &e) in ends.iter().enumerate() {
        let q = &intent[..e];
        let tops = rank(q);
        let Some(&(top1, weak)) = tops.first() else { continue };
        tr.shown += 1.0;
        tr.violations += weak as u8 as f64;
        let qk = fnv1a(q.as_bytes());
        if let Some(&(lt, ly)) = flipstate.get(&qk) {
            tr.flip_base += 1.0;
            tr.flips += (lt != top1 && ly == lt) as u8 as f64;
        }
        flipstate.insert(qk, (top1, target));
        if top1 == target {
            tr.first_key_top1 += (k == 0) as u8 as f64;
            return Typed {
                kss: (k + 2) as f64,
                final_query: q.to_string(),
            };
        }
        last = tops;
    }
    let penalty = match last.iter().position(|x| x.0 == target) {
        Some(rk) if rk < 8 => rk as f64 + 1.0,
        _ => 10.0,
    };
    Typed {
        kss: ends.len() as f64 + penalty,
        final_query: intent.to_string(),
    }
}

fn finish(tr: &mut TyRes, kss: f64, drift: bool) {
    tr.events += 1.0;
    tr.kss += kss;
    if drift {
        tr.drift_kss += kss;
        tr.drift_n += 1.0;
    }
}

/// Totals over users.
pub struct Totals {
    pub zq: Vec<ZqRes>,
    pub engine_zq: Vec<ZqRes>,
    pub ty: Vec<TyRes>,
    pub events: f64,
    pub weights: Vec<Vec<[f64; K]>>,
}

/// Runs every seed on 10 threads.
pub fn run_all(cat: &Arc<Vec<Item>>, cfg: &Config, seeds: &[u64]) -> Totals {
    let arena = Arc::new(Arena::from_titles(cat.iter().map(|i| i.name.as_str())));
    let threads = 10usize;
    let results: Vec<UserOut> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..threads)
            .map(|k| {
                let (cat, arena, cfg) = (cat.clone(), arena.clone(), cfg.clone());
                let mine: Vec<u64> = seeds.iter().copied().skip(k).step_by(threads).collect();
                s.spawn(move || {
                    mine.iter()
                        .map(|&sd| run_user(&cat, &arena, &cfg, sd))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().expect("simulation thread"))
            .collect()
    });
    let mut t = Totals {
        zq: vec![ZqRes::new(); cfg.zq.len()],
        engine_zq: vec![ZqRes::new(); cfg.engines.len()],
        ty: vec![TyRes::default(); cfg.baselines.len() + cfg.engines.len()],
        events: 0.0,
        weights: vec![Vec::new(); cfg.zq.len()],
    };
    for r in &results {
        r.zq.iter().zip(t.zq.iter_mut()).for_each(|(a, b)| b.merge(a));
        r.engine_zq
            .iter()
            .zip(t.engine_zq.iter_mut())
            .for_each(|(a, b)| b.merge(a));
        r.ty.iter().zip(t.ty.iter_mut()).for_each(|(a, b)| b.merge(a));
        for (w, all) in r.weights.iter().zip(t.weights.iter_mut()) {
            all.extend(w.iter());
        }
        t.events += r.zq.first().or(r.engine_zq.first()).map_or(0.0, |x| x.per[0].n);
    }
    t
}
