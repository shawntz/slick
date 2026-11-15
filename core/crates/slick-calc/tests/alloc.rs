//! A rejected query allocates nothing. A counting allocator watches this thread while warm
//! evaluations run.
//!
//! The library itself forbids unsafe code. This test needs one `unsafe impl` because Rust only
//! lets a global allocator be installed that way.

mod support;

use slick_calc::{Answer, evaluate, prepare};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};
use support::Options;

struct Counting;

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
}

fn note() {
    if COUNTING.try_with(Cell::get).unwrap_or(false) {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
    }
}

// SAFETY: every method forwards to the system allocator with the caller's arguments unchanged.
// Counting touches only an atomic and a const-initialized thread local, neither of which
// allocates.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note();
        // SAFETY: forwarded unchanged; the caller upholds `GlobalAlloc::alloc`'s contract.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        note();
        // SAFETY: as above.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        note();
        // SAFETY: as above; `ptr` came from this allocator, which is the system allocator.
        unsafe { System.realloc(ptr, layout, new_size) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: as above.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn count(f: impl FnOnce()) -> usize {
    ALLOCATIONS.store(0, Ordering::Relaxed);
    COUNTING.with(|c| c.set(true));
    f();
    COUNTING.with(|c| c.set(false));
    ALLOCATIONS.load(Ordering::Relaxed)
}

const REJECTED: &[&str] = &[
    "safari",
    "s",
    "sa",
    "saf",
    "visual studio code",
    "google chrome",
    "time machine",
    "new tab",
    "notes 2024",
    "2024 notes",
    "iphone 15 pro",
    "1password",
    "v2",
    "123",
    "-5",
    "1,000",
    "pi day",
    "new york times",
    "march madness",
    "time zone",
    "café",
    "東京",
];

const ACCEPTED_WARM: &[&str] = &["2+2", "12 * 3", "sqrt 16", "20% of 50", "0.1 + 0.2", "2^10"];

#[test]
fn rejected_queries_allocate_nothing() {
    prepare();
    let ctx = support::context(Options::default());
    let mut answer = Answer::new();
    // Warm the zone and rate tables, which load once per process.
    for q in REJECTED {
        assert!(!evaluate(q, &ctx, &mut answer), "{q} should not be math");
    }
    for q in REJECTED {
        let n = count(|| {
            let _ = evaluate(q, &ctx, &mut answer);
        });
        assert_eq!(n, 0, "{q:?} allocated {n} times");
    }
}

#[test]
fn simple_answers_reuse_the_answer_buffers() {
    prepare();
    let ctx = support::context(Options::default());
    let mut answer = Answer::new();
    for q in ACCEPTED_WARM {
        assert!(evaluate(q, &ctx, &mut answer));
    }
    for q in ACCEPTED_WARM {
        let n = count(|| {
            let _ = evaluate(q, &ctx, &mut answer);
        });
        assert_eq!(n, 0, "{q:?} allocated {n} times on a warm answer");
    }
}
