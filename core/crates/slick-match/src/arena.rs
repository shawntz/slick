//! The flat structure-of-arrays store that queries scan.
//!
//! An arena holds items. Each item has one or more entries (match strings): a title, then any
//! aliases and keywords. Entries are stored folded (lowercase, diacritics stripped, one char to
//! one char) back to back in one byte buffer, with per-entry presence masks, word-initial masks and
//! word-start bitmaps. For file paths the scored window of an entry is its basename and the full
//! path is a fallback.

use crate::fold::{self, fold_str, mask_bit};
use crate::rank::Field;
use std::ops::Range;

/// Zero bytes kept after the last entry so SIMD loads of up to 64 bytes never leave the buffer.
pub const PAD: usize = 64;

/// Entry flag: folding was not one ASCII byte per char (CJK, emoji, some symbols).
pub(crate) const FLAG_MULTIBYTE: u8 = 1;
const FIELD_SHIFT: u8 = 1;

/// Flat SoA arena of items and their entries.
#[derive(Default)]
pub struct Arena {
    /// Folded bytes of every entry back to back, then `PAD` zero bytes.
    pub text: Vec<u8>,
    /// Per entry: offset into `text`.
    pub start: Vec<u32>,
    /// Per entry: folded length in bytes (entries are truncated at 65,535).
    pub len: Vec<u16>,
    /// Per entry: byte offset of the scored window (the basename for paths, 0 otherwise).
    pub win: Vec<u16>,
    /// Per entry: presence mask of the scored window.
    pub mask: Vec<u64>,
    /// Per entry: presence mask of the whole text (paths only).
    pub pmask: Vec<u64>,
    /// Per entry: presence mask of word-initial chars (typo prefilter).
    pub initials: Vec<u64>,
    /// Per entry: presence mask of chars that start two words or more.
    pub initials2: Vec<u64>,
    /// Per entry: word-start bits for window bytes 0..64.
    pub ws: Vec<u64>,
    /// Per entry: the first byte of the window, 0 when it is empty. An exact or literal prefix
    /// match needs the query to start with it.
    pub head: Vec<u8>,
    /// Per entry: the byte at the first word start of the window, 0 when it has none. A complete
    /// word cover needs the query to start with it.
    pub lead: Vec<u8>,
    /// Per entry: the first bytes of the first eight words of the window, word j in byte j, 0 past
    /// the last word. The index of the first word a query's first char starts bounds the
    /// word-prefix quality.
    pub heads: Vec<u64>,
    /// Per entry: a 64-bit Bloom mask of the adjacent byte pairs of the window (see [`pair_bit`]).
    /// A substring match needs every pair of the query in it.
    pub pairs: Vec<u64>,
    /// Per entry: bit 0 multibyte, bits 1..3 the field.
    pub flags: Vec<u8>,
    /// Per item: index of its first entry, plus one final element (entries of item `i` are
    /// `first[i]..first[i + 1]`).
    first: Vec<u32>,
    /// True for path arenas.
    pub paths: bool,
    padded: bool,
}

impl Arena {
    /// An empty arena for titles (`paths` false) or file paths.
    pub fn new(paths: bool) -> Self {
        Arena {
            paths,
            first: vec![0],
            ..Arena::default()
        }
    }

    /// One title entry per item.
    pub fn from_titles<'a>(items: impl IntoIterator<Item = &'a str>) -> Self {
        let mut a = Arena::new(false);
        for s in items {
            a.push(s);
        }
        a.shrink();
        a
    }

    /// One path entry per item. The basename is scored first; see `Opts::path_fallback`.
    pub fn from_paths<'a>(items: impl IntoIterator<Item = &'a str>) -> Self {
        let mut a = Arena::new(true);
        for s in items {
            a.push(s);
        }
        a.shrink();
        a
    }

    /// Releases spare capacity after a bulk build.
    pub fn shrink(&mut self) {
        self.text.shrink_to_fit();
        self.start.shrink_to_fit();
        self.len.shrink_to_fit();
        self.win.shrink_to_fit();
        self.mask.shrink_to_fit();
        self.pmask.shrink_to_fit();
        self.initials.shrink_to_fit();
        self.initials2.shrink_to_fit();
        self.ws.shrink_to_fit();
        self.head.shrink_to_fit();
        self.lead.shrink_to_fit();
        self.heads.shrink_to_fit();
        self.pairs.shrink_to_fit();
        self.flags.shrink_to_fit();
        self.first.shrink_to_fit();
    }

    /// Adds an item with one entry: a title, or a path in a path arena.
    pub fn push(&mut self, s: &str) {
        self.ensure_first();
        self.push_entry(s, Field::Title);
        self.close_item();
    }

    /// Adds an item with a title plus any aliases and keywords. Empty strings are skipped, except
    /// the title, which is always the item's first entry.
    pub fn push_item<'a>(
        &mut self,
        title: &str,
        aliases: impl IntoIterator<Item = &'a str>,
        keywords: impl IntoIterator<Item = &'a str>,
    ) {
        self.ensure_first();
        self.push_entry(title, Field::Title);
        for a in aliases {
            if !a.trim().is_empty() {
                self.push_entry(a, Field::Alias);
            }
        }
        for k in keywords {
            if !k.trim().is_empty() {
                self.push_entry(k, Field::Keyword);
            }
        }
        self.close_item();
    }

    fn ensure_first(&mut self) {
        if self.first.is_empty() {
            self.first.push(0);
        }
    }

    fn close_item(&mut self) {
        self.first.push(self.start.len() as u32);
    }

    fn push_entry(&mut self, s: &str, field: Field) {
        let window_char = if self.paths {
            let trimmed = s.trim_end_matches('/');
            match trimmed.rfind('/') {
                Some(p) => trimmed[..p + 1].chars().count(),
                None => 0,
            }
        } else {
            0
        };
        let (f, win_byte) = fold_str(s, window_char);
        let mut bytes = f.bytes;
        truncate_on_char_boundary(&mut bytes, u16::MAX as usize);
        if self.padded {
            self.text.truncate(self.text.len() - PAD);
            self.padded = false;
        }
        let win_byte = win_byte.min(bytes.len());
        self.start.push(self.text.len() as u32);
        self.text.extend_from_slice(&bytes);
        self.len.push(bytes.len() as u16);
        self.win.push(win_byte as u16);
        if self.paths {
            let base = &bytes[win_byte..];
            let mut m = 0u64;
            if f.one_to_one {
                for &b in base {
                    m |= fold::mask_bit_byte(b);
                }
            } else {
                for c in String::from_utf8_lossy(base).chars() {
                    m |= mask_bit(c);
                }
            }
            self.mask.push(m);
            self.pmask.push(f.mask);
        } else {
            self.mask.push(f.mask);
        }
        self.initials.push(f.initials);
        self.initials2.push(f.initials2);
        self.ws.push(f.ws);
        let window = &bytes[win_byte..];
        self.head.push(window.first().copied().unwrap_or(0));
        let heads = word_heads(window, f.ws);
        self.lead.push(heads as u8);
        self.heads.push(heads);
        self.pairs.push(pair_mask(window));
        let multibyte = if f.one_to_one { 0 } else { FLAG_MULTIBYTE };
        self.flags.push(multibyte | ((field as u8) << FIELD_SHIFT));
        self.text.extend_from_slice(&[0u8; PAD]);
        self.padded = true;
    }

    /// Number of items.
    #[inline(always)]
    pub fn len(&self) -> usize {
        self.first.len().saturating_sub(1)
    }

    /// True when the arena holds no items.
    #[inline(always)]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Number of entries across all items.
    #[inline(always)]
    pub fn entries(&self) -> usize {
        self.start.len()
    }

    /// The entries of item `i`.
    #[inline(always)]
    pub fn entry_range(&self, i: usize) -> Range<usize> {
        self.first[i] as usize..self.first[i + 1] as usize
    }

    /// Which match string entry `e` is.
    #[inline(always)]
    pub fn field(&self, e: usize) -> Field {
        Field::from_bits(self.flags[e] >> FIELD_SHIFT)
    }

    /// The first entry of item `i` with this field, if any.
    pub fn entry_of(&self, i: usize, field: Field) -> Option<usize> {
        self.entry_range(i).find(|&e| self.field(e) == field)
    }

    /// Folded bytes of entry `e`.
    #[inline(always)]
    pub fn item(&self, e: usize) -> &[u8] {
        let s = self.start[e] as usize;
        &self.text[s..s + self.len[e] as usize]
    }

    /// Folded bytes of the scored window of entry `e`.
    #[inline(always)]
    pub fn window(&self, e: usize) -> &[u8] {
        let s = self.start[e] as usize;
        &self.text[s + self.win[e] as usize..s + self.len[e] as usize]
    }

    /// True when entry `e` folded to one ASCII byte per char.
    #[inline(always)]
    pub fn one_to_one(&self, e: usize) -> bool {
        self.flags[e] & FLAG_MULTIBYTE == 0
    }

    /// Bytes held by the arena (capacity), for memory reports.
    pub fn heap_bytes(&self) -> usize {
        self.text.capacity()
            + self.start.capacity() * 4
            + self.len.capacity() * 2
            + self.win.capacity() * 2
            + self.mask.capacity() * 8
            + self.pmask.capacity() * 8
            + self.initials.capacity() * 8
            + self.initials2.capacity() * 8
            + self.ws.capacity() * 8
            + self.head.capacity()
            + self.lead.capacity()
            + self.heads.capacity() * 8
            + self.pairs.capacity() * 8
            + self.flags.capacity()
            + self.first.capacity() * 4
    }
}

/// The Bloom bit of the adjacent byte pair `(a, b)`.
#[inline(always)]
pub fn pair_bit(a: u8, b: u8) -> u64 {
    let h = (a as u32).wrapping_mul(0x9E37_79B1) ^ (b as u32).wrapping_mul(0x85EB_CA77);
    1u64 << (h >> 26)
}

/// The Bloom mask of the adjacent byte pairs of `s`. Pairs with a space are left out: a query
/// token never holds one.
pub fn pair_mask(s: &[u8]) -> u64 {
    s.windows(2)
        .filter(|p| p[0] != b' ' && p[1] != b' ')
        .fold(0, |m, p| m | pair_bit(p[0], p[1]))
}

/// The first bytes of the first eight words of a window, word j in byte j, as the scorer sees
/// the words: the bits of `ws` inside the window, then each separator-to-non-separator step after
/// byte 64.
fn word_heads(s: &[u8], ws: u64) -> u64 {
    use crate::score::Unit;
    let n = s.len();
    let mut bits = if n >= 64 { ws } else { ws & ((1u64 << n) - 1) };
    let mut heads = 0u64;
    let mut j = 0;
    while bits != 0 && j < 8 {
        heads |= (s[bits.trailing_zeros() as usize] as u64) << (8 * j);
        bits &= bits - 1;
        j += 1;
    }
    let mut i = 64;
    while i < n && j < 8 {
        if s[i - 1].is_sep() && !s[i].is_sep() {
            heads |= (s[i] as u64) << (8 * j);
            j += 1;
        }
        i += 1;
    }
    heads
}

/// Truncates UTF-8 bytes to at most `max` without splitting a char.
fn truncate_on_char_boundary(bytes: &mut Vec<u8>, max: usize) {
    if bytes.len() <= max {
        return;
    }
    let mut end = max;
    while end > 0 && (bytes[end] & 0xC0) == 0x80 {
        end -= 1;
    }
    bytes.truncate(end);
}
