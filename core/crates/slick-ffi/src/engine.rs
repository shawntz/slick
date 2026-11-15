//! C ABI for root search: the `slick_engine_*` functions over `slick-engine`.
//!
//! An engine handle is safe to use from any thread at once. Sessions are not: each belongs to one
//! thread at a time.

use crate::args::{SlickItem, bytes, handle, handle_mut, items, out, slice, text};
use crate::session::{SlickHit, SlickRange, SlickSession, write_hits, write_ranges};
use crate::status::{SlickStatus, guard, guard_result};
use slick_engine::{Context, Engine, EngineParams, Source};
use std::path::Path;

/// An opaque root search engine.
pub struct SlickEngine {
    inner: Engine,
}

/// `SlickContext.flags`: running on battery.
pub const SLICK_CONTEXT_ON_BATTERY: u8 = 1;
/// `SlickContext.flags`: first summon after two hours idle, a wake or an unlock.
pub const SLICK_CONTEXT_SESSION_START: u8 = 2;
/// `SlickContext.flags`: a Focus mode is on.
pub const SLICK_CONTEXT_FOCUS: u8 = 4;

/// The context, set whenever one of its values changes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlickContext {
    /// Unix time, seconds.
    pub now: f64,
    /// Key of the frontmost app, 0 when unknown. It is never suggested.
    pub frontmost: u64,
    /// Key of the previously executed item, 0 to use the engine's own record.
    pub previous: u64,
    /// Seconds since `previous` ran.
    pub since_previous: f64,
    /// Local hour, 0..=23.
    pub hour: u8,
    /// Local weekday, 0 = Monday ..= 6 = Sunday.
    pub weekday: u8,
    /// Connected displays.
    pub display_count: u8,
    /// `SLICK_AUDIO_*`.
    pub audio_route: u8,
    /// `SLICK_CONTEXT_*` bits.
    pub flags: u8,
    /// Zero.
    pub reserved: [u8; 3],
}

/// One zero-query suggestion, 16 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlickSuggestion {
    /// Item key.
    pub key: u64,
    /// Model score; higher is better. Comparable only within one list.
    pub score: f32,
    /// Zero.
    pub reserved: u32,
}

/// The headline numbers of the learning inspector, 32 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlickLearningSummary {
    /// Executions learned, undone ones excluded.
    pub events: u64,
    /// Items with at least one learned execution that were not forgotten since.
    pub items: u64,
    /// Learned queries the statistics name.
    pub queries: u64,
    /// Unix time of the oldest learned execution of those items, in seconds. NaN when none.
    pub first_event: f64,
}

fn engine<'a>(e: *const SlickEngine) -> Result<&'a Engine, SlickStatus> {
    Ok(&handle(e)?.inner)
}

fn ok(r: Result<(), slick_engine::EngineError>) -> Result<i32, SlickStatus> {
    r.map(|_| SlickStatus::Ok as i32).map_err(SlickStatus::from)
}

/// Opens an engine that persists its learning under the directory `dir` (UTF-8, created when
/// missing) and stores it in `*out`. With `dir_len` 0 the engine keeps everything in memory.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_open(dir: *const u8, dir_len: usize, out: *mut *mut SlickEngine) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        let dir = text(dir, dir_len)?;
        let inner = if dir.is_empty() {
            Engine::in_memory(EngineParams::default())
        } else {
            Engine::open(Path::new(dir), EngineParams::default()).map_err(SlickStatus::from)?
        };
        *slot = Box::into_raw(Box::new(SlickEngine { inner }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Writes a final snapshot, stops the store and frees the engine. NULL is allowed.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_close(engine: *mut SlickEngine) -> i32 {
    guard(|| {
        if !engine.is_null() {
            // SAFETY: a non-NULL engine came from `slick_engine_open` and is closed once.
            drop(unsafe { Box::from_raw(engine) });
        }
        SlickStatus::Ok as i32
    })
}

/// Replaces every item of `source` with `count` items whose strings are spans of `strings`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_replace_source(
    engine: *const SlickEngine,
    source: u32,
    item_list: *const SlickItem,
    count: usize,
    strings: *const u8,
    strings_len: usize,
) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let list = items(slice(item_list, count)?, bytes(strings, strings_len)?)?;
        ok(e.replace_source(source, list))
    })
}

/// Adds or replaces one item of `source`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_upsert(
    engine: *const SlickEngine,
    source: u32,
    item: *const SlickItem,
    strings: *const u8,
    strings_len: usize,
) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let mut list = items(slice(item, 1)?, bytes(strings, strings_len)?)?;
        let one = list.pop().ok_or(SlickStatus::InvalidArgument)?;
        ok(e.upsert(source, one))
    })
}

/// Removes the item with `key` from the catalog. Its learning is kept.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_remove(engine: *const SlickEngine, key: u64) -> i32 {
    guard_result(|| ok(self::engine(engine)?.remove(key)))
}

/// Returns the number of items in the catalog.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_count(engine: *const SlickEngine) -> i32 {
    guard_result(|| Ok(self::engine(engine)?.len()?.min(i32::MAX as usize) as i32))
}

/// Sets the user alias of `key` (UTF-8); an empty alias removes it. Not persisted: set aliases at
/// launch from the app's settings.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_set_alias(engine: *const SlickEngine, key: u64, alias: *const u8, len: usize) -> i32 {
    guard_result(|| ok(self::engine(engine)?.set_alias(key, text(alias, len)?)))
}

/// Sets the context and recomputes the suggestions and the context prior.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_set_context(engine: *const SlickEngine, context: *const SlickContext) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let c = handle(context)?;
        ok(e.set_context(Context {
            now: c.now,
            hour: c.hour,
            weekday: c.weekday,
            frontmost: c.frontmost,
            previous: c.previous,
            since_previous: c.since_previous,
            on_battery: c.flags & SLICK_CONTEXT_ON_BATTERY != 0,
            display_count: c.display_count,
            audio_route: c.audio_route,
            session_start: c.flags & SLICK_CONTEXT_SESSION_START != 0,
            focus: c.flags & SLICK_CONTEXT_FOCUS != 0,
        }))
    })
}

/// Ranks the catalog for `query` (UTF-8) into `out` and returns the number of hits, at most `cap`.
/// Allocates nothing once the session has seen a few queries.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_query(
    engine: *const SlickEngine,
    session: *mut SlickSession,
    query: *const u8,
    len: usize,
    out: *mut SlickHit,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let s = handle_mut(session)?;
        let dst = self::out(out, cap)?;
        let hits = e.query(&mut s.inner, text(query, len)?, dst.len())?;
        Ok(write_hits(hits, dst))
    })
}

/// Writes the UTF-16 highlight ranges of `key`'s title for the session's last query into `out`
/// and returns how many were written. Call it for visible rows only.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_ranges(
    engine: *const SlickEngine,
    session: *mut SlickSession,
    key: u64,
    out: *mut SlickRange,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let s = handle_mut(session)?;
        write_ranges(e.ranges(&mut s.inner, key)?, out, cap)
    })
}

/// The inline completion for the session's top hit. Writes the text to show after the typed
/// query (UTF-8) into `out`, the hit's key into `*out_key`, and returns its length in bytes; 0
/// when there is no completion. Returns `SLICK_STATUS_BUFFER_TOO_SMALL` when it does not fit.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_completion(
    engine: *const SlickEngine,
    session: *mut SlickSession,
    out_key: *mut u64,
    out: *mut u8,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let s = handle_mut(session)?;
        let key = handle_mut(out_key)?;
        *key = 0;
        let Some((k, rest)) = e.completion(&mut s.inner)? else {
            return Ok(0);
        };
        let dst = self::out(out, cap)?;
        let dst = dst.get_mut(..rest.len()).ok_or(SlickStatus::BufferTooSmall)?;
        dst.copy_from_slice(rest.as_bytes());
        *key = k;
        Ok(rest.len() as i32)
    })
}

/// Writes the zero-query suggestions for the current context into `out`, best first, and returns
/// how many were written. They are computed when the context or the learning changes.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_suggestions(engine: *const SlickEngine, out: *mut SlickSuggestion, cap: usize) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let mut list = Vec::with_capacity(slick_engine::SUGGESTIONS);
        e.suggestions(&mut list)?;
        let dst = self::out(out, cap)?;
        for (d, &(key, score)) in dst.iter_mut().zip(&list) {
            *d = SlickSuggestion {
                key,
                score,
                reserved: 0,
            };
        }
        Ok(list.len().min(cap) as i32)
    })
}

/// Learns that `key` ran after `query` (UTF-8, the raw field text) was typed, reached by `source`
/// (`SLICK_SOURCE_*`) from displayed row `rank` (255 for none), at Unix time `now`. Returns 1 when
/// learned, 0 when learning is paused or the item opts out. The log write happens on the store's
/// thread.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_record(
    engine: *const SlickEngine,
    key: u64,
    query: *const u8,
    len: usize,
    source: u8,
    rank: u8,
    now: f64,
) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let source = Source::from_u8(source).ok_or(SlickStatus::InvalidArgument)?;
        Ok(e.record(key, text(query, len)?, source, rank, now)? as i32)
    })
}

/// Removes the learning of the last execution when it was `key` and ran at most five seconds
/// before `now`. Returns 1 when something was undone, else 0.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_undo(engine: *const SlickEngine, key: u64, now: f64) -> i32 {
    guard_result(|| Ok(self::engine(engine)?.undo(key, now)? as i32))
}

/// Forgets everything learned about `key`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_forget(engine: *const SlickEngine, key: u64) -> i32 {
    guard_result(|| ok(self::engine(engine)?.forget(key)))
}

/// Forgets the learned row of one query (UTF-8, folded by the engine), so typing it ranks by text
/// again. Shorter queries it extends keep their learning. Returns 1 when the query had a row,
/// else 0.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_forget_query(engine: *const SlickEngine, query: *const u8, len: usize) -> i32 {
    guard_result(|| Ok(self::engine(engine)?.forget_query(text(query, len)?)? as i32))
}

/// A first-run seed: a light virtual use of `key` (weight around 0.15 to 0.3) at Unix time `at`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_seed(engine: *const SlickEngine, key: u64, weight: f32, at: f64) -> i32 {
    guard_result(|| ok(self::engine(engine)?.seed(key, weight, at)))
}

/// Pauses (true) or resumes learning. While paused, executions are neither learned nor logged.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_set_learning_paused(engine: *const SlickEngine, paused: bool) -> i32 {
    guard_result(|| ok(self::engine(engine)?.set_learning_paused(paused)))
}

/// Erases all learning, in memory and on disk.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_reset_learning(engine: *const SlickEngine) -> i32 {
    guard_result(|| ok(self::engine(engine)?.reset_learning()))
}

/// Waits until every log record so far is on disk.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_flush(engine: *const SlickEngine) -> i32 {
    guard_result(|| {
        self::engine(engine)?.flush();
        Ok(SlickStatus::Ok as i32)
    })
}

/// Writes the learning statistics as UTF-8 JSON into `out` and their length into `*out_len`.
/// Returns `SLICK_STATUS_BUFFER_TOO_SMALL` (with the needed length in `*out_len`) when they do
/// not fit.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_stats(engine: *const SlickEngine, out: *mut u8, cap: usize, out_len: *mut usize) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let needed = handle_mut(out_len)?;
        let json = e.stats_json()?;
        *needed = json.len();
        let dst = self::out(out, cap)?;
        let dst = dst.get_mut(..json.len()).ok_or(SlickStatus::BufferTooSmall)?;
        dst.copy_from_slice(json.as_bytes());
        Ok(SlickStatus::Ok as i32)
    })
}

/// Writes the headline numbers of the learning inspector into `*out`: learned executions, items
/// with a learned run, named queries and the time of the oldest run. Cheaper than the statistics.
#[unsafe(no_mangle)]
pub extern "C" fn slick_engine_summary(engine: *const SlickEngine, out: *mut SlickLearningSummary) -> i32 {
    guard_result(|| {
        let e = self::engine(engine)?;
        let dst = handle_mut(out)?;
        let s = e.summary()?;
        *dst = SlickLearningSummary {
            events: s.events,
            items: s.items,
            queries: s.queries,
            first_event: s.first_event.unwrap_or(f64::NAN),
        };
        Ok(SlickStatus::Ok as i32)
    })
}
