//! Engine latency against the budgets in docs/ARCHITECTURE.md, on one thread:
//!
//! - a query with ranking and top 50 included: under 300 µs at p99 over 3,000 items and under
//!   1 ms at p99 over 10,000 items, both for a fresh full scan and for typing char by char;
//! - zero-query suggestions (recomputed on a context change): under 50 µs at p99;
//! - recording an execution, on the calling thread, with persistence on: under 100 µs at p99.
//!
//! The learning state is a synthetic heavy user. Run with `make bench-core`. The process exits
//! with status 1 when a budget is blown. Set `BENCH_REPS` to change the number of repetitions and
//! `BENCH_ITEMS` (a comma-separated list) to change the catalog sizes.
//!
//! The bench runs at the user-interactive QoS class, which Apple silicon schedules on performance
//! cores. The budgets are stated at efficiency-core speed: `BENCH_QOS=background` runs it at the
//! background class, which macOS keeps on the efficiency cores, for that measurement.

#[path = "../tests/support/synthetic.rs"]
mod synthetic;

use slick_engine::{Context, Engine, EngineParams, Item, Session, Source};
use std::time::Instant;

unsafe extern "C" {
    /// Darwin: sets the calling thread's quality of service.
    fn pthread_set_qos_class_self_np(qos: u32, relative_priority: i32) -> i32;
    /// The 1, 5 and 15 minute load averages.
    fn getloadavg(loadavg: *mut f64, nelem: i32) -> i32;
}

/// QOS_CLASS_USER_INTERACTIVE, the class of the main thread while the user types.
const USER_INTERACTIVE: u32 = 0x21;
/// QOS_CLASS_BACKGROUND, which macOS runs on the efficiency cores only.
const BACKGROUND: u32 = 0x09;

struct Stats {
    name: String,
    samples: Vec<f64>,
    budget_us: Option<f64>,
}

impl Stats {
    fn new(name: impl Into<String>, budget_us: Option<f64>) -> Stats {
        Stats {
            name: name.into(),
            samples: Vec::new(),
            budget_us,
        }
    }

    fn time<R>(&mut self, f: impl FnOnce() -> R) -> R {
        let t = Instant::now();
        let r = f();
        self.samples.push(t.elapsed().as_secs_f64() * 1e6);
        r
    }

    fn quantile(&self, q: f64) -> f64 {
        let mut v = self.samples.clone();
        v.sort_by(f64::total_cmp);
        v[((v.len() - 1) as f64 * q).round() as usize]
    }

    /// Prints a table row; returns false when the p99 is over budget.
    fn report(&self) -> bool {
        let p99 = self.quantile(0.99);
        let ok = self.budget_us.is_none_or(|b| p99 < b);
        println!(
            "| {:<52} | {:>6} | {:>7.1} | {:>7.1} | {:>7.1} | {:>7.1} | {:>9} |",
            self.name,
            self.samples.len(),
            self.quantile(0.0),
            self.quantile(0.5),
            p99,
            self.quantile(1.0),
            match self.budget_us {
                Some(b) if ok => format!("< {b} ok"),
                Some(b) => format!("< {b} OVER"),
                None => "-".into(),
            }
        );
        ok
    }
}

/// The five queries with the highest median full-scan time. Samples are in query order per rep.
fn slowest_queries(cold: &Stats, reps: usize) -> String {
    let n = synthetic::QUERIES.len();
    let mut medians: Vec<(f64, &str)> = (0..n)
        .map(|q| {
            let mut v: Vec<f64> = (0..reps).map(|r| cold.samples[r * n + q]).collect();
            v.sort_by(f64::total_cmp);
            (v[v.len() / 2], synthetic::QUERIES[q])
        })
        .collect();
    medians.sort_by(|a, b| b.0.total_cmp(&a.0));
    medians
        .iter()
        .take(5)
        .map(|(t, q)| format!("{q:?} {t:.0}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The query budget at p99 for a catalog of `n` items, from docs/ARCHITECTURE.md.
fn query_budget(n: usize) -> Option<f64> {
    match n {
        0..=3_000 => Some(300.0),
        3_001..=10_000 => Some(1_000.0),
        _ => None,
    }
}

fn load_average() -> String {
    let mut l = [0.0f64; 3];
    // SAFETY: getloadavg writes at most `nelem` doubles into the array, which holds three.
    let n = unsafe { getloadavg(l.as_mut_ptr(), 3) };
    if n < 1 {
        return "unknown".into();
    }
    format!("{:.2} {:.2} {:.2}", l[0], l[1], l[2])
}

/// A persisted engine over a synthetic catalog of `n` items, trained as a heavy user. Returns the
/// engine, the items and the time of the last training event.
fn trained_engine(n: usize, dir: &std::path::Path) -> (Engine, Vec<Item>, f64) {
    let _ = std::fs::remove_dir_all(dir);
    let items = synthetic::catalog(n);
    let built = Instant::now();
    let e = Engine::open(dir, EngineParams::default()).expect("open");
    e.replace_source(1, items.clone()).expect("catalog");
    let catalog_ms = built.elapsed().as_secs_f64() * 1e3;
    let trained = Instant::now();
    let t = synthetic::train(&e, &items, 20_000, 600);
    let train_s = trained.elapsed().as_secs_f64();
    e.flush();
    println!(
        "\nitems={n} learned events=20000 distinct=600: catalog build {catalog_ms:.1} ms, training {train_s:.1} s\n"
    );
    (e, items, t)
}

/// Full-scan and typing latency over `e`. Returns false when a budget is blown.
fn measure_queries(e: &Engine, n: usize, reps: usize, sink: &mut usize) -> bool {
    println!("| case | n | min µs | p50 µs | p99 µs | max µs | budget p99 |");
    println!("|---|---|---|---|---|---|---|");
    // Each sample is a fresh query: a summon, then the whole query typed at once (a full scan).
    let mut s = Session::new();
    let budget = query_budget(n);
    let mut cold = Stats::new(format!("query, full scan, top 50 ({n} items)"), budget);
    let mut typing = Stats::new(format!("query, typed char by char ({n} items)"), budget);
    let mut typed = String::with_capacity(64);
    for _ in 0..reps {
        for q in synthetic::QUERIES {
            s.reset();
            *sink += cold.time(|| e.query(&mut s, q, 50).expect("query").len());
        }
        for q in synthetic::QUERIES {
            s.reset();
            typed.clear();
            for c in q.chars() {
                typed.push(c);
                *sink += typing.time(|| e.query(&mut s, &typed, 50).expect("query").len());
            }
        }
    }
    let ok = cold.report() & typing.report();
    println!(
        "\nslowest full-scan queries over {n} items (median µs): {}\n",
        slowest_queries(&cold, reps)
    );
    ok
}

fn main() {
    let class = match std::env::var("BENCH_QOS").as_deref() {
        Ok("background") => BACKGROUND,
        _ => USER_INTERACTIVE,
    };
    // SAFETY: a plain Darwin call that changes only the calling thread's scheduling class.
    let qos = unsafe { pthread_set_qos_class_self_np(class, 0) };
    let reps: usize = std::env::var("BENCH_REPS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30);
    let sizes: Vec<usize> = std::env::var("BENCH_ITEMS")
        .ok()
        .map(|v| v.split(',').filter_map(|s| s.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![3_000, 10_000]);
    println!(
        "qos class {class:#x} (status {qos}), reps={reps}, load average {}",
        load_average()
    );
    let root = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("slick-engine-bench");
    let mut ok = true;
    let mut sink = 0usize;
    let mut last = None;
    for &n in &sizes {
        let dir = root.join(format!("items-{n}"));
        let (e, items, t) = trained_engine(n, &dir);
        ok &= measure_queries(&e, n, reps, &mut sink);
        if let Some((old, _, _, old_dir)) = last.replace((e, items, t, dir)) {
            drop::<Engine>(old);
            let _ = std::fs::remove_dir_all(old_dir);
        }
    }
    let Some((e, items, mut t, dir)) = last else {
        return;
    };
    println!("other paths, over the last catalog ({} items):\n", items.len());
    println!("| case | n | min µs | p50 µs | p99 µs | max µs | budget p99 |");
    println!("|---|---|---|---|---|---|---|");

    // Ranges and the completion decision for the visible rows of one keystroke.
    let mut s = Session::new();
    let mut render = Stats::new("ranges for 10 rows plus completion", None);
    for _ in 0..reps {
        for q in synthetic::QUERIES {
            let keys: Vec<u64> = e
                .query(&mut s, q, 50)
                .expect("query")
                .iter()
                .take(10)
                .map(|h| h.key)
                .collect();
            sink += render.time(|| {
                let mut n = 0;
                for &k in &keys {
                    n += e.ranges(&mut s, k).expect("ranges").len();
                }
                n + e.completion(&mut s).expect("completion").map_or(0, |(_, r)| r.len())
            });
        }
    }
    render.report();

    // Suggestions are recomputed when the context changes.
    let mut suggest = Stats::new("suggestions: context change, recompute", Some(50.0));
    let mut read = Stats::new("suggestions: read the prepared list", None);
    let mut out = Vec::with_capacity(32);
    for k in 0..reps * 60 {
        let c = Context {
            now: t + k as f64,
            hour: (k % 24) as u8,
            weekday: (k % 7) as u8,
            frontmost: items[k % 23].key,
            display_count: 1 + (k % 2) as u8,
            ..Context::default()
        };
        suggest.time(|| e.set_context(c).expect("context"));
        read.time(|| e.suggestions(&mut out).expect("suggestions"));
        sink += out.len();
    }
    ok &= suggest.report();
    read.report();

    // Recording an execution: learning on this thread, the log write on the store's thread. A
    // snapshot is written every 500 executions; its max shows whether it ever makes a record wait.
    let mut record = Stats::new("record an execution (persistence on)", Some(100.0));
    for k in 0..reps * 60 {
        t += 30.0;
        let it = &items[(k * 7919) % 2_000];
        let q: String = it.title.chars().take(1 + k % 5).collect();
        record.time(|| e.record(it.key, &q, Source::Typed, 0, t).expect("record"));
    }
    ok &= record.report();
    e.flush();
    drop(e);
    let _ = std::fs::remove_dir_all(&dir);
    println!("\nload average at the end {}", load_average());
    println!("(sink {sink})");
    if !ok {
        eprintln!("a latency budget was blown");
        std::process::exit(1);
    }
}
