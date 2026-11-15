//! Calculator latency against the budgets in the InstantProvider contract, on one thread:
//!
//! - rejecting a query that is not math: under 1 µs at p50;
//! - any accepted query: under 100 µs at p99.
//!
//! Times are thread CPU time from `clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)`, in a release
//! build. Rejections take tens of nanoseconds, below the clock's useful resolution, so each
//! rejection sample times a batch of calls and divides. Accepted queries are timed one call at a
//! time, minus the clock's own cost.
//!
//! Run with `scripts/cargo.sh bench -p slick-calc`. It runs at the user-interactive QoS class;
//! `BENCH_QOS=background` keeps it on the efficiency cores, the speed the budgets are stated at.
//! `BENCH_REPS` sets the repetitions. The process exits with status 1 when a budget is blown.
//!
//! The library forbids unsafe code. This file needs two foreign calls, the CPU clock and the QoS
//! class, and so two small unsafe blocks.

#[path = "../tests/support/mod.rs"]
mod support;

use slick_calc::{Answer, evaluate, prepare};
use support::Options;

unsafe extern "C" {
    /// Darwin: nanoseconds on the given clock.
    fn clock_gettime_nsec_np(clock_id: u32) -> u64;
    /// Darwin: sets the calling thread's quality of service.
    fn pthread_set_qos_class_self_np(qos: u32, relative_priority: i32) -> i32;
}

const CLOCK_THREAD_CPUTIME_ID: u32 = 16;
const USER_INTERACTIVE: u32 = 0x21;
const BACKGROUND: u32 = 0x09;

fn cpu_ns() -> u64 {
    // SAFETY: a plain Darwin libc call with a valid clock id; it touches no memory of ours.
    unsafe { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}

static CASES: &str = include_str!("../tests/cases.txt");

const REJECT_WORDS: &[&str] = &[
    "s",
    "sa",
    "saf",
    "safa",
    "safari",
    "t",
    "te",
    "ter",
    "term",
    "terminal",
    "visual studio code",
    "google chrome",
    "system settings",
    "activity monitor",
    "app store",
    "messages",
    "photos",
    "xcode",
    "slack",
    "spotify",
    "time machine",
    "new tab",
    "dark mode",
    "find my",
];

const REJECT_DIGITS: &[&str] = &[
    "notes 2024",
    "2024 notes",
    "iphone 15 pro",
    "1password",
    "7zip",
    "v2",
    "123",
    "windows 11",
    "office 365",
    "python3",
    "12 monkeys",
    "3 body problem",
];

const SIMPLE: &[&str] = &[
    "2+2",
    "12 * 3",
    "100 / 7",
    "2^10",
    "(1 + 2) * 3",
    "0.1 + 0.2",
    "15% of 80",
    "sqrt 16",
];

struct Stats {
    name: String,
    samples: Vec<f64>,
}

impl Stats {
    fn new(name: &str) -> Stats {
        Stats {
            name: name.to_owned(),
            samples: Vec::new(),
        }
    }

    fn q(&self, q: f64) -> f64 {
        let mut v = self.samples.clone();
        v.sort_by(f64::total_cmp);
        if v.is_empty() {
            return f64::NAN;
        }
        v[((v.len() - 1) as f64 * q).round() as usize]
    }

    fn row(&self, budget: &str, ok: bool) {
        println!(
            "| {:<44} | {:>7} | {:>9.3} | {:>9.3} | {:>9.3} | {:<20} |",
            self.name,
            self.samples.len(),
            self.q(0.5),
            self.q(0.99),
            self.q(1.0),
            if budget.is_empty() {
                "-".to_owned()
            } else {
                format!("{budget} {}", if ok { "ok" } else { "OVER" })
            }
        );
    }
}

/// Queries the suite accepts in the default context: every case up to the first directive.
fn accepted_cases() -> Vec<&'static str> {
    let mut out = Vec::new();
    for line in CASES.lines() {
        let t = line.trim();
        if t.starts_with("::") {
            break;
        }
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        if let Some((q, expect)) = t.split_once("=>")
            && expect.trim() != "!"
            && !expect.trim().starts_with('!')
        {
            out.push(q.trim());
        }
    }
    out
}

fn main() {
    let background = std::env::var("BENCH_QOS").is_ok_and(|v| v == "background");
    let qos = if background { BACKGROUND } else { USER_INTERACTIVE };
    // SAFETY: a plain Darwin call that changes this thread's scheduling class only.
    let _ = unsafe { pthread_set_qos_class_self_np(qos, 0) };
    let reps: usize = std::env::var("BENCH_REPS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(200);

    prepare();
    let ctx = support::context(Options::default());
    let mut answer = Answer::new();
    let accepted = accepted_cases();
    // Warm every path once: zone tables, rates, the answer's string capacity.
    for q in accepted.iter().chain(REJECT_WORDS).chain(REJECT_DIGITS) {
        let _ = evaluate(q, &ctx, &mut answer);
    }

    // The clock's own cost, subtracted from single-call samples.
    let mut overhead: Vec<u64> = (0..10_000)
        .map(|_| {
            let a = cpu_ns();
            let b = cpu_ns();
            b - a
        })
        .collect();
    overhead.sort_unstable();
    let clock = overhead[overhead.len() / 2] as f64;

    const BATCH: usize = 256;
    let mut reject_words = Stats::new("reject: words (per call, batches of 256)");
    let mut reject_digits = Stats::new("reject: words with digits (per call, batches)");
    for _ in 0..reps {
        for (set, stats) in [(REJECT_WORDS, &mut reject_words), (REJECT_DIGITS, &mut reject_digits)] {
            for q in set {
                let t = cpu_ns();
                for _ in 0..BATCH {
                    let _ = evaluate(std::hint::black_box(q), &ctx, &mut answer);
                }
                let dt = cpu_ns() - t;
                stats.samples.push(dt as f64 / BATCH as f64 / 1000.0);
            }
        }
    }

    let single = |q: &str, answer: &mut Answer| -> f64 {
        let t = cpu_ns();
        let _ = evaluate(std::hint::black_box(q), &ctx, answer);
        let dt = cpu_ns() - t;
        (dt as f64 - clock).max(0.0) / 1000.0
    };
    let mut simple = Stats::new("accept: simple arithmetic");
    let mut all = Stats::new("accept: every accepted case in the suite");
    let mut per_query: Vec<(String, Stats)> = accepted.iter().map(|q| ((*q).to_owned(), Stats::new(q))).collect();
    for _ in 0..reps {
        for q in SIMPLE {
            simple.samples.push(single(q, &mut answer));
        }
        for (q, stats) in per_query.iter_mut() {
            let us = single(q, &mut answer);
            stats.samples.push(us);
            all.samples.push(us);
        }
    }
    per_query.sort_by(|a, b| b.1.q(0.5).total_cmp(&a.1.q(0.5)));

    let load = std::process::Command::new("/usr/sbin/sysctl")
        .args(["-n", "vm.loadavg"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default();
    println!();
    println!(
        "slick-calc latency, µs of thread CPU time, QoS {}, load {load}",
        if background { "background" } else { "user-interactive" }
    );
    println!("clock overhead {clock:.0} ns per pair, subtracted from single calls; {reps} repetitions");
    println!();
    println!(
        "| {:<44} | {:>7} | {:>9} | {:>9} | {:>9} | {:<20} |",
        "path", "n", "p50", "p99", "max", "budget"
    );
    println!(
        "|{}|{}|{}|{}|{}|{}|",
        "-".repeat(46),
        "-".repeat(9),
        "-".repeat(11),
        "-".repeat(11),
        "-".repeat(11),
        "-".repeat(22)
    );
    let mut ok = true;
    for s in [&reject_words, &reject_digits] {
        let pass = s.q(0.5) < 1.0;
        ok &= pass;
        s.row("p50 < 1 µs", pass);
    }
    let pass = simple.q(0.99) < 100.0;
    ok &= pass;
    simple.row("p99 < 100 µs", pass);
    let pass = all.q(0.99) < 100.0;
    ok &= pass;
    all.row("p99 < 100 µs", pass);
    println!();
    println!("Slowest accepted queries by median:");
    for (q, s) in per_query.iter().take(8) {
        let pass = s.q(0.99) < 100.0;
        ok &= pass;
        let mut row = Stats::new(&format!("{q:?}"));
        row.samples = s.samples.clone();
        row.row("p99 < 100 µs", pass);
    }
    if !ok {
        println!("\nA budget is blown.");
        std::process::exit(1);
    }
}
