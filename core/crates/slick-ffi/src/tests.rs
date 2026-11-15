//! The C ABI exercised the way Swift calls it: raw pointers, caller buffers and status codes.

use super::*;
use std::ptr::{null, null_mut};

mod alloc;
mod calc;
mod files;
mod hostile;

const OK: i32 = SlickStatus::Ok as i32;

/// Items and the strings buffer their spans point into.
struct Batch {
    items: Vec<SlickItem>,
    strings: Vec<u8>,
}

impl Batch {
    fn new(list: &[(&str, &str, &str, u8)]) -> Batch {
        let mut b = Batch {
            items: Vec::new(),
            strings: Vec::new(),
        };
        for &(title, aliases, keywords, kind) in list {
            let mut span = |s: &str| {
                let start = b.strings.len() as u32;
                b.strings.extend_from_slice(s.replace('|', "\u{1f}").as_bytes());
                (start, b.strings.len() as u32 - start)
            };
            let (title_start, title_len) = span(title);
            let (aliases_start, aliases_len) = span(aliases);
            let (keywords_start, keywords_len) = span(keywords);
            b.items.push(SlickItem {
                key: slick_engine::key_of(format!("app:{title}").as_bytes()),
                title_start,
                title_len,
                aliases_start,
                aliases_len,
                keywords_start,
                keywords_len,
                kind,
                ..SlickItem::default()
            });
        }
        b
    }
}

fn open_in_memory() -> *mut SlickEngine {
    let mut e = null_mut();
    assert_eq!(engine::slick_engine_open(null(), 0, &mut e), OK);
    e
}

fn query(e: *const SlickEngine, s: *mut SlickSession, q: &str) -> Vec<SlickHit> {
    let mut out = [SlickHit::default(); 10];
    let n = engine::slick_engine_query(e, s, q.as_ptr(), q.len(), out.as_mut_ptr(), out.len());
    assert!(n >= 0, "status {n}");
    out[..n as usize].to_vec()
}

#[test]
fn the_abi_version_noop_and_panic_guard() {
    assert_eq!(slick_abi_version(), SLICK_ABI_VERSION);
    assert_eq!(slick_noop(), OK);
    assert_eq!(slick_debug_panic(), SlickStatus::Panic as i32);
}

#[test]
fn constants_match_the_engine() {
    use slick_engine::{Source, audio, flags, hit_flags, kind};
    assert_eq!(
        (SLICK_ITEM_NO_SUGGEST, SLICK_ITEM_NO_LEARN),
        (flags::NO_SUGGEST, flags::NO_LEARN)
    );
    let kinds = [
        SLICK_KIND_OTHER,
        SLICK_KIND_APP,
        SLICK_KIND_COMMAND,
        SLICK_KIND_FILE,
        SLICK_KIND_SETTING,
    ];
    assert_eq!(
        kinds,
        [kind::OTHER, kind::APP, kind::COMMAND, kind::FILE, kind::SETTING]
    );
    assert_eq!(SLICK_KIND_CONTACT, kind::CONTACT);
    let hits = [SLICK_HIT_ALIAS, SLICK_HIT_LEARNED, SLICK_HIT_AFFINITY];
    assert_eq!(hits, [hit_flags::ALIAS, hit_flags::LEARNED, hit_flags::AFFINITY]);
    let routes = [
        SLICK_AUDIO_BUILT_IN,
        SLICK_AUDIO_HEADPHONES,
        SLICK_AUDIO_BLUETOOTH,
        SLICK_AUDIO_USB,
        SLICK_AUDIO_OTHER,
    ];
    assert_eq!(
        routes,
        [
            audio::BUILT_IN,
            audio::HEADPHONES,
            audio::BLUETOOTH,
            audio::USB,
            audio::OTHER
        ]
    );
    let sources = [
        (SLICK_SOURCE_TYPED, Source::Typed),
        (SLICK_SOURCE_SUGGESTION, Source::Suggestion),
        (SLICK_SOURCE_HOTKEY, Source::Hotkey),
        (SLICK_SOURCE_ALIAS, Source::Alias),
        (SLICK_SOURCE_FALLBACK, Source::Fallback),
    ];
    for (c, s) in sources {
        assert_eq!(Source::from_u8(c), Some(s));
    }
}

#[test]
fn the_key_test_vector_is_fnv1a() {
    assert_eq!(slick_engine::key_of(b"app:com.example.Editor"), SLICK_KEY_TEST_VALUE);
    assert_eq!(slick_engine::key_of(b""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(slick_engine::key_of(b"a"), 0xaf63_dc4c_8601_ec8c);
}

#[test]
fn layouts_are_fixed() {
    assert_eq!(size_of::<SlickHit>(), 16);
    assert_eq!(size_of::<SlickRange>(), 8);
    assert_eq!(size_of::<SlickSuggestion>(), 16);
    assert_eq!(size_of::<SlickItem>(), 48);
    assert_eq!(size_of::<SlickContext>(), 40);
}

#[test]
fn search_learn_and_inspect_through_the_c_abi() {
    let e = open_in_memory();
    let batch = Batch::new(&[
        ("Safari", "", "browser|web", SLICK_KIND_APP),
        ("Terminal", "Shell", "", SLICK_KIND_APP),
        ("Term", "", "", SLICK_KIND_APP),
        ("Café Finder", "", "", SLICK_KIND_COMMAND),
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
    assert_eq!(engine::slick_engine_count(e), 4);
    let context = SlickContext {
        now: 1_780_000_000.0,
        hour: 9,
        display_count: 1,
        ..SlickContext::default()
    };
    assert_eq!(engine::slick_engine_set_context(e, &context), OK);
    let mut s = null_mut();
    assert_eq!(session::slick_session_new(&mut s), OK);
    let key = |i: usize| batch.items[i].key;
    assert_eq!(query(e, s, "web")[0].key, key(0));
    assert_eq!(query(e, s, "shell")[0].key, key(1));
    let hits = query(e, s, "term");
    assert_eq!(hits[0].key, key(2), "an exact title first");
    // Highlights, UTF-16.
    query(e, s, "cafe");
    let mut ranges = [SlickRange::default(); 4];
    let n = engine::slick_engine_ranges(e, s, key(3), ranges.as_mut_ptr(), ranges.len());
    assert_eq!(&ranges[..n as usize], &[SlickRange { start: 0, length: 4 }]);
    // Learn Terminal for "term" twice: the learned band.
    for t in [1.0, 2.0] {
        let q = "term";
        let rc = engine::slick_engine_record(
            e,
            key(1),
            q.as_ptr(),
            q.len(),
            SLICK_SOURCE_TYPED,
            1,
            1_780_000_000.0 + t,
        );
        assert_eq!(rc, 1);
    }
    let hits = query(e, s, "term");
    assert_eq!((hits[0].key, hits[0].flags), (key(1), SLICK_HIT_LEARNED));
    // Inline completion.
    let (mut k, mut text) = (0u64, [0u8; 32]);
    let n = engine::slick_engine_completion(e, s, &mut k, text.as_mut_ptr(), text.len());
    assert_eq!((k, &text[..n as usize]), (key(1), &b"inal"[..]));
    let mut tiny = [0u8; 2];
    let rc = engine::slick_engine_completion(e, s, &mut k, tiny.as_mut_ptr(), tiny.len());
    assert_eq!(rc, SlickStatus::BufferTooSmall as i32);
    // Undo the second pick inside the window.
    assert_eq!(engine::slick_engine_undo(e, key(1), 1_780_000_004.0), 1);
    assert_eq!(query(e, s, "term")[0].key, key(2));
    // Suggestions never include the frontmost app.
    let mut sugg = [SlickSuggestion::default(); 8];
    let n = engine::slick_engine_suggestions(e, sugg.as_mut_ptr(), sugg.len());
    assert_eq!(sugg[0].key, key(1));
    assert!(n >= 1);
    let front = SlickContext {
        frontmost: key(1),
        ..context
    };
    assert_eq!(engine::slick_engine_set_context(e, &front), OK);
    let n = engine::slick_engine_suggestions(e, sugg.as_mut_ptr(), sugg.len());
    assert!(sugg[..n as usize].iter().all(|x| x.key != key(1)));
    // Statistics, with the size probe.
    let mut len = 0usize;
    let rc = engine::slick_engine_stats(e, null_mut(), 0, &mut len);
    assert_eq!(rc, SlickStatus::BufferTooSmall as i32);
    let mut json = vec![0u8; len];
    assert_eq!(
        engine::slick_engine_stats(e, json.as_mut_ptr(), json.len(), &mut len),
        OK
    );
    assert!(std::str::from_utf8(&json).is_ok_and(|j| j.contains("\"undone\":1")));
    // Forget one query's learned row: "term" ranks by text again, and a second forget finds none.
    let q = "  TERM ";
    assert_eq!(engine::slick_engine_forget_query(e, q.as_ptr(), q.len()), 1);
    assert_eq!(engine::slick_engine_forget_query(e, q.as_ptr(), q.len()), 0);
    assert!(
        query(e, s, "term")
            .iter()
            .all(|h| h.flags & (SLICK_HIT_LEARNED | SLICK_HIT_AFFINITY) == 0)
    );
    assert_eq!(query(e, s, "term")[0].key, key(2));
    // Forget, pause, reset.
    assert_eq!(engine::slick_engine_forget(e, key(1)), OK);
    assert_eq!(engine::slick_engine_set_learning_paused(e, true), OK);
    let q = "term";
    assert_eq!(
        engine::slick_engine_record(e, key(1), q.as_ptr(), q.len(), SLICK_SOURCE_TYPED, 0, 1_780_000_100.0),
        0
    );
    assert_eq!(engine::slick_engine_reset_learning(e), OK);
    assert_eq!(engine::slick_engine_seed(e, key(0), 0.3, 1_780_000_000.0), OK);
    assert_eq!(engine::slick_engine_flush(e), OK);
    // Catalog changes.
    assert_eq!(engine::slick_engine_remove(e, key(0)), OK);
    let one = Batch::new(&[("Notes", "", "", SLICK_KIND_APP)]);
    let rc = engine::slick_engine_upsert(e, 2, one.items.as_ptr(), one.strings.as_ptr(), one.strings.len());
    assert_eq!(rc, OK);
    assert_eq!(engine::slick_engine_count(e), 4);
    let alias = "nn";
    assert_eq!(
        engine::slick_engine_set_alias(e, one.items[0].key, alias.as_ptr(), alias.len()),
        OK
    );
    assert_eq!(query(e, s, "nn")[0].tier, 10);
    assert_eq!(session::slick_session_reset(s), OK);
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(engine::slick_engine_close(e), OK);
}

#[test]
fn bad_arguments_come_back_as_statuses() {
    let e = open_in_memory();
    let mut s = null_mut();
    assert_eq!(session::slick_session_new(&mut s), OK);
    let mut out = [SlickHit::default(); 2];
    let bad = [0xffu8, 0xfe];
    let rc = engine::slick_engine_query(e, s, bad.as_ptr(), bad.len(), out.as_mut_ptr(), out.len());
    assert_eq!(rc, SlickStatus::InvalidUtf8 as i32);
    let rc = engine::slick_engine_query(null(), s, null(), 0, out.as_mut_ptr(), out.len());
    assert_eq!(rc, SlickStatus::NullPointer as i32);
    let rc = engine::slick_engine_query(e, s, b"x".as_ptr(), 1, null_mut(), 5);
    assert_eq!(rc, SlickStatus::NullPointer as i32);
    let rc = engine::slick_engine_query(e, null_mut(), b"x".as_ptr(), 1, out.as_mut_ptr(), 2);
    assert_eq!(rc, SlickStatus::NullPointer as i32);
    let item = SlickItem {
        title_len: 100,
        ..SlickItem::default()
    };
    let rc = engine::slick_engine_replace_source(e, 1, &item, 1, b"short".as_ptr(), 5);
    assert_eq!(rc, SlickStatus::InvalidArgument as i32);
    let q = "x";
    let rc = engine::slick_engine_record(e, 1, q.as_ptr(), 1, 9, 0, 0.0);
    assert_eq!(rc, SlickStatus::InvalidArgument as i32);
    assert_eq!(
        engine::slick_engine_set_context(e, null()),
        SlickStatus::NullPointer as i32
    );
    assert_eq!(
        engine::slick_engine_open(null(), 0, null_mut()),
        SlickStatus::NullPointer as i32
    );
    // A data directory that cannot be created is an I/O error, not a crash.
    let file = concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml/not-a-directory");
    let mut e2 = null_mut();
    assert_eq!(
        engine::slick_engine_open(file.as_ptr(), file.len(), &mut e2),
        SlickStatus::Io as i32
    );
    assert!(e2.is_null());
    assert_eq!(engine::slick_engine_close(null_mut()), OK);
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(engine::slick_engine_close(e), OK);
}

#[test]
fn fuzzy_indexes_through_the_c_abi() {
    let mut ix = null_mut();
    assert_eq!(index::slick_index_new(&mut ix), OK);
    let batch = Batch::new(&[
        ("Party Popper 🎉", "", "celebrate", 0),
        ("Grinning Face 😀", "", "smile", 0),
    ]);
    let rc = index::slick_index_set_items(ix, batch.items.as_ptr(), 2, batch.strings.as_ptr(), batch.strings.len());
    assert_eq!(rc, OK);
    assert_eq!(index::slick_index_count(ix), 2);
    let mut s = null_mut();
    assert_eq!(session::slick_session_new(&mut s), OK);
    let mut out = [SlickHit::default(); 4];
    let q = "smile";
    let n = index::slick_index_query(ix, s, q.as_ptr(), q.len(), out.as_mut_ptr(), out.len());
    assert_eq!((n, out[0].key, out[0].field), (1, batch.items[1].key, 2));
    let q = "party";
    index::slick_index_query(ix, s, q.as_ptr(), q.len(), out.as_mut_ptr(), out.len());
    let mut ranges = [SlickRange::default(); 2];
    let n = index::slick_index_ranges(ix, s, batch.items[0].key, ranges.as_mut_ptr(), 2);
    assert_eq!(&ranges[..n as usize], &[SlickRange { start: 0, length: 5 }]);
    assert_eq!(session::slick_session_free(s), OK);
    assert_eq!(index::slick_index_free(ix), OK);
}

#[test]
fn the_learning_summary_through_the_c_abi() {
    let e = open_in_memory();
    let batch = Batch::new(&[("Terminal", "", "", SLICK_KIND_APP), ("Notes", "", "", SLICK_KIND_APP)]);
    let rc = engine::slick_engine_replace_source(
        e,
        1,
        batch.items.as_ptr(),
        batch.items.len(),
        batch.strings.as_ptr(),
        batch.strings.len(),
    );
    assert_eq!(rc, OK);
    let mut s = SlickLearningSummary::default();
    assert_eq!(engine::slick_engine_summary(e, &mut s), OK);
    assert_eq!((s.events, s.items, s.queries), (0, 0, 0));
    assert!(s.first_event.is_nan(), "no first event");
    for (i, t) in [(0, 1.0), (0, 2.0), (1, 3.0)] {
        let q = "te";
        let rc = engine::slick_engine_record(
            e,
            batch.items[i].key,
            q.as_ptr(),
            q.len(),
            SLICK_SOURCE_TYPED,
            0,
            1_780_000_000.0 + t * 60.0,
        );
        assert_eq!(rc, 1);
    }
    assert_eq!(engine::slick_engine_summary(e, &mut s), OK);
    assert_eq!((s.events, s.items, s.queries), (3, 2, 2));
    assert!((s.first_event - 1_780_000_060.0).abs() < 61.0, "{}", s.first_event);
    assert_eq!(
        engine::slick_engine_summary(e, null_mut()),
        SlickStatus::NullPointer as i32
    );
    assert_eq!(
        engine::slick_engine_summary(null(), &mut s),
        SlickStatus::NullPointer as i32
    );
    assert_eq!(size_of::<SlickLearningSummary>(), 32);
    assert_eq!(engine::slick_engine_close(e), OK);
}
