//! The query path allocates nothing: a counting allocator watches this thread while a warmed-up
//! session runs queries, highlight ranges and the completion decision over 10,000 items.

#[path = "support/synthetic.rs"]
mod synthetic;

use slick_engine::{Engine, EngineParams, Session};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

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

// SAFETY: every method forwards to the system allocator with the caller's arguments unchanged;
// counting touches only an atomic and a const-initialized thread local, neither of which allocates.
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

fn run(e: &Engine, s: &mut Session, typed: &mut String) -> usize {
    let mut seen = 0;
    s.reset();
    for q in synthetic::QUERIES {
        // Type it one char at a time, then backspace twice, like a person would.
        typed.clear();
        for c in q.chars() {
            typed.push(c);
            seen += query_and_render(e, s, typed);
        }
        typed.pop();
        seen += query_and_render(e, s, typed);
        typed.pop();
        seen += query_and_render(e, s, typed);
    }
    seen
}

fn query_and_render(e: &Engine, s: &mut Session, q: &str) -> usize {
    let keys: [u64; 10] = {
        let hits = e.query(s, q, 50).expect("query");
        let mut k = [0u64; 10];
        for (slot, h) in k.iter_mut().zip(hits) {
            *slot = h.key;
        }
        k
    };
    let mut n = 0;
    for key in keys.into_iter().filter(|&k| k != 0) {
        n += e.ranges(s, key).expect("ranges").len();
    }
    n + e.completion(s).expect("completion").map_or(0, |(_, rest)| rest.len())
}

#[test]
fn the_query_path_allocates_nothing() {
    let items = synthetic::catalog(10_000);
    let e = Engine::in_memory(EngineParams::default());
    e.replace_source(1, items.clone()).expect("catalog");
    synthetic::train(&e, &items, 3_000, 400);
    for (i, item) in items.iter().take(5).enumerate() {
        e.set_alias(item.key, &format!("al{i}")).expect("alias");
    }
    let mut s = Session::new();
    let mut typed = String::with_capacity(64);
    // Warm up twice: buffers grow to the longest query and the deepest narrowing stack.
    let warm = run(&e, &mut s, &mut typed) + run(&e, &mut s, &mut typed);
    ALLOCATIONS.store(0, Ordering::Relaxed);
    COUNTING.with(|c| c.set(true));
    let measured = run(&e, &mut s, &mut typed);
    let single = query_and_render(&e, &mut s, "s");
    COUNTING.with(|c| c.set(false));
    let allocations = ALLOCATIONS.load(Ordering::Relaxed);
    assert!(
        measured > 0 && warm > 0 && single > 0,
        "the queries matched and rendered something"
    );
    assert_eq!(allocations, 0, "allocations on the query path");
}
