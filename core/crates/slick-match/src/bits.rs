//! Bit-parallel fast path for ASCII needles over windows of at most 64 bytes (every root title and
//! almost every basename). For each distinct needle char, NEON builds a 64-bit "where does this
//! char occur" bitmap 16 bytes per compare. The gate, exact, prefix, substring and word-initial
//! checks then take a handful of shifts and ANDs. Word segmentation and subsequence scoring reuse
//! the scalar reference code. Results equal `score::score` (tested), except that items that cannot
//! reach `floor` or the rank bound return `Sc::Below` without being fully classified.

use crate::Unit;
use crate::score::{
    self, EXACT, Needle, PREFIX, SUBSEQUENCE, SUBSTRING, TextScore, UNORDERED, WORD_PREFIX, substring_quality,
    unordered_quality,
};

/// Longest needle the bit path handles. Longer queries take the scalar path.
pub const MAX_NEEDLE: usize = 32;

/// Per-query precomputation for the bit path.
#[derive(Clone, Debug, Default)]
pub struct BitNeedle {
    /// Distinct bytes of the needle; each gets one occurrence bitmap.
    pub distinct: Vec<u8>,
    /// Slot (index into `distinct`) of every byte of `full`.
    pub full_slot: Vec<u8>,
    /// Slot of every byte of `ns`.
    pub ns_slot: Vec<u8>,
    /// False when the bit path cannot handle this needle.
    pub ok: bool,
}

impl BitNeedle {
    /// Rebuilds the precomputation in place, reusing the vectors' capacity.
    pub fn set(&mut self, full: &[u8], ns: &[u8], ascii: bool) {
        self.distinct.clear();
        self.full_slot.clear();
        self.ns_slot.clear();
        self.ok = ascii && !full.is_empty() && full.len() <= MAX_NEEDLE;
        if !self.ok {
            return;
        }
        for &c in full {
            let slot = slot_of(&mut self.distinct, c);
            self.full_slot.push(slot);
        }
        for &c in ns {
            let slot = slot_of(&mut self.distinct, c);
            self.ns_slot.push(slot);
        }
    }

    /// Copies `other` into `self`, reusing capacity.
    pub fn copy_from(&mut self, other: &BitNeedle) {
        self.distinct.clear();
        self.distinct.extend_from_slice(&other.distinct);
        self.full_slot.clear();
        self.full_slot.extend_from_slice(&other.full_slot);
        self.ns_slot.clear();
        self.ns_slot.extend_from_slice(&other.ns_slot);
        self.ok = other.ok;
    }
}

fn slot_of(distinct: &mut Vec<u8>, c: u8) -> u8 {
    match distinct.iter().position(|&x| x == c) {
        Some(p) => p as u8,
        None => {
            distinct.push(c);
            (distinct.len() - 1) as u8
        }
    }
}

/// Rank bound for one entry: skip classification when even the best word-prefix match of this
/// entry cannot reach `thresh`.
#[derive(Clone, Copy, Debug)]
pub struct Bound {
    /// Rank of the current k-th best hit, or `i32::MIN` while the top k is still filling.
    pub thresh: i32,
    /// Rank of a quality-0 word-prefix match of this entry (see `rank::word_prefix_base`).
    pub word_prefix_base: i32,
}

impl Bound {
    /// No bound: classify every match.
    pub const NONE: Bound = Bound {
        thresh: i32::MIN,
        word_prefix_base: 0,
    };
}

/// Outcome of the bit path for one window.
pub enum Sc {
    /// Fails the strict gate.
    No,
    /// Passes the gate but cannot reach the floor or the bound.
    Below,
    /// A full classification.
    Yes(TextScore),
}

/// For each byte in `chars`, a bitmap of the positions in `block[..n]` that hold it. The loads
/// read whole 16-byte lanes of `block`, past `n` when `n` is not a multiple of 16; the mask drops
/// those bits.
///
/// Each compare gives 0xFF per equal byte; ANDed with the weights 1, 2, 4 ... 128, twice, a group
/// of eight bytes sums to its 8-bit mask. Pairwise adds sum several vectors at once: three of them
/// turn one to four vectors into the 16-bit to 64-bit masks of one to four chars, where a
/// horizontal add would take two per vector.
#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn bitmaps(block: &[u8; 64], n: usize, chars: &[u8], out: &mut [u64; MAX_NEEDLE]) {
    use std::arch::aarch64::*;
    let p = block.as_ptr();
    let d = chars.len();
    // Past the needle's distinct chars a zero byte stands in; its mask is never stored.
    let ch = |i: usize| chars.get(i).copied().unwrap_or(0);
    // SAFETY: `block` is 64 readable bytes, and the loads below read `p[0..16]`, `p[16..32]`,
    // `p[32..48]` and `p[48..64]` at most. NEON is part of the aarch64 baseline, and the other
    // intrinsics only touch registers.
    unsafe {
        const W: [u8; 16] = [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];
        let w = vld1q_u8(W.as_ptr());
        let lim = if n >= 64 { u64::MAX } else { (1u64 << n) - 1 };
        // Weighted equal bytes of `v` and `c`.
        let eq = |v: uint8x16_t, c: u8| vandq_u8(vceqq_u8(v, vdupq_n_u8(c)), w);
        // Straight-line code per width class: a variable-length vector array spills to memcpy.
        let v0 = vld1q_u8(p);
        if n <= 16 {
            // Four chars per round, 16 bits each.
            let mut k = 0;
            while k < d {
                let s = vpaddq_u8(
                    vpaddq_u8(eq(v0, ch(k)), eq(v0, ch(k + 1))),
                    vpaddq_u8(eq(v0, ch(k + 2)), eq(v0, ch(k + 3))),
                );
                let x = vgetq_lane_u64(vreinterpretq_u64_u8(vpaddq_u8(s, s)), 0);
                for (j, slot) in out[k..d.min(k + 4)].iter_mut().enumerate() {
                    *slot = (x >> (16 * j)) & 0xFFFF & lim;
                }
                k += 4;
            }
        } else if n <= 32 {
            // Two chars per round, 32 bits each.
            let v1 = vld1q_u8(p.add(16));
            let mut k = 0;
            while k < d {
                let s = vpaddq_u8(
                    vpaddq_u8(eq(v0, ch(k)), eq(v1, ch(k))),
                    vpaddq_u8(eq(v0, ch(k + 1)), eq(v1, ch(k + 1))),
                );
                let x = vgetq_lane_u64(vreinterpretq_u64_u8(vpaddq_u8(s, s)), 0);
                out[k] = x & 0xFFFF_FFFF & lim;
                if k + 1 < d {
                    out[k + 1] = (x >> 32) & lim;
                }
                k += 2;
            }
        } else {
            // Two chars per round, 64 bits each.
            let v1 = vld1q_u8(p.add(16));
            let v2 = vld1q_u8(p.add(32));
            let v3 = vld1q_u8(p.add(48));
            let quads = |c: u8| vpaddq_u8(vpaddq_u8(eq(v0, c), eq(v1, c)), vpaddq_u8(eq(v2, c), eq(v3, c)));
            let mut k = 0;
            while k < d {
                let s = vreinterpretq_u64_u8(vpaddq_u8(quads(ch(k)), quads(ch(k + 1))));
                out[k] = vgetq_lane_u64(s, 0) & lim;
                if k + 1 < d {
                    out[k + 1] = vgetq_lane_u64(s, 1) & lim;
                }
                k += 2;
            }
        }
    }
}

/// Portable fallback for [`bitmaps`] on targets without NEON.
#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
fn bitmaps(block: &[u8; 64], n: usize, chars: &[u8], out: &mut [u64; MAX_NEEDLE]) {
    let s = &block[..n];
    for (d, &c) in chars.iter().enumerate() {
        let mut m = 0u64;
        for (i, &b) in s.iter().enumerate() {
            m |= ((b == c) as u64) << i;
        }
        out[d] = m;
    }
}

/// Bits strictly above position `p` (p may be -1).
#[inline(always)]
fn above(p: i32) -> u64 {
    if p < 0 {
        u64::MAX
    } else if p >= 63 {
        0
    } else {
        !((2u64 << p) - 1)
    }
}

#[inline(always)]
fn subseq_bits(bm: &[u64; MAX_NEEDLE], slots: &[u8]) -> bool {
    let mut pos = -1i32;
    for &sl in slots {
        let c = bm[sl as usize] & above(pos);
        if c == 0 {
            return false;
        }
        pos = c.trailing_zeros() as i32;
    }
    true
}

/// Positions p where the needle (given by slots) occurs contiguously starting at p.
#[inline(always)]
fn occurrences(bm: &[u64; MAX_NEEDLE], slots: &[u8], n: usize) -> u64 {
    let l = slots.len();
    if l > n {
        return 0;
    }
    let mut r = bm[slots[0] as usize];
    for (k, &sl) in slots.iter().enumerate().skip(1) {
        r &= bm[sl as usize] >> k;
    }
    let room = n - l + 1;
    if room >= 64 { r } else { r & ((1u64 << room) - 1) }
}

#[inline(always)]
fn below(t: u8, floor: u8, s: TextScore) -> Sc {
    if t < floor { Sc::Below } else { Sc::Yes(s) }
}

/// Scores the window `block[..n]` (`n` at most 64) against an ASCII needle with bitmap
/// operations. Returns the same tier and quality as `score::score`, or `Sc::Below` for a match
/// that cannot reach `floor` or the `bound`.
///
/// `block` is the 64 bytes that start at the window: the arena keeps `PAD` zero bytes after its
/// last entry, so they exist for every window. Taking them as an array lets the NEON loads read
/// whole lanes without trusting the caller.
#[inline]
pub fn score_bits(
    nd: &Needle<'_, u8>,
    bn: &BitNeedle,
    block: &[u8; 64],
    n: usize,
    ws: u64,
    floor: u8,
    bound: Bound,
) -> Sc {
    let s = &block[..n];
    let q = nd.ns;
    let m = q.len();
    let mut bm = [0u64; MAX_NEEDLE];
    bitmaps(block, n, &bn.distinct, &mut bm);
    let ws = if n >= 64 { ws } else { ws & ((1u64 << n) - 1) };

    // ---- single char
    if m == 1 && nd.tokens.len() <= 1 {
        let b = bm[bn.ns_slot[0] as usize];
        if b == 0 {
            return Sc::No;
        }
        let p = b.trailing_zeros() as i32;
        if p == 0 {
            if n == 1 {
                return Sc::Yes(TextScore::new(EXACT, 999));
            }
            let ends_mid = !(s[1].is_sep() || (ws >> 1) & 1 == 1);
            let all = (ws >> 1) == 0;
            return below(
                PREFIX,
                floor,
                TextScore::new(PREFIX, score::prefix_quality(n, 1, ends_mid, all, false)),
            );
        }
        let extra = ((n - 1) as i32).min(60);
        let hit = b & ws;
        if hit != 0 {
            let pos = hit.trailing_zeros() as usize;
            let j = (ws & ((1u64 << pos) - 1)).count_ones() as i32;
            let complete = pos + 1 >= n || s[pos + 1].is_sep() || (ws >> (pos + 1)) & 1 == 1;
            let adj = if complete { 40 } else { 0 };
            return below(
                WORD_PREFIX,
                floor,
                TextScore::new(
                    WORD_PREFIX,
                    score::word_prefix_quality(j.min(255) as u8, 0, 1, extra, adj),
                ),
            );
        }
        return below(SUBSTRING, floor, TextScore::new(SUBSTRING, substring_quality(p, extra)));
    }

    // ---- gate
    let gate = if nd.tokens.len() <= 1 {
        subseq_bits(&bm, &bn.ns_slot)
    } else {
        nd.tokens
            .iter()
            .all(|&(a, b)| subseq_bits(&bm, &bn.full_slot[a as usize..b as usize]))
    };
    if !gate {
        return Sc::No;
    }
    let full = nd.full;
    let fm = full.len();
    // ---- exact / prefix
    if fm <= n && occurrences(&bm, &bn.full_slot, n) & 1 == 1 {
        if n == fm {
            return Sc::Yes(TextScore::new(EXACT, 999));
        }
        let ends_mid = !(s[fm].is_sep() || (ws >> fm) & 1 == 1);
        let all = fm >= 64 || (ws >> fm) == 0;
        return below(
            PREFIX,
            floor,
            TextScore::new(PREFIX, score::prefix_quality(n, fm, ends_mid, all, false)),
        );
    }
    if floor > PREFIX {
        return Sc::Below;
    }
    let extra = (n as i32 - m as i32).max(0);
    let first_at_word = bm[bn.ns_slot[0] as usize] & ws != 0;
    let word_count = ws.count_ones() as usize;
    // ---- a one-token query equal to a whole later word ranks with literal prefixes ("code")
    let whole = if first_at_word && nd.promotes_whole_words() {
        whole_word(&bm, bn, s, ws, n)
    } else {
        None
    };
    if let Some(word) = whole {
        let quality = score::whole_word_quality(n, fm, word);
        // A complete cover may score higher. It needs the first word to start with q[0] and at
        // most m words.
        let first_hit = (bm[bn.ns_slot[0] as usize] & ws).trailing_zeros();
        let cover_possible = ws & below_bits(first_hit as usize) == 0 && word_count.min(32) <= m;
        let cover = if !cover_possible {
            None
        } else if m == 2 {
            segment2(bm[bn.ns_slot[0] as usize], bm[bn.ns_slot[1] as usize], s, ws)
        } else {
            let mut words = [0u16; 32];
            let nw = word_starts(ws, &mut words);
            score::segment_info(q, s, ws, &words[..nw])
        }
        .filter(|sg| sg.covers_all)
        .map(|sg| score::prefix_quality(n, fm, sg.ends_mid, true, true));
        let best = cover.map_or(quality, |c| c.max(quality));
        return below(PREFIX, floor, TextScore::new(PREFIX, best));
    }
    // ---- word-prefix segmentation
    if first_at_word && floor >= WORD_PREFIX && bound.thresh != i32::MIN {
        // Quality-aware bound: segmentation can only start at or after the first word whose
        // initial is q[0]. A complete cover (PREFIX tier) needs that to be word 0 and at most m words.
        let first_hit = (bm[bn.ns_slot[0] as usize] & ws).trailing_zeros();
        let fw_min = (ws & ((1u64 << first_hit) - 1)).count_ones() as i32;
        let cover_possible = fw_min == 0 && word_count.min(32) <= m;
        if !cover_possible && bound.word_prefix_base + 940 - 40 * fw_min.min(5) - 3 * extra.min(60) < bound.thresh {
            return Sc::Below;
        }
    }
    let mut words = [0u16; 32];
    let mut nw = 0;
    if (first_at_word && !(m == 2 && nd.tokens.len() <= 1 && word_count <= 32)) || nd.tokens.len() >= 2 {
        nw = word_starts(ws, &mut words);
    }
    let words = &words[..nw];
    let seg = if !first_at_word {
        None
    } else if m == 2 && nd.tokens.len() <= 1 && word_count <= 32 {
        segment2(bm[bn.ns_slot[0] as usize], bm[bn.ns_slot[1] as usize], s, ws)
    } else {
        score::segment_info(q, s, ws, words)
    };
    if let Some(sg) = seg {
        if sg.covers_all && m >= 2 {
            return below(
                PREFIX,
                floor,
                TextScore::new(PREFIX, score::prefix_quality(n, fm, sg.ends_mid, true, true)),
            );
        }
        let qq = score::word_prefix_quality(sg.first_word, sg.skipped, sg.segments, extra, sg.adj);
        return below(WORD_PREFIX, floor, TextScore::new(WORD_PREFIX, qq));
    }
    if floor > UNORDERED {
        return Sc::Below;
    }
    // ---- unordered tokens
    if nd.tokens.len() >= 2
        && first_at_word_all(&bm, bn, nd, ws)
        && let Some(worst) = score::unordered_pub(nd, s, words)
    {
        return below(
            UNORDERED,
            floor,
            TextScore::new(UNORDERED, unordered_quality(worst, extra)),
        );
    }
    if floor > SUBSTRING {
        return Sc::Below;
    }
    // ---- substring
    let mut occ = occurrences(&bm, &bn.full_slot, n);
    if occ == 0 && fm != m {
        occ = occurrences(&bm, &bn.ns_slot, n);
    }
    if occ != 0 {
        let p = occ.trailing_zeros() as i32;
        return below(SUBSTRING, floor, TextScore::new(SUBSTRING, substring_quality(p, extra)));
    }
    if floor > SUBSEQUENCE {
        return Sc::Below;
    }
    let quality = if nd.tokens.len() <= 1 {
        subsequence_bits(&bm, &bn.ns_slot, ws, n)
    } else {
        let mut worst = Some(999);
        for &(a, b) in nd.tokens {
            let t = subsequence_bits(&bm, &bn.full_slot[a as usize..b as usize], ws, n);
            worst = worst.zip(t).map(|(w, t)| w.min(t));
        }
        worst.map(|w| w - 100)
    };
    match quality {
        Some(qq) => below(SUBSEQUENCE, floor, TextScore::new(SUBSEQUENCE, qq)),
        None => Sc::No,
    }
}

/// The fzf-v1 subsequence quality of `score::subsequence_tail` from occurrence bitmaps: forward
/// to the first complete match, backward to the tightest start, then forward greedily inside
/// that window, counting word-start hits, adjacent pairs and gaps.
#[inline(always)]
fn subsequence_bits(bm: &[u64; MAX_NEEDLE], slots: &[u8], ws: u64, n: usize) -> Option<i32> {
    let m = slots.len();
    if m == 0 || m > n {
        return None;
    }
    let mut pos = -1i32;
    for &sl in slots {
        let c = bm[sl as usize] & above(pos);
        if c == 0 {
            return None;
        }
        pos = c.trailing_zeros() as i32;
    }
    let end = pos as usize;
    let mut start = end;
    for &sl in slots[..m - 1].iter().rev() {
        let c = bm[sl as usize] & below_bits(start);
        if c == 0 {
            return None;
        }
        start = 63 - c.leading_zeros() as usize;
    }
    let (mut hits, mut consec) = (0, 0);
    let mut prev = start as i32 - 1;
    for &sl in slots {
        let p = (bm[sl as usize] & above(prev)).trailing_zeros() as i32;
        hits += ((ws >> p) & 1) as i32;
        consec += (p == prev + 1 && p != start as i32) as i32;
        prev = p;
    }
    let gaps = (end + 1 - start - m) as i32;
    Some(500 + 25 * hits + 15 * consec - 4 * gaps.min(50) - 3 * (start as i32).min(30) - 2 * ((n - m) as i32).min(60))
}

/// The positions of the first 32 word starts in `ws`, lowest first. Returns how many.
#[inline(always)]
fn word_starts(ws: u64, out: &mut [u16; 32]) -> usize {
    let mut b = ws;
    let mut nw = 0;
    while b != 0 && nw < 32 {
        out[nw] = b.trailing_zeros() as u16;
        nw += 1;
        b &= b - 1;
    }
    nw
}

/// The first word of the window that equals the needle, as its word index: the needle occurs at
/// a word start, and a word ends where it ends, at a separator, a word start or the window's end.
/// Like the scalar scorer, it looks at the first 32 words only.
#[inline(always)]
fn whole_word(bm: &[u64; MAX_NEEDLE], bn: &BitNeedle, s: &[u8], ws: u64, n: usize) -> Option<usize> {
    let m = bn.ns_slot.len();
    let mut starts = occurrences(bm, &bn.ns_slot, n) & ws;
    while starts != 0 {
        let p = starts.trailing_zeros() as usize;
        let word = (ws & below_bits(p)).count_ones() as usize;
        if word >= 32 {
            return None;
        }
        let e = p + m;
        if e >= n || s[e].is_sep() || (ws >> e) & 1 == 1 {
            return Some(word);
        }
        starts &= starts - 1;
    }
    None
}

/// Bits below position `p` (p may be 64).
#[inline(always)]
fn below_bits(p: usize) -> u64 {
    if p >= 64 { u64::MAX } else { (1u64 << p) - 1 }
}

/// The word-prefix segmentation of a 2-char needle from its occurrence bitmaps: the same result
/// as `score::segment_info`, which for two chars reduces to "the first word starting with q[0]
/// that either continues with q[1] or has a later word starting with q[1]".
#[inline(always)]
fn segment2(b0: u64, b1: u64, s: &[u8], ws: u64) -> Option<score::Seg> {
    let n = s.len();
    let starts = b0 & ws;
    let runs = starts & (b1 >> 1);
    let seconds = b1 & ws;
    let word_count = ws.count_ones();
    let words_below = |p: usize| (ws & below_bits(p)).count_ones();
    let word_end = |e: usize| e >= n || s[e].is_sep() || (e < 64 && (ws >> e) & 1 == 1);
    let hump = |p: usize| p > 0 && !s[p - 1].is_sep();
    let mut cands = starts;
    while cands != 0 {
        let p0 = cands.trailing_zeros() as usize;
        let first_word = words_below(p0);
        if (runs >> p0) & 1 == 1 {
            let end = p0 + 2;
            let last = words_below(end) - 1;
            let complete = word_end(end);
            return Some(score::Seg {
                end,
                first_word: first_word as u8,
                skipped: 0,
                segments: 1,
                covers_all: first_word == 0 && last == word_count - 1,
                adj: if complete { 40 } else { 0 },
                ends_mid: !complete,
            });
        }
        let later = seconds & !below_bits(p0 + 1);
        if later != 0 {
            let p1 = later.trailing_zeros() as usize;
            let skipped = words_below(p1) - first_word - 1;
            let last = words_below(p1 + 1) - 1;
            let after = ws & !below_bits(p1 + 1);
            // A camelCase word typed as its two initials ("gh" for GitHub) counts as one word.
            let token = skipped == 0 && !hump(p0) && hump(p1) && (after == 0 || !hump(after.trailing_zeros() as usize));
            let complete = token || (word_end(p0 + 1) && word_end(p1 + 1));
            return Some(score::Seg {
                end: p1 + 1,
                first_word: first_word as u8,
                skipped: skipped as u8,
                segments: if token { 1 } else { 2 },
                covers_all: first_word == 0 && skipped == 0 && last == word_count - 1,
                adj: if complete { 40 } else { 0 },
                ends_mid: !token && !word_end(p1 + 1),
            });
        }
        cands &= cands - 1;
    }
    None
}

#[inline(always)]
fn first_at_word_all(bm: &[u64; MAX_NEEDLE], bn: &BitNeedle, nd: &Needle<'_, u8>, ws: u64) -> bool {
    nd.tokens
        .iter()
        .all(|&(a, _)| bm[bn.full_slot[a as usize] as usize] & ws != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every window length from 0 to 64 and every count of distinct chars from 1 to 32, over
    /// blocks whose bytes past the window are not zero, against a byte-by-byte reference.
    #[test]
    fn bitmaps_equal_a_scalar_reference() {
        let mut x: u64 = 0x2545_F491_4F6C_DD1D;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let alphabet = b"abcdefghijklmnopqrstuvwxyz0123456789 .-";
        let mut checked = 0;
        for n in 0..=64usize {
            for d in 1..=MAX_NEEDLE {
                let mut block = [0u8; 64];
                for b in block.iter_mut() {
                    *b = alphabet[(next() % alphabet.len() as u64) as usize];
                }
                // Half the draws come from the window, so most chars occur in it.
                let mut chars: Vec<u8> = Vec::new();
                while chars.len() < d {
                    let r = next();
                    let c = if r % 2 == 0 && n > 0 {
                        block[(r / 2 % n as u64) as usize]
                    } else {
                        alphabet[(r / 2 % alphabet.len() as u64) as usize]
                    };
                    if !chars.contains(&c) {
                        chars.push(c);
                    }
                }
                let mut got = [0u64; MAX_NEEDLE];
                bitmaps(&block, n, &chars, &mut got);
                for (k, &c) in chars.iter().enumerate() {
                    let want = block[..n]
                        .iter()
                        .enumerate()
                        .fold(0u64, |m, (i, &b)| m | (((b == c) as u64) << i));
                    assert_eq!(got[k], want, "n {n} chars {chars:?} char {k}");
                    checked += 1;
                }
            }
        }
        assert!(checked > 30_000, "{checked}");
    }
}
