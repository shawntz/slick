//! Reading arguments from C: byte spans, UTF-8 strings, item lists and output buffers. Every
//! check returns a status instead of trusting the caller.

use crate::status::SlickStatus;
use slick_engine::Item;

/// Separates the aliases (or keywords) packed into one span of a `SlickItem`.
pub const SLICK_LIST_SEPARATOR: u8 = 0x1F;

/// One item for the engine's catalog or a fuzzy index. Its strings are spans into one UTF-8
/// buffer passed alongside the item array, so the caller builds a single byte buffer per call.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlickItem {
    /// FNV-1a hash of the item's id string; see `SLICK_KEY_TEST_INPUT`.
    pub key: u64,
    /// Byte offset of the title in the strings buffer.
    pub title_start: u32,
    /// Byte length of the title.
    pub title_len: u32,
    /// Byte offset of the aliases, separated by `SLICK_LIST_SEPARATOR`.
    pub aliases_start: u32,
    /// Byte length of the aliases (0 for none).
    pub aliases_len: u32,
    /// Byte offset of the keywords, separated by `SLICK_LIST_SEPARATOR`.
    pub keywords_start: u32,
    /// Byte length of the keywords (0 for none).
    pub keywords_len: u32,
    /// The item's own static prior in [0, 1], added to its kind prior.
    pub prior: f32,
    /// `SLICK_ITEM_NO_SUGGEST`, `SLICK_ITEM_NO_LEARN`.
    pub flags: u32,
    /// `SLICK_KIND_*`.
    pub kind: u8,
    /// Zero.
    pub reserved: [u8; 7],
}

/// Checks what Rust needs before it may view `count` values of `T` at `ptr` as a slice: a non-NULL,
/// aligned pointer and at most `isize::MAX` bytes. A count that large cannot describe a real buffer,
/// so it is refused instead of reaching `from_raw_parts`, where it would be undefined behaviour.
fn check_span<T>(ptr: *const T, count: usize) -> Result<(), SlickStatus> {
    if ptr.is_null() {
        return Err(SlickStatus::NullPointer);
    }
    let fits = count
        .checked_mul(size_of::<T>())
        .is_some_and(|n| n <= isize::MAX as usize);
    if !fits || !ptr.is_aligned() {
        return Err(SlickStatus::InvalidArgument);
    }
    Ok(())
}

/// A byte slice from a pointer and a length. A NULL pointer is allowed only with length 0.
pub(crate) fn bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], SlickStatus> {
    slice(ptr, len)
}

/// A UTF-8 string from a pointer and a length.
pub(crate) fn text<'a>(ptr: *const u8, len: usize) -> Result<&'a str, SlickStatus> {
    std::str::from_utf8(bytes(ptr, len)?).map_err(|_| SlickStatus::InvalidUtf8)
}

/// A slice of `T` from a pointer and a count. A NULL pointer is allowed only with count 0.
pub(crate) fn slice<'a, T>(ptr: *const T, count: usize) -> Result<&'a [T], SlickStatus> {
    if count == 0 {
        return Ok(&[]);
    }
    check_span(ptr, count)?;
    // SAFETY: the caller guarantees `ptr` points to `count` initialized values for the duration of
    // the call; `check_span` rejected NULL, misalignment and spans over `isize::MAX` bytes.
    Ok(unsafe { std::slice::from_raw_parts(ptr, count) })
}

/// A writable output buffer of `cap` elements. A NULL pointer is allowed only with `cap` 0.
pub(crate) fn out<'a, T>(ptr: *mut T, cap: usize) -> Result<&'a mut [T], SlickStatus> {
    if cap == 0 {
        return Ok(&mut []);
    }
    check_span(ptr, cap)?;
    // SAFETY: the caller guarantees `ptr` is valid for writes of `cap` elements and not aliased
    // for the duration of the call; `check_span` rejected NULL, misalignment and spans over
    // `isize::MAX` bytes. Every exported element type is plain old data, so any bit pattern
    // already there may be overwritten.
    Ok(unsafe { std::slice::from_raw_parts_mut(ptr, cap) })
}

/// A shared reference to a handle or an input struct.
pub(crate) fn handle<'a, T>(ptr: *const T) -> Result<&'a T, SlickStatus> {
    check_span(ptr, 1)?;
    // SAFETY: a non-NULL, aligned handle came from the matching `_new` or `_open` function and
    // has not been freed (the caller guarantees both); an input struct is valid for reads.
    Ok(unsafe { &*ptr })
}

/// An exclusive reference to a handle or an output slot.
pub(crate) fn handle_mut<'a, T>(ptr: *mut T) -> Result<&'a mut T, SlickStatus> {
    check_span(ptr, 1)?;
    // SAFETY: as for `handle`; in addition the caller guarantees no other call uses this handle
    // at the same time (sessions belong to one thread at a time).
    Ok(unsafe { &mut *ptr })
}

fn span(strings: &[u8], start: u32, len: u32) -> Result<&str, SlickStatus> {
    let (start, len) = (start as usize, len as usize);
    let end = start.checked_add(len).ok_or(SlickStatus::InvalidArgument)?;
    let b = strings.get(start..end).ok_or(SlickStatus::InvalidArgument)?;
    std::str::from_utf8(b).map_err(|_| SlickStatus::InvalidUtf8)
}

fn list(strings: &[u8], start: u32, len: u32) -> Result<Vec<String>, SlickStatus> {
    let s = span(strings, start, len)?;
    if s.is_empty() {
        return Ok(Vec::new());
    }
    Ok(s.split(SLICK_LIST_SEPARATOR as char).map(str::to_string).collect())
}

/// The engine items described by `items` over the `strings` buffer.
pub(crate) fn items(items: &[SlickItem], strings: &[u8]) -> Result<Vec<Item>, SlickStatus> {
    items
        .iter()
        .map(|i| {
            Ok(Item {
                key: i.key,
                title: span(strings, i.title_start, i.title_len)?.to_string(),
                aliases: list(strings, i.aliases_start, i.aliases_len)?,
                keywords: list(strings, i.keywords_start, i.keywords_len)?,
                kind: i.kind,
                prior: if i.prior.is_finite() { i.prior } else { 0.0 },
                flags: i.flags,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_are_checked() {
        let strings = b"Safari\x1fWeb\x1fBrowser\xff";
        let item = SlickItem {
            key: 1,
            title_len: 6,
            aliases_start: 7,
            aliases_len: 11,
            ..SlickItem::default()
        };
        let got = items(&[item], strings).expect("valid");
        assert_eq!(got[0].title, "Safari");
        assert_eq!(got[0].aliases, vec!["Web", "Browser"]);
        let past_end = SlickItem { title_len: 99, ..item };
        assert_eq!(items(&[past_end], strings).err(), Some(SlickStatus::InvalidArgument));
        let bad_utf8 = SlickItem {
            title_start: 18,
            title_len: 1,
            ..item
        };
        assert_eq!(items(&[bad_utf8], strings).err(), Some(SlickStatus::InvalidUtf8));
        assert_eq!(bytes(std::ptr::null(), 3).err(), Some(SlickStatus::NullPointer));
        assert_eq!(bytes(std::ptr::null(), 0), Ok(&[][..]));
    }
}
