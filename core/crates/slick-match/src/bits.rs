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

/// One bit per byte of `v` that equals the matching byte of `cv`, for 16 bytes.
///
/// # Safety
/// Needs NEON, which every aarch64 target has. It reads registers only, no memory.
#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn mask16(
    v: std::arch::aarch64::uint8x16_t,
    cv: std::arch::aarch64::uint8x16_t,
    w: std::arch::aarch64::uint8x16_t,
) -> u64 {
    use std::arch::aarch64::*;
    // SAFETY: NEON is part of the aarch64 baseline, and these intrinsics only touch registers.
    unsafe {
        let t = vandq_u8(vceqq_u8(v, cv), w);
        (vaddv_u8(vget_low_u8(t)) as u64) | ((vaddv_u8(vget_high_u8(t)) as u64) << 8)
    }
}

/// For each byte in `chars`, a bitmap of the positions in `block[..n]` that hold it. The loads
/// read whole 16-byte lanes of `block`, past `n` when `n` is not a multiple of 16; the mask drops
/// those bits.
#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn bitmaps(block: &[u8; 64], n: usize, chars: &[u8], out: &mut [u64; MAX_NEEDLE]) {
    use std::arch::aarch64::*;
    let p = block.as_ptr();
    // SAFETY: `block` is 64 readable bytes, and the loads below read `p[0..16]`, `p[16..32]`,
    // `p[32..48]` and `p[48..64]` at most. NEON is part of the aarch64 baseline.
    unsafe {
        const W: [u8; 16] = [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];
        let w = vld1q_u8(W.as_ptr());
        let lim = if n >= 64 { u64::MAX } else { (1u64 << n) - 1 };
        // Straight-line code per width class: a variable-length vector array spills to memcpy.
        let v0 = vld1q_u8(p);
        if n <= 16 {
            for (d, &c) in chars.iter().enumerate() {
                out[d] = mask16(v0, vdupq_n_u8(c), w) & lim;
            }
        } else if n <= 32 {
            let v1 = vld1q_u8(p.add(16));
            for (d, &c) in chars.iter().enumerate() {
                let cv = vdupq_n_u8(c);
                out[d] = (mask16(v0, cv, w) | (mask16(v1, cv, w) << 16)) & lim;
            }
        } else {
            let v1 = vld1q_u8(p.add(16));
            let v2 = vld1q_u8(p.add(32));
            let v3 = vld1q_u8(p.add(48));
            for (d, &c) in chars.iter().enumerate() {
                let cv = vdupq_n_u8(c);
                out[d] = (mask16(v0, cv, w)
                    | (mask16(v1, cv, w) << 16)
                    | (mask16(v2, cv, w) << 32)
                    | (mask16(v3, cv, w) << 48))
                    & lim;
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
        let mut b = ws;
        while b != 0 && nw < 32 {
            words[nw] = b.trailing_zeros() as u16;
            nw += 1;
            b &= b - 1;
        }
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
