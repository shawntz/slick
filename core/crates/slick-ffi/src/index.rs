//! C ABI for the generic fuzzy indexes that features build: the `slick_index_*` functions over
//! `slick-engine`. They share the matcher with root search and none of the learning. An index
//! handle is safe to use from any thread at once.

use crate::args::{SlickItem, bytes, handle, handle_mut, items, out, slice, text};
use crate::session::{SlickHit, SlickRange, SlickSession, write_hits, write_ranges};
use crate::status::{SlickStatus, guard, guard_result};
use slick_engine::FuzzyIndex;

/// An opaque fuzzy index.
pub struct SlickIndex {
    inner: FuzzyIndex,
}

fn index<'a>(i: *const SlickIndex) -> Result<&'a FuzzyIndex, SlickStatus> {
    Ok(&handle(i)?.inner)
}

/// Creates an empty index and stores it in `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_index_new(out: *mut *mut SlickIndex) -> i32 {
    guard_result(|| {
        *handle_mut(out)? = Box::into_raw(Box::new(SlickIndex {
            inner: FuzzyIndex::new(),
        }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Frees an index. NULL is allowed.
#[unsafe(no_mangle)]
pub extern "C" fn slick_index_free(index: *mut SlickIndex) -> i32 {
    guard(|| {
        if !index.is_null() {
            // SAFETY: a non-NULL index came from `slick_index_new` and is freed once.
            drop(unsafe { Box::from_raw(index) });
        }
        SlickStatus::Ok as i32
    })
}

/// Replaces every item. An item's prior lifts it within its tier; kind and flags are ignored.
#[unsafe(no_mangle)]
pub extern "C" fn slick_index_set_items(
    index: *const SlickIndex,
    item_list: *const SlickItem,
    count: usize,
    strings: *const u8,
    strings_len: usize,
) -> i32 {
    guard_result(|| {
        let ix = self::index(index)?;
        let list = items(slice(item_list, count)?, bytes(strings, strings_len)?)?;
        ix.set_items(&list)?;
        Ok(SlickStatus::Ok as i32)
    })
}

/// Returns the number of items.
#[unsafe(no_mangle)]
pub extern "C" fn slick_index_count(index: *const SlickIndex) -> i32 {
    guard_result(|| Ok(self::index(index)?.len()?.min(i32::MAX as usize) as i32))
}

/// Ranks the items for `query` (UTF-8) into `out` and returns the number of hits, at most `cap`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_index_query(
    index: *const SlickIndex,
    session: *mut SlickSession,
    query: *const u8,
    len: usize,
    out: *mut SlickHit,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let ix = self::index(index)?;
        let s = handle_mut(session)?;
        let dst = self::out(out, cap)?;
        let hits = ix.query(&mut s.inner, text(query, len)?, dst.len())?;
        Ok(write_hits(hits, dst))
    })
}

/// Writes the UTF-16 highlight ranges of `key`'s title for the session's last query into `out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_index_ranges(
    index: *const SlickIndex,
    session: *mut SlickSession,
    key: u64,
    out: *mut SlickRange,
    cap: usize,
) -> i32 {
    guard_result(|| {
        let ix = self::index(index)?;
        let s = handle_mut(session)?;
        write_ranges(ix.ranges(&mut s.inner, key)?, out, cap)
    })
}
