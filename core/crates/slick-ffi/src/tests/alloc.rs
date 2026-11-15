//! A counting global allocator for this test binary. Tests count the allocations of the calling
//! thread inside a closure, or of every thread when they run alone in a child process.
//!
//! Counting only touches atomics and a const-initialized thread local, so it never allocates. Every
//! method forwards to the system allocator unchanged.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

struct Counting;

static THREAD_ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);
static ALL_ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);
static COUNT_ALL: AtomicBool = AtomicBool::new(false);

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
}

fn note() {
    if COUNTING.try_with(Cell::get).unwrap_or(false) {
        THREAD_ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
    }
    if COUNT_ALL.load(Ordering::Relaxed) {
        ALL_ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
    }
}

// SAFETY: every method forwards to the system allocator with the caller's arguments unchanged.
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

/// Runs `f` and returns how many allocations the calling thread made inside it. Tests run on
/// separate threads, so other tests do not disturb the count.
pub(crate) fn on_this_thread(f: impl FnOnce()) -> usize {
    COUNTING.with(|c| c.set(true));
    let before = THREAD_ALLOCATIONS.load(Ordering::Relaxed);
    f();
    let after = THREAD_ALLOCATIONS.load(Ordering::Relaxed);
    COUNTING.with(|c| c.set(false));
    after - before
}

/// Runs `f` and returns how many allocations every thread of the process made inside it. Only
/// meaningful in a process that runs one test, see `in_child`.
pub(crate) fn on_every_thread(f: impl FnOnce()) -> usize {
    ALL_ALLOCATIONS.store(0, Ordering::Relaxed);
    COUNT_ALL.store(true, Ordering::Relaxed);
    f();
    COUNT_ALL.store(false, Ordering::Relaxed);
    ALL_ALLOCATIONS.load(Ordering::Relaxed)
}

/// The variable that tells an ignored test it runs alone in a child process.
pub(crate) const CHILD: &str = "SLICK_FFI_TEST_CHILD";

/// Runs the ignored test `name` alone in a child process of this test binary and asserts that it
/// passed. A test that counts allocations on every thread needs a process to itself.
pub(crate) fn in_child(name: &str) {
    let exe = std::env::current_exe().expect("the test binary");
    let out = std::process::Command::new(exe)
        .args([name, "--exact", "--ignored", "--test-threads", "1", "--nocapture"])
        .env(CHILD, "1")
        .output()
        .expect("the child test runs");
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && text.contains("1 passed"),
        "child test {name} failed:\n{text}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
