//! Highlight ranges for visible rows, as UTF-16 ranges into the original text (what `NSRange` and
//! `NSAttributedString` want). Computing them for every match would cost several times the search,
//! so callers ask only for the rows on screen.

use crate::arena::Arena;
use crate::query::Query;
use crate::score;
use crate::search::decode_window;

/// Reusable buffers for [`ranges`].
#[derive(Default)]
pub struct HighlightScratch {
    pos: Vec<u32>,
    chars: Vec<char>,
}

/// Writes the matched UTF-16 ranges `(start, length)` of entry `e` into `out`, merged and sorted.
///
/// `orig` must be the original (unfolded) text the entry was built from. The strict match is
/// highlighted; when there is none, the typo match is. An entry that does not match leaves `out`
/// empty.
pub fn ranges(a: &Arena, e: usize, q: &Query, orig: &str, scratch: &mut HighlightScratch, out: &mut Vec<(u32, u32)>) {
    out.clear();
    let HighlightScratch { pos, chars } = scratch;
    pos.clear();
    if q.is_empty() || e >= a.entries() {
        return;
    }
    let w = a.window(e);
    let ws = a.ws[e];
    // Positions as char indices into the window.
    if q.ascii {
        let nd = q.needle();
        if score::score::<u8, true>(&nd, w, ws, false, Some(pos)).is_none() {
            pos.clear();
            if score::score::<u8, true>(&nd, w, ws, true, Some(pos)).is_none() {
                return;
            }
        }
        if !a.one_to_one(e) {
            pos.sort_unstable();
            pos.dedup();
            bytes_to_char_indices(w, pos);
        }
    } else {
        if a.one_to_one(e) {
            return;
        }
        let cws = decode_window(w, ws, chars);
        let nd = q.needle_chars();
        if score::score::<char, true>(&nd, chars, cws, false, Some(pos)).is_none() {
            pos.clear();
            if score::score::<char, true>(&nd, chars, cws, true, Some(pos)).is_none() {
                return;
            }
        }
    }
    pos.sort_unstable();
    pos.dedup();
    // Folding maps one char to one char, so char i of the folded entry is char i of `orig`.
    let win_chars = char_count(&a.item(e)[..a.win[e] as usize]) as u32;
    let mut next = 0;
    let mut utf16 = 0u32;
    for (ci, c) in orig.chars().enumerate() {
        if next == pos.len() {
            break;
        }
        let units = c.len_utf16() as u32;
        if pos[next] + win_chars == ci as u32 {
            match out.last_mut() {
                Some((start, len)) if *start + *len == utf16 => *len += units,
                _ => out.push((utf16, units)),
            }
            next += 1;
        }
        utf16 += units;
    }
}

/// Converts sorted byte offsets of char starts in `w` into char indices, in place.
fn bytes_to_char_indices(w: &[u8], pos: &mut [u32]) {
    let mut next = 0;
    let mut ci = 0u32;
    for (bi, &b) in w.iter().enumerate() {
        if b & 0xC0 == 0x80 {
            continue;
        }
        while next < pos.len() && pos[next] as usize <= bi {
            if pos[next] as usize == bi {
                pos[next] = ci;
            }
            next += 1;
        }
        ci += 1;
    }
}

fn char_count(bytes: &[u8]) -> usize {
    bytes.iter().filter(|&&b| b & 0xC0 != 0x80).count()
}
