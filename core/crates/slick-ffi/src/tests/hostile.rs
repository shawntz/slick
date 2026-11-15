//! The C ABI under hostile arguments: NULL and dangling pointers with zero lengths, invalid UTF-8,
//! lengths no real buffer can have, misaligned and zero-capacity output buffers, non-finite
//! numbers, and many threads at once. Every call must come back with a status, and a refused call
//! must leave the state as it was.
//!
//! Use after close and double close are not tested: with raw pointers they are undefined behaviour
//! in any C API. The Swift wrappers own each handle and free it exactly once in `deinit`.

use super::*;
use std::ptr::NonNull;

const INVALID_ARGUMENT: i32 = SlickStatus::InvalidArgument as i32;
const INVALID_UTF8: i32 = SlickStatus::InvalidUtf8 as i32;
const NULL_POINTER: i32 = SlickStatus::NullPointer as i32;

fn dangling<T>() -> *mut T {
    NonNull::<T>::dangling().as_ptr()
}

fn new_session() -> *mut SlickSession {
    let mut s = null_mut();
    assert_eq!(session::slick_session_new(&mut s), OK);
    s
}

fn catalog(e: *const SlickEngine) -> Batch {
    let batch = Batch::new(&[
        ("Safari", "", "browser|web", 1),
        ("Terminal", "Shell", "", 1),
        ("Toggle Dark Mode", "", "appearance", 2),
    ]);
    let rc = engine::slick_engine_replace_source(
        e,
        1,
        batch.items.as_ptr(),
        batch.items.len(),
        batch.strings.as_ptr(),
        batch.strings.len(),
    );
    assert_eq!(rc, OK);
    batch
}

fn stats(e: *const SlickEngine) -> String {
    let mut needed = 0usize;
    let mut buf = vec![0u8; 64 * 1024];
    assert_eq!(
        engine::slick_engine_stats(e, buf.as_mut_ptr(), buf.len(), &mut needed),
        OK
    );
    String::from_utf8(buf[..needed].to_vec()).expect("stats are UTF-8")
}

#[test]
fn zero_lengths_accept_null_and_dangling_pointers() {
    for ptr in [null_mut::<u8>(), dangling::<u8>()] {
        let mut e = null_mut();
        assert_eq!(engine::slick_engine_open(ptr, 0, &mut e), OK, "in memory");
        let s = new_session();
        let rc = engine::slick_engine_replace_source(e, 1, dangling(), 0, ptr, 0);
        assert_eq!((rc, engine::slick_engine_count(e)), (OK, 0));
        catalog(e);
        let hits = dangling::<SlickHit>();
        assert_eq!(engine::slick_engine_query(e, s, ptr, 0, hits, 0), 0, "empty query");
        assert_eq!(
            engine::slick_engine_query(e, s, b"s".as_ptr(), 1, hits, 0),
            0,
            "no room"
        );
        assert_eq!(engine::slick_engine_ranges(e, s, 1, dangling(), 0), 0);
        let mut key = 7u64;
        assert_eq!(engine::slick_engine_completion(e, s, &mut key, ptr, 0), 0);
        assert_eq!(key, 0, "no completion clears the key");
        assert_eq!(engine::slick_engine_suggestions(e, dangling(), 0), 0);
        assert_eq!(engine::slick_engine_set_alias(e, 1, ptr, 0), OK);
        assert_eq!(engine::slick_engine_record(e, 1, ptr, 0, 0, 255, 1.0e9), 1);
        let mut needed = 0usize;
        let rc = engine::slick_engine_stats(e, ptr, 0, &mut needed);
        assert_eq!(rc, SlickStatus::BufferTooSmall as i32);
        assert!(needed > 2, "the needed length is reported");
        let mut ix = null_mut();
        assert_eq!(index::slick_index_new(&mut ix), OK);
        assert_eq!(index::slick_index_set_items(ix, dangling(), 0, ptr, 0), OK);
        assert_eq!(index::slick_index_query(ix, s, ptr, 0, dangling(), 0), 0);
        assert_eq!(index::slick_index_ranges(ix, s, 1, dangling(), 0), 0);
        assert_eq!(index::slick_index_free(ix), OK);
        assert_eq!(session::slick_session_free(s), OK);
        assert_eq!(engine::slick_engine_close(e), OK);
    }
}

#[test]
fn invalid_utf8_is_refused_everywhere_and_changes_nothing() {
    let e = open_in_memory();
    let s = new_session();
    let batch = catalog(e);
    let bad = [b'S', 0xC3, 0x28, 0xFF];
    let mut out = [SlickHit::default(); 4];
    assert_eq!(
        engine::slick_engine_query(e, s, bad.as_ptr(), bad.len(), out.as_mut_ptr(), 4),
        INVALID_UTF8
    );
    assert_eq!(
        engine::slick_engine_set_alias(e, 1, bad.as_ptr(), bad.len()),
        INVALID_UTF8
    );
    assert_eq!(
        engine::slick_engine_record(e, batch.items[0].key, bad.as_ptr(), bad.len(), 0, 0, 1.0e9),
        INVALID_UTF8
    );
    let mut e2 = null_mut();
    assert_eq!(
        engine::slick_engine_open(bad.as_ptr(), bad.len(), &mut e2),
        INVALID_UTF8
    );
    assert!(e2.is_null());
    // A bad span in any field of any item refuses the whole batch.
    for field in 0..3 {
        let mut strings = b"Good".to_vec();
        strings.extend_from_slice(&bad);
        let mut item = SlickItem {
            key: 99,
            title_len: 4,
            ..SlickItem::default()
        };
        let span = (4, bad.len() as u32);
        match field {
            0 => (item.title_start, item.title_len) = span,
            1 => (item.aliases_start, item.aliases_len) = span,
            _ => (item.keywords_start, item.keywords_len) = span,
        }
        let rc = engine::slick_engine_replace_source(e, 1, &item, 1, strings.as_ptr(), strings.len());
        assert_eq!(rc, INVALID_UTF8, "field {field}");
        let rc = engine::slick_engine_upsert(e, 2, &item, strings.as_ptr(), strings.len());
        assert_eq!(rc, INVALID_UTF8, "field {field}");
    }
    assert_eq!(engine::slick_engine_count(e), 3, "the catalog is unchanged");
    assert_eq!(query(e, s, "saf")[0].key, batch.items[0].key);
    let json = stats(e);
    assert!(json.contains("\"events\":0"), "nothing was learned: {json}");
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(engine::slick_engine_close(e), OK);
}

#[test]
fn impossible_lengths_and_misaligned_buffers_are_refused() {
    let e = open_in_memory();
    let s = new_session();
    let batch = catalog(e);
    let q = b"saf";
    let mut out = [SlickHit::default(); 4];
    let huge = [usize::MAX, isize::MAX as usize + 1];
    for len in huge {
        let rc = engine::slick_engine_query(e, s, q.as_ptr(), len, out.as_mut_ptr(), 4);
        assert_eq!(rc, INVALID_ARGUMENT, "query length {len}");
        let rc = engine::slick_engine_set_alias(e, 1, q.as_ptr(), len);
        assert_eq!(rc, INVALID_ARGUMENT, "alias length {len}");
        let rc = engine::slick_engine_record(e, 1, q.as_ptr(), len, 0, 0, 1.0e9);
        assert_eq!(rc, INVALID_ARGUMENT, "record length {len}");
        let rc = engine::slick_engine_replace_source(e, 1, batch.items.as_ptr(), 1, batch.strings.as_ptr(), len);
        assert_eq!(rc, INVALID_ARGUMENT, "strings length {len}");
    }
    // Counts whose byte size overflows usize, or exceeds isize::MAX: 48-byte items, 16-byte hits,
    // suggestions and ranges (8-byte ranges get an even larger count).
    for count in [usize::MAX, usize::MAX / 48 + 1, isize::MAX as usize / 48 + 1] {
        let rc = engine::slick_engine_replace_source(
            e,
            1,
            batch.items.as_ptr(),
            count,
            batch.strings.as_ptr(),
            batch.strings.len(),
        );
        assert_eq!(rc, INVALID_ARGUMENT, "item count {count}");
    }
    for count in [usize::MAX, usize::MAX / 16 + 1, isize::MAX as usize / 8 + 1] {
        let rc = engine::slick_engine_query(e, s, q.as_ptr(), q.len(), out.as_mut_ptr(), count);
        assert_eq!(rc, INVALID_ARGUMENT, "hit capacity {count}");
        let rc = engine::slick_engine_suggestions(e, dangling(), count);
        assert_eq!(rc, INVALID_ARGUMENT, "suggestion capacity {count}");
        let rc = engine::slick_engine_ranges(e, s, batch.items[0].key, dangling(), count);
        assert_eq!(rc, INVALID_ARGUMENT, "range capacity {count}");
    }
    let mut needed = 0usize;
    let rc = engine::slick_engine_stats(e, dangling(), usize::MAX, &mut needed);
    assert_eq!(rc, INVALID_ARGUMENT);
    // Misaligned output and input pointers.
    let mut raw = [0u64; 16];
    let misaligned = (raw.as_mut_ptr() as *mut u8).wrapping_add(1);
    let rc = engine::slick_engine_query(e, s, q.as_ptr(), q.len(), misaligned.cast(), 2);
    assert_eq!(rc, INVALID_ARGUMENT);
    let rc = engine::slick_engine_set_context(e, misaligned.cast());
    assert_eq!(rc, INVALID_ARGUMENT);
    let rc = engine::slick_engine_replace_source(e, 1, misaligned.cast(), 1, batch.strings.as_ptr(), 1);
    assert_eq!(rc, INVALID_ARGUMENT);
    // A span whose start plus length overflows u32 arithmetic.
    let item = SlickItem {
        key: 5,
        title_start: u32::MAX,
        title_len: u32::MAX,
        ..SlickItem::default()
    };
    let rc = engine::slick_engine_upsert(e, 1, &item, batch.strings.as_ptr(), batch.strings.len());
    assert_eq!(rc, INVALID_ARGUMENT);
    // Every refusal left the engine working.
    assert_eq!(engine::slick_engine_count(e), 3);
    assert_eq!(query(e, s, "saf")[0].key, batch.items[0].key);
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(engine::slick_engine_close(e), OK);
}

#[test]
fn null_handles_and_output_slots_are_refused() {
    let e = open_in_memory();
    let s = new_session();
    let q = b"s";
    let mut out = [SlickHit::default(); 2];
    assert_eq!(engine::slick_engine_count(null()), NULL_POINTER);
    assert_eq!(engine::slick_engine_remove(null(), 1), NULL_POINTER);
    assert_eq!(engine::slick_engine_flush(null()), NULL_POINTER);
    assert_eq!(engine::slick_engine_forget(null(), 1), NULL_POINTER);
    assert_eq!(engine::slick_engine_forget_query(null(), q.as_ptr(), 1), NULL_POINTER);
    assert_eq!(engine::slick_engine_forget_query(e, null(), 1), NULL_POINTER);
    assert_eq!(
        engine::slick_engine_forget_query(e, null(), 0),
        0,
        "an empty query has no row"
    );
    let bad = [0xffu8, 0xfe];
    assert_eq!(
        engine::slick_engine_forget_query(e, bad.as_ptr(), bad.len()),
        SlickStatus::InvalidUtf8 as i32
    );
    assert_eq!(engine::slick_engine_undo(null(), 1, 0.0), NULL_POINTER);
    assert_eq!(engine::slick_engine_seed(null(), 1, 0.2, 0.0), NULL_POINTER);
    assert_eq!(engine::slick_engine_reset_learning(null()), NULL_POINTER);
    assert_eq!(engine::slick_engine_set_learning_paused(null(), true), NULL_POINTER);
    assert_eq!(engine::slick_engine_upsert(e, 1, null(), q.as_ptr(), 1), NULL_POINTER);
    assert_eq!(
        engine::slick_engine_ranges(e, null_mut(), 1, out.as_mut_ptr().cast(), 1),
        NULL_POINTER
    );
    assert_eq!(
        engine::slick_engine_completion(e, s, null_mut(), null_mut(), 0),
        NULL_POINTER
    );
    let mut needed = 0usize;
    assert_eq!(engine::slick_engine_stats(e, null_mut(), 0, null_mut()), NULL_POINTER);
    assert_eq!(
        engine::slick_engine_stats(null(), null_mut(), 0, &mut needed),
        NULL_POINTER
    );
    assert_eq!(engine::slick_engine_suggestions(e, null_mut(), 3), NULL_POINTER);
    assert_eq!(session::slick_session_new(null_mut()), NULL_POINTER);
    assert_eq!(session::slick_session_reset(null_mut()), NULL_POINTER);
    assert_eq!(index::slick_index_new(null_mut()), NULL_POINTER);
    assert_eq!(index::slick_index_count(null()), NULL_POINTER);
    assert_eq!(
        index::slick_index_query(null(), s, q.as_ptr(), 1, out.as_mut_ptr(), 2),
        NULL_POINTER
    );
    assert_eq!(index::slick_index_free(null_mut()), OK);
    assert_eq!(session::slick_session_free(null_mut()), OK);
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(engine::slick_engine_close(e), OK);
}

#[test]
fn non_finite_numbers_and_out_of_range_bytes_are_harmless() {
    let e = open_in_memory();
    let s = new_session();
    let batch = catalog(e);
    let safari = batch.items[0].key;
    for now in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0e300, 0.0, 1.0e300] {
        let c = SlickContext {
            now,
            since_previous: now,
            hour: 255,
            weekday: 255,
            display_count: 255,
            audio_route: 255,
            flags: 255,
            previous: safari,
            ..SlickContext::default()
        };
        assert_eq!(engine::slick_engine_set_context(e, &c), OK, "{now}");
        assert_eq!(
            engine::slick_engine_record(e, safari, b"saf".as_ptr(), 3, 0, 255, now),
            1
        );
        assert!(engine::slick_engine_undo(e, safari, now) >= 0);
        assert_eq!(engine::slick_engine_seed(e, safari, now as f32, now), OK);
        assert_eq!(query(e, s, "saf")[0].key, safari);
    }
    for weight in [f32::NAN, f32::INFINITY, -1.0, 0.0] {
        assert_eq!(engine::slick_engine_seed(e, safari, weight, 1.0e9), OK);
    }
    let mut item = batch.items[1];
    item.prior = f32::NAN;
    item.kind = 255;
    item.flags = u32::MAX;
    let rc = engine::slick_engine_upsert(e, 1, &item, batch.strings.as_ptr(), batch.strings.len());
    assert_eq!(rc, OK);
    assert_eq!(query(e, s, "terminal")[0].key, item.key);
    let json = stats(e);
    assert!(!json.contains("NaN") && !json.contains("inf"), "{json}");
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(engine::slick_engine_close(e), OK);
}

/// Raw handles shared across threads, as Swift shares the engine.
#[derive(Clone, Copy)]
struct Shared(*const SlickEngine);
// SAFETY: the engine handle is documented as safe to use from any thread at once; the test frees
// it only after joining every thread.
unsafe impl Send for Shared {}

#[test]
fn many_threads_query_while_others_replace_and_record() {
    let e = open_in_memory();
    let batch = catalog(e);
    let shared = Shared(e);
    let mut threads = Vec::new();
    for t in 0..4 {
        threads.push(std::thread::spawn(move || {
            let e = shared;
            let s = new_session();
            let mut out = [SlickHit::default(); 8];
            for i in 0..2_000 {
                let q = ["s", "sa", "saf", "t", "te", "ter", "dark", "web"][(i + t) % 8];
                let n = engine::slick_engine_query(e.0, s, q.as_ptr(), q.len(), out.as_mut_ptr(), 8);
                assert!(n >= 0, "status {n}");
                let mut key = 0u64;
                let mut text = [0u8; 64];
                let n = engine::slick_engine_completion(e.0, s, &mut key, text.as_mut_ptr(), 64);
                assert!(n >= 0, "status {n}");
            }
            assert_eq!(session::slick_session_free(s), OK);
        }));
    }
    let (items, strings) = (batch.items.clone(), batch.strings.clone());
    threads.push(std::thread::spawn(move || {
        let e = shared;
        for i in 0..300 {
            let n = 1 + i % items.len();
            let rc = engine::slick_engine_replace_source(e.0, 1, items.as_ptr(), n, strings.as_ptr(), strings.len());
            assert_eq!(rc, OK);
            let rc = engine::slick_engine_record(e.0, items[0].key, b"saf".as_ptr(), 3, 0, 0, 1.0e9 + i as f64);
            assert_eq!(rc, 1);
            let mut needed = 0usize;
            let mut buf = [0u8; 16];
            let rc = engine::slick_engine_stats(e.0, buf.as_mut_ptr(), buf.len(), &mut needed);
            assert_eq!(rc, SlickStatus::BufferTooSmall as i32);
        }
    }));
    for t in threads {
        t.join().expect("thread");
    }
    assert!(stats(e).contains("\"events\":300"));
    assert_eq!(engine::slick_engine_close(e), OK);
}
