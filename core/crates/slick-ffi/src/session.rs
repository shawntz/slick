//! C ABI for query sessions: the `slick_session_*` functions. A session holds one panel's query
//! state (the narrowing stack and reusable buffers) and works with the engine and every fuzzy
//! index. Use a session from one thread at a time.

use crate::args::{handle_mut, out};
use crate::status::{SlickStatus, guard, guard_result};
use slick_engine::{Hit, Session};

/// An opaque query session.
pub struct SlickSession {
    pub(crate) inner: Session,
}

/// One ranked result, 16 bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickHit {
    /// Item key.
    pub key: u64,
    /// Rank; higher is better.
    pub rank: i32,
    /// Text tier 0 (subsequence) to 6 (exact); 8 learned band, 9 alias prefix, 10 alias exact.
    pub tier: u8,
    /// 0 title, 1 alias, 2 keyword, 3 user alias, 255 none.
    pub field: u8,
    /// The item's kind.
    pub kind: u8,
    /// `SLICK_HIT_ALIAS`, `SLICK_HIT_LEARNED`, `SLICK_HIT_AFFINITY`.
    pub flags: u8,
}

/// A highlight range in UTF-16 code units.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlickRange {
    /// First UTF-16 unit.
    pub start: u32,
    /// Number of UTF-16 units.
    pub length: u32,
}

/// Copies `hits` into the caller's buffer (checked with `args::out` before the query ran) and
/// returns how many were written.
pub(crate) fn write_hits(hits: &[Hit], dst: &mut [SlickHit]) -> i32 {
    for (d, h) in dst.iter_mut().zip(hits.iter()) {
        *d = SlickHit {
            key: h.key,
            rank: h.rank,
            tier: h.tier,
            field: h.field,
            kind: h.kind,
            flags: h.flags,
        };
    }
    hits.len().min(dst.len()) as i32
}

/// Copies UTF-16 ranges into the caller's buffer and returns how many were written.
pub(crate) fn write_ranges(ranges: &[(u32, u32)], ptr: *mut SlickRange, cap: usize) -> Result<i32, SlickStatus> {
    let dst = out(ptr, cap)?;
    for (d, &(start, length)) in dst.iter_mut().zip(ranges) {
        *d = SlickRange { start, length };
    }
    Ok(ranges.len().min(cap) as i32)
}

/// Creates a session and stores it in `*out`.
#[unsafe(no_mangle)]
pub extern "C" fn slick_session_new(out: *mut *mut SlickSession) -> i32 {
    guard_result(|| {
        let slot = handle_mut(out)?;
        *slot = Box::into_raw(Box::new(SlickSession { inner: Session::new() }));
        Ok(SlickStatus::Ok as i32)
    })
}

/// Frees a session. NULL is allowed.
#[unsafe(no_mangle)]
pub extern "C" fn slick_session_free(session: *mut SlickSession) -> i32 {
    guard(|| {
        if !session.is_null() {
            // SAFETY: a non-NULL session came from `slick_session_new` and is freed once.
            drop(unsafe { Box::from_raw(session) });
        }
        SlickStatus::Ok as i32
    })
}

/// Forgets the session's earlier queries. Call it when the launcher is summoned.
#[unsafe(no_mangle)]
pub extern "C" fn slick_session_reset(session: *mut SlickSession) -> i32 {
    guard_result(|| {
        handle_mut(session)?.inner.reset();
        Ok(SlickStatus::Ok as i32)
    })
}
