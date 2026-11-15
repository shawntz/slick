//! A folded query, reusable across keystrokes without allocating.

use crate::arena::pair_bit;
use crate::bits::BitNeedle;
use crate::fold::{self, mask_bit};
use crate::score::Needle;

/// Longest query considered, in chars. Longer input is truncated.
pub const MAX_QUERY_CHARS: usize = 256;
/// How many chars after the first the word-prefix bound checks.
pub const LINKS: usize = 8;

/// A query folded the same way as arena entries: lowercase, diacritics stripped, whitespace
/// collapsed to single spaces and trimmed.
///
/// [`Query::set`] refills it in place, so a query kept for a panel's lifetime stops allocating
/// once its buffers have grown to the longest query typed.
#[derive(Debug, Default)]
pub struct Query {
    /// Folded, single spaces between tokens.
    pub full: Vec<u8>,
    /// Folded, without spaces.
    pub ns: Vec<u8>,
    /// Token ranges into `full` (empty for non-ASCII queries, which use the char ranges).
    pub tokens: Vec<(u16, u16)>,
    /// Presence mask of every char.
    pub mask: u64,
    /// Mask bits of the first two chars (typo prefilter).
    pub typo_bits: u64,
    /// True when the folded query is ASCII (the byte paths apply).
    pub ascii: bool,
    /// Bit-path precomputation.
    pub bn: BitNeedle,
    /// True for an ASCII query of one token: the scan may then skip entries by an upper bound on
    /// their rank (see `search`).
    pub bounded: bool,
    /// The mask bit of the first char (zero when absent), for the bound.
    pub bit0: u64,
    /// The Bloom mask of every adjacent pair of `full`.
    pub pairs: u64,
    /// For chars 1..=LINKS of a bounded query: the mask bit of the char, to test whether it can
    /// start a word.
    pub link_bits: [u64; LINKS],
    /// The Bloom bit of the pair it forms with the char before it, to test whether it can follow
    /// that char.
    pub link_pairs: [u64; LINKS],
    /// Bit j set when char j + 1 equals the first char, so starting a word with it needs a second
    /// word with that initial.
    pub link_same: u8,
    /// How many of the arrays above are in use.
    pub links: u8,
    full_c: Vec<char>,
    ns_c: Vec<char>,
    tokens_c: Vec<(u16, u16)>,
}

impl Query {
    /// Folds `raw` into a new query.
    pub fn new(raw: &str) -> Self {
        let mut q = Query::default();
        q.set(raw);
        q
    }

    /// Refolds this query from `raw`, reusing every buffer.
    pub fn set(&mut self, raw: &str) {
        self.full_c.clear();
        for c in raw.chars().take(MAX_QUERY_CHARS) {
            let f = if c.is_whitespace() { ' ' } else { fold::fold_char(c) };
            if f == ' ' && self.full_c.last().is_none_or(|&last| last == ' ') {
                continue;
            }
            self.full_c.push(f);
        }
        while self.full_c.last() == Some(&' ') {
            self.full_c.pop();
        }
        self.ns_c.clear();
        self.ns_c.extend(self.full_c.iter().copied().filter(|&c| c != ' '));
        self.tokens_c.clear();
        let mut st = 0usize;
        for (i, &c) in self.full_c.iter().enumerate() {
            if c == ' ' {
                self.tokens_c.push((st as u16, i as u16));
                st = i + 1;
            }
        }
        if st < self.full_c.len() {
            self.tokens_c.push((st as u16, self.full_c.len() as u16));
        }
        self.mask = self.ns_c.iter().fold(0u64, |m, &c| m | mask_bit(c));
        self.ascii = self.full_c.iter().all(|c| c.is_ascii());
        self.full.clear();
        self.ns.clear();
        self.tokens.clear();
        let mut buf = [0u8; 4];
        for &c in &self.full_c {
            self.full.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
        for &c in &self.ns_c {
            self.ns.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
        if self.ascii {
            self.tokens.extend_from_slice(&self.tokens_c);
        }
        let bit = |c: Option<&char>| c.map(|&c| mask_bit(c)).unwrap_or(0);
        self.typo_bits = bit(self.ns_c.first()) | bit(self.ns_c.get(1));
        self.bn.set(&self.full, &self.ns, self.ascii);
        self.bounded = self.ascii && self.tokens.len() == 1 && self.full == self.ns;
        let byte = |i: usize| self.full.get(i).copied();
        self.bit0 = byte(0).map_or(0, fold::mask_bit_byte);
        self.pairs = crate::arena::pair_mask(&self.full);
        self.links = 0;
        self.link_same = 0;
        if self.bounded {
            for (j, w) in self.full.windows(2).take(LINKS).enumerate() {
                self.link_bits[j] = fold::mask_bit_byte(w[1]);
                self.link_pairs[j] = pair_bit(w[0], w[1]);
                self.link_same |= ((w[1] == self.full[0]) as u8) << j;
                self.links += 1;
            }
        }
    }

    /// Copies `other` into `self`, reusing capacity.
    pub fn copy_from(&mut self, other: &Query) {
        copy_vec(&mut self.full, &other.full);
        copy_vec(&mut self.ns, &other.ns);
        copy_vec(&mut self.tokens, &other.tokens);
        copy_vec(&mut self.full_c, &other.full_c);
        copy_vec(&mut self.ns_c, &other.ns_c);
        copy_vec(&mut self.tokens_c, &other.tokens_c);
        self.mask = other.mask;
        self.typo_bits = other.typo_bits;
        self.ascii = other.ascii;
        self.bn.copy_from(&other.bn);
        self.bounded = other.bounded;
        self.bit0 = other.bit0;
        self.pairs = other.pairs;
        self.link_bits = other.link_bits;
        self.link_pairs = other.link_pairs;
        self.link_same = other.link_same;
        self.links = other.links;
    }

    /// True when the query has no searchable chars.
    pub fn is_empty(&self) -> bool {
        self.ns_c.is_empty()
    }

    /// Length in chars, without spaces.
    pub fn len_chars(&self) -> usize {
        self.ns_c.len()
    }

    /// The folded query as chars, single spaces between tokens.
    pub fn chars(&self) -> &[char] {
        &self.full_c
    }

    /// True when `self` can only match a subset of what `prev` matched: it extends `prev`.
    pub fn narrows(&self, prev: &Query) -> bool {
        !prev.is_empty() && self.full.starts_with(&prev.full)
    }

    /// The byte needle for ASCII queries.
    #[inline(always)]
    pub fn needle(&self) -> Needle<'_, u8> {
        Needle {
            full: &self.full,
            ns: &self.ns,
            tokens: &self.tokens,
        }
    }

    /// The char needle for non-ASCII queries.
    #[inline(always)]
    pub fn needle_chars(&self) -> Needle<'_, char> {
        Needle {
            full: &self.full_c,
            ns: &self.ns_c,
            tokens: &self.tokens_c,
        }
    }
}

fn copy_vec<T: Copy>(dst: &mut Vec<T>, src: &[T]) {
    dst.clear();
    dst.extend_from_slice(src);
}

impl Clone for Query {
    fn clone(&self) -> Self {
        let mut q = Query::default();
        q.copy_from(self);
        q
    }
}
