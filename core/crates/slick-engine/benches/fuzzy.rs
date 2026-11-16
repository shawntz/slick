//! Feature index latency on one thread, over synthetic lists shaped like an emoji grid: short
//! titles with several shared keywords, from `tests/support/tagged.rs`.
//!
//! Each keystroke is measured the way Root's `EngineFuzzyIndex` serves a host-filtered list: every
//! match, so `k` is the list's size, and with "ranges" also the title ranges of every hit that is
//! not a keyword match. "full scan" queries a fresh session with the whole query; "typed" types it one
//! char at a time, so the session narrows.
//!
//! ```text
//! scripts/cargo.sh bench --locked -p slick-engine --bench fuzzy
//! ```
//!
//! `BENCH_ITEMS`, a comma-separated list, sets the list sizes, `BENCH_REPS` the repetitions and
//! `BENCH_QOS=background` the background QoS class. No budget is checked: the host's keystroke
//! budget covers this work together with drawing.

#[path = "../tests/support/tagged.rs"]
mod tagged;

use slick_engine::{FuzzyIndex, Session};
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
/// The field of a keyword hit, which the host draws without title ranges.
const KEYWORD: u8 = 2;

struct Stats {
    name: String,
    samples: Vec<f64>,
}

impl Stats {
    fn new(name: String) -> Stats {
        Stats {
            name,
            samples: Vec::new(),
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

    fn report(&self) {
        println!(
            "| {:<44} | {:>6} | {:>7.1} | {:>7.1} | {:>7.1} | {:>8.1} |",
            self.name,
            self.samples.len(),
            self.quantile(0.0),
            self.quantile(0.5),
            self.quantile(0.99),
            self.quantile(1.0),
        );
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

/// One keystroke: every match, and with `ranges` the title ranges of each non-keyword hit.
fn keystroke(index: &FuzzyIndex, s: &mut Session, q: &str, every: usize, ranges: bool) -> usize {
    let len = index.query(s, q, every).expect("query").len();
    let mut n = len;
    if ranges {
        for i in 0..len {
            let hit = s.hits()[i];
            if hit.field != KEYWORD {
                n += index.ranges(s, hit.key).expect("ranges").len();
            }
        }
    }
    n
}

fn measure(n: usize, reps: usize, sink: &mut usize) {
    let items = tagged::catalog(n);
    let index = FuzzyIndex::new();
    index.set_items(&items).expect("items");
    let mut s = Session::new();
    let mut typed = String::with_capacity(64);
    for ranges in [false, true] {
        let what = if ranges { "query and ranges" } else { "query" };
        let mut cold = Stats::new(format!("{what}, full scan ({n} items)"));
        let mut typing = Stats::new(format!("{what}, typed ({n} items)"));
        for _ in 0..reps {
            for q in tagged::QUERIES {
                s.reset();
                *sink += cold.time(|| keystroke(&index, &mut s, q, n, ranges));
            }
            for q in tagged::QUERIES {
                s.reset();
                typed.clear();
                for c in q.chars() {
                    typed.push(c);
                    *sink += typing.time(|| keystroke(&index, &mut s, &typed, n, ranges));
                }
            }
        }
        cold.report();
        typing.report();
    }
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
        .unwrap_or(20);
    let sizes: Vec<usize> = std::env::var("BENCH_ITEMS")
        .ok()
        .map(|v| v.split(',').filter_map(|s| s.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![4_000, 10_000, 50_000]);
    println!(
        "qos class {class:#x} (status {qos}), reps={reps}, load average {}",
        load_average()
    );
    println!("| case | n | min µs | p50 µs | p99 µs | max µs |");
    println!("|---|---|---|---|---|---|");
    let mut sink = 0usize;
    for &n in &sizes {
        measure(n, reps, &mut sink);
    }
    println!("\nload average at the end {}", load_average());
    println!("(sink {sink})");
}
