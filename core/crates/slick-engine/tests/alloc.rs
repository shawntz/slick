//! The query path allocates nothing: a counting allocator watches this thread while a warmed-up
//! session runs queries, highlight ranges and the completion decision over 10,000 items, and while
//! a feature index answers typed queries and the host's highlight ranges over 4,000 tagged items.

#[path = "support/synthetic.rs"]
mod synthetic;
#[path = "support/tagged.rs"]
mod tagged;

use slick_engine::{Engine, EngineParams, FuzzyIndex, Session};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct Counting;

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    /// Allocations of this thread while it counts. Per thread, so tests run side by side.
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

fn note() {
    if COUNTING.try_with(Cell::get).unwrap_or(false) {
        let _ = ALLOCATIONS.try_with(|n| n.set(n.get() + 1));
    }
}

/// Runs `f` and returns how many allocations this thread made inside it.
fn allocations_in(f: impl FnOnce()) -> usize {
    ALLOCATIONS.with(|n| n.set(0));
    COUNTING.with(|c| c.set(true));
    f();
    COUNTING.with(|c| c.set(false));
    ALLOCATIONS.with(Cell::get)
}

// SAFETY: every method forwards to the system allocator with the caller's arguments unchanged;
// counting touches only const-initialized thread locals, which never allocate.
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
    let (mut measured, mut single) = (0, 0);
    let allocations = allocations_in(|| {
        measured = run(&e, &mut s, &mut typed);
        single = query_and_render(&e, &mut s, "s");
    });
    assert!(
        measured > 0 && warm > 0 && single > 0,
        "the queries matched and rendered something"
    );
    assert_eq!(allocations, 0, "allocations on the query path");
}

/// One keystroke in a host-filtered list as Root's `EngineFuzzyIndex` serves it: every match, then
/// the title ranges of every hit that is not a keyword match.
fn filter_list(index: &FuzzyIndex, s: &mut Session, q: &str, every: usize) -> usize {
    let mut n = 0;
    let len = index.query(s, q, every).expect("query").len();
    for i in 0..len {
        let hit = s.hits()[i];
        if hit.field != 2 {
            n += index.ranges(s, hit.key).expect("ranges").len();
        }
    }
    n + len
}

fn type_tagged(index: &FuzzyIndex, s: &mut Session, typed: &mut String, every: usize) -> usize {
    let mut seen = 0;
    s.reset();
    for q in tagged::QUERIES {
        typed.clear();
        for c in q.chars() {
            typed.push(c);
            seen += filter_list(index, s, typed, every);
        }
        typed.pop();
        seen += filter_list(index, s, typed, every);
    }
    seen
}

#[test]
fn the_feature_index_query_path_allocates_nothing() {
    let items = tagged::catalog(4_000);
    let index = FuzzyIndex::new();
    index.set_items(&items).expect("items");
    let mut s = Session::new();
    let mut typed = String::with_capacity(64);
    let every = items.len();
    let warm = type_tagged(&index, &mut s, &mut typed, every) + type_tagged(&index, &mut s, &mut typed, every);
    let mut measured = 0;
    let allocations = allocations_in(|| measured = type_tagged(&index, &mut s, &mut typed, every));
    assert!(
        measured > 0 && measured == warm / 2,
        "the same queries matched the same rows"
    );
    assert_eq!(allocations, 0, "allocations on the feature index's query path");
}
