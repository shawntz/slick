//! The session simulator that tunes the ranking constants.
//!
//! Synthetic users (see `generator`) summon the launcher for eight weeks. Zero-query models are
//! scored on hit rate; typed rankers on keystrokes to reach the target, with the real engine and
//! slick-match as the matcher.
//!
//! ```text
//! cargo run --release -p slick-predict --example sim -- eval [users] [first seed]
//! cargo run --release -p slick-predict --example sim -- tune-typed   (seeds 0..29)
//! cargo run --release -p slick-predict --example sim -- tune-zq      (seeds 0..29)
//! cargo run --release -p slick-predict --example sim -- calib        (generator statistics)
//! ```
//!
//! Evaluation seeds start at 1000 and never overlap the tuning seeds 0..29.

mod baselines;
mod catalog;
mod evaluate;
mod generator;
mod rng;

use baselines::{SimpleKind, TypedMode};
use catalog::{Kind, build_catalog};
use evaluate::{Config, PERIODS, Totals, TyRes, ZqRes, ZqSpec, run_all};
use generator::{DAY, build_persona, generate};
use rng::Rng;
use slick_engine::EngineParams;
use slick_predict::context::FEATURE_NAMES;
use slick_predict::zero_query::{ITEM_EXPERTS, K, ZqParams};
use std::sync::Arc;

fn pc(x: f64, n: f64) -> f64 {
    100.0 * x / n.max(1.0)
}

fn print_zq(names: &[String], z: &[ZqRes]) {
    print!("| model | top1 | top3 | top5 |");
    for (n, _, _) in PERIODS.iter().skip(1) {
        print!(" {n} top1/top3 |");
    }
    println!(" new app top3, first 3 d |");
    println!("|---|---|---|---|{}---|", "---|".repeat(PERIODS.len() - 1));
    for (name, r) in names.iter().zip(z) {
        let a = &r.per[0];
        print!(
            "| {name} | {:.1} | {:.1} | {:.1} |",
            pc(a.h1, a.n),
            pc(a.h3, a.n),
            pc(a.h5, a.n)
        );
        for a in r.per.iter().skip(1) {
            print!(" {:.1} / {:.1} |", pc(a.h1, a.n), pc(a.h3, a.n));
        }
        println!(" {:.1} |", pc(r.newapp.h3, r.newapp.n));
    }
}

fn print_typed(names: &[String], t: &[TyRes]) {
    println!(
        "| ranker | mean keystrokes | top1 after 1st key % | unwarranted flips % | weak-over-strong % | typo top3 % | post-drift keystrokes | inline completion shown % / precision % |"
    );
    println!("|---|---|---|---|---|---|---|---|");
    for (name, r) in names.iter().zip(t) {
        println!(
            "| {name} | {:.3} | {:.1} | {:.2} | {:.2} | {:.1} | {:.2} | {:.1} / {:.1} |",
            r.kss / r.events,
            pc(r.first_key_top1, r.events),
            pc(r.flips, r.flip_base),
            pc(r.violations, r.shown),
            pc(r.typo_top3, r.typo_n),
            r.drift_kss / r.drift_n.max(1.0),
            pc(r.completions, r.shown),
            pc(r.completions_right, r.completions),
        );
    }
}

fn print_weights(cfg: &Config, t: &Totals) {
    for ((name, _), ws) in cfg.zq.iter().zip(&t.weights) {
        if ws.is_empty() {
            continue;
        }
        let mut mean = [0.0; K];
        for w in ws {
            for k in 0..K {
                mean[k] += w[k] / ws.len() as f64;
            }
        }
        let names = ITEM_EXPERTS.iter().chain(FEATURE_NAMES.iter());
        let s: Vec<String> = names.zip(mean).map(|(n, w)| format!("{n} {w:.2}")).collect();
        println!(
            "learned exponents, mean of {} users, {name}: {}",
            ws.len(),
            s.join(", ")
        );
    }
}

fn zq_models() -> Vec<(String, ZqSpec)> {
    let mut naive = ZqParams {
        lr: 0.0,
        w_init: [1.0; K],
        ..ZqParams::default()
    };
    naive.w_init[1..4].iter_mut().for_each(|w| *w = 0.0);
    let frozen = ZqParams {
        lr: 0.0,
        ..ZqParams::default()
    };
    vec![
        ("Oracle (true generator argmax)".into(), ZqSpec::Oracle),
        ("MRU".into(), ZqSpec::Simple(SimpleKind::Mru)),
        ("MFU".into(), ZqSpec::Simple(SimpleKind::Mfu)),
        ("Frecency H=1d".into(), ZqSpec::Simple(SimpleKind::Frecency(DAY))),
        ("Frecency H=7d".into(), ZqSpec::Simple(SimpleKind::Frecency(7.0 * DAY))),
        ("Zoxide-style".into(), ZqSpec::Simple(SimpleKind::Zoxide)),
        ("kNN contexts".into(), ZqSpec::Knn),
        ("Interpolated mixture".into(), ZqSpec::Icm),
        ("Naive Bayes (exponents 1)".into(), ZqSpec::Model(naive)),
        ("Model, exponents frozen at the priors".into(), ZqSpec::Model(frozen)),
        (
            "Model, learned exponents (production)".into(),
            ZqSpec::Model(ZqParams::default()),
        ),
    ]
}

fn variant(name: &str, f: impl Fn(&mut EngineParams)) -> (String, EngineParams) {
    let mut p = EngineParams::default();
    f(&mut p);
    (name.into(), p)
}

fn eval_config() -> Config {
    Config {
        zq: zq_models(),
        baselines: vec![
            ("Text only".into(), TypedMode::Text),
            ("Text + MRU".into(), TypedMode::Mru),
            ("Text + MFU".into(), TypedMode::Mfu),
            ("Text + frecency".into(), TypedMode::Frecency),
            (
                "Match x popularity (crosses tiers)".into(),
                TypedMode::PopularityDominant,
            ),
        ],
        engines: vec![
            variant("ENGINE (production)", |_| {}),
            variant("engine without affinity", |p| {
                p.rank.affinity = 0;
                p.learner.affinity.band_weight = f64::INFINITY;
            }),
            variant("engine without the learned band", |p| {
                p.learner.affinity.band_weight = f64::INFINITY
            }),
            variant("engine, exact-query affinity only (eta 0)", |p| {
                p.learner.affinity.eta = 0.0
            }),
            variant("engine without context prior", |p| p.rank.context = 0),
            variant("engine without kind priors", |p| p.rank.prior = 0),
        ],
    }
}

fn tune_typed_config() -> Config {
    let mut engines = vec![variant("default", |_| {})];
    for g in [0.6, 0.8] {
        engines.push(variant(&format!("gamma {g}"), |p| p.learner.affinity.gamma = g));
    }
    for e in [0.25, 1.0] {
        engines.push(variant(&format!("eta {e}"), |p| p.learner.affinity.eta = e));
    }
    for b in [1.0, 2.0, 3.0] {
        engines.push(variant(&format!("band weight {b}"), |p| {
            p.learner.affinity.band_weight = b
        }));
    }
    for a in [3_000, 9_000] {
        engines.push(variant(&format!("affinity {a}"), |p| p.rank.affinity = a));
    }
    for (f, c) in [(2_000, 2_000), (5_000, 1_000), (6_000, 0), (4_000, 0)] {
        engines.push(variant(&format!("frecency {f} context {c}"), |p| {
            p.rank.frecency = f;
            p.rank.context = c;
        }));
    }
    for m in [0, 1_500, 6_000] {
        engines.push(variant(&format!("completion margin {m}"), |p| {
            p.rank.completion_margin = m
        }));
    }
    Config {
        zq: Vec::new(),
        baselines: Vec::new(),
        engines,
    }
}

fn tune_zq_config() -> Config {
    let mut zq = Vec::new();
    let mut add = |name: String, f: &dyn Fn(&mut ZqParams)| {
        let mut p = ZqParams::default();
        f(&mut p);
        zq.push((name, ZqSpec::Model(p)));
    };
    add("default".into(), &|_| {});
    for mu in [3.0, 20.0] {
        add(format!("mu {mu}"), &|p| p.mu = mu);
    }
    for lr in [0.005, 0.02] {
        add(format!("lr {lr}"), &|p| p.lr = lr);
    }
    for h in [1.0, 7.0] {
        add(format!("h_prior {h} d"), &|p| p.h_prior = h * DAY);
    }
    for w in [100.0, 1000.0] {
        add(format!("warmup {w}"), &|p| p.warmup = w);
    }
    Config {
        zq,
        baselines: Vec::new(),
        engines: Vec::new(),
    }
}

fn calib(cat: &[catalog::Item]) {
    let (mut events, mut days, mut distinct, mut repeats) = (0usize, 0usize, 0usize, 0usize);
    let mut kinds = [0usize; 3];
    for seed in 0..20u64 {
        let mut rng = Rng::new(seed);
        let mut p = build_persona(cat, &mut rng);
        let evs = generate(cat, &mut p, &mut rng);
        events += evs.len();
        let mut d: Vec<u32> = evs.iter().map(|e| e.day).collect();
        d.dedup();
        days += d.len();
        let mut ys: Vec<u32> = evs.iter().map(|e| e.y).collect();
        ys.sort_unstable();
        ys.dedup();
        distinct += ys.len();
        repeats += evs.windows(2).filter(|w| w[0].y == w[1].y).count();
        for e in &evs {
            kinds[match cat[e.y as usize].kind {
                Kind::App => 0,
                Kind::Command => 1,
                Kind::File => 2,
            }] += 1;
        }
    }
    println!(
        "20 users: events {events}, events per active day {:.1}, distinct items per user {:.1}, immediate repeats {:.1} %, apps/commands/files {kinds:?}",
        events as f64 / days as f64,
        distinct as f64 / 20.0,
        pc(repeats as f64, events as f64)
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).map_or("eval", String::as_str);
    let cat = Arc::new(build_catalog(150));
    let started = std::time::Instant::now();
    let (cfg, seeds): (Config, Vec<u64>) = match command {
        "eval" => {
            let n: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(60);
            let base: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1000);
            (eval_config(), (base..base + n).collect())
        }
        "tune-typed" => (tune_typed_config(), (0..30).collect()),
        "tune-zq" => (tune_zq_config(), (0..30).collect()),
        "calib" => {
            calib(&cat);
            return;
        }
        other => {
            eprintln!("unknown command {other:?}; use eval, tune-typed, tune-zq or calib");
            std::process::exit(2);
        }
    };
    let t = run_all(&cat, &cfg, &seeds);
    println!(
        "{command}: users {} (seeds {}..{}), events {}, catalog {} items\n",
        seeds.len(),
        seeds[0],
        seeds[seeds.len() - 1],
        t.events,
        cat.len()
    );
    if !cfg.zq.is_empty() || !cfg.engines.is_empty() {
        println!("### Zero-query suggestions (hit rate %, prequential, frontmost app excluded)\n");
        let mut names: Vec<String> = cfg.zq.iter().map(|z| z.0.clone()).collect();
        let mut rows = t.zq.clone();
        for ((name, _), r) in cfg.engines.iter().zip(&t.engine_zq).take(1) {
            names.push(format!("{name}: suggestions"));
            rows.push(r.clone());
        }
        print_zq(&names, &rows);
        println!();
        print_weights(&cfg, &t);
    }
    if !cfg.baselines.is_empty() || !cfg.engines.is_empty() {
        println!("\n### Typed queries\n");
        let names: Vec<String> = cfg
            .baselines
            .iter()
            .map(|b| b.0.clone())
            .chain(cfg.engines.iter().map(|e| e.0.clone()))
            .collect();
        print_typed(&names, &t.ty);
    }
    eprintln!("elapsed {:.1} s", started.elapsed().as_secs_f64());
}
