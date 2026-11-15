//! Search over a snapshot: name tiers from `slick_match`, the folder tier, extensions and path
//! fragments, a bounded top k with a shared running threshold, narrowing as the query grows, and
//! parallel parts on threads the caller owns.
//!
//! A search runs in up to three passes:
//!
//! 1. **Prefix pass.** A prefix or exact match needs the name's first word to start with the
//!    query's first char. When at least `limit` such hits rank in those tiers, nothing else can
//!    enter the top k and the search stops after touching one byte per entry.
//! 2. **Strict pass** over every entry, or over the previous query's matches when the query only
//!    grew. It leaves every entry that passed the gate as the narrowing set for the next query.
//! 3. **Typo pass** over every entry when the best strict hit is weaker than word-prefix and the
//!    query has four chars or more, as in `slick_match`.

use crate::names::{self, ext_matches, fold_into, lower_block, stem_len};
use crate::query::{self, MAX_ANC_TOKENS, Parsed, Plan};
use crate::rank::{self, Lifter, Prefer, RankParams, TIER_GAP, tier};
use crate::store::{CHUNK, CHUNK_BITS, EntryId, NONE, Snapshot, View, flags};
use slick_match::bits::{self, Bound, Sc};
use slick_match::score::{self, PREFIX, SUBSTRING, TextScore, WORD_PREFIX};
use slick_match::{Query, Unit};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicUsize, Ordering::Relaxed};
use std::sync::{Arc, Mutex};

/// Which entries a search may return.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Kinds {
    #[default]
    All,
    Files,
    Folders,
}

/// Order of a folder listing with an empty filter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum BrowseSort {
    /// Case-insensitive name order.
    #[default]
    Name,
    /// Newest first.
    Modified,
}

/// Options for one search.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchOptions {
    /// Most hits to return.
    pub limit: usize,
    /// Only entries strictly below this folder.
    pub within: Option<EntryId>,
    pub kinds: Kinds,
    /// Lift files or folders inside each tier.
    pub prefer: Prefer,
    /// Return hidden entries, when the index holds them.
    pub include_hidden: bool,
    /// Current Unix time in seconds, for the recency lift.
    pub now: u32,
    /// Run the typo pass when nothing matches well.
    pub typo: bool,
    pub rank: RankParams,
    /// Expands a leading `~` in folder queries.
    pub home: Option<Vec<u8>>,
    /// Order of folder listings without a filter.
    pub browse_sort: BrowseSort,
}

impl Default for SearchOptions {
    fn default() -> Self {
        SearchOptions {
            limit: 50,
            within: None,
            kinds: Kinds::All,
            prefer: Prefer::Neither,
            include_hidden: false,
            now: 0,
            typo: true,
            rank: RankParams::default(),
            home: None,
            browse_sort: BrowseSort::Name,
        }
    }
}

/// How a hit matched.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum How {
    /// The query matched the name.
    Name = 0,
    /// Some tokens matched the name, the others started words of folders above it.
    Ancestor = 1,
    /// The last token was the extension and the others matched the name without it.
    Extension = 2,
    /// One edit away from a word of the name.
    Typo = 3,
    /// Only filters: an extension or path fragments without other text.
    Filter = 4,
    /// A child of a browsed folder.
    Browse = 5,
}

impl How {
    fn from_bits(b: u64) -> How {
        match b & 7 {
            0 => How::Name,
            1 => How::Ancestor,
            2 => How::Extension,
            3 => How::Typo,
            4 => How::Filter,
            _ => How::Browse,
        }
    }
}

/// One search result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileHit {
    pub id: EntryId,
    /// Higher is better. [`crate::rank`] has the layout.
    pub rank: i32,
    pub how: How,
}

impl FileHit {
    /// The file tier of the hit, one of [`crate::rank::tier`].
    pub fn tier(&self) -> u8 {
        rank::tier_of(self.rank)
    }
}

/// What the last search did, for tests and benchmarks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SearchStats {
    /// Entries the strict pass looked at.
    pub scanned: usize,
    /// The prefix pass filled the top k.
    pub prefix_only: bool,
    /// The strict pass ran over the previous query's matches.
    pub narrowed: bool,
    pub typo_ran: bool,
    /// A folder query named a folder the index does not hold.
    pub not_indexed: bool,
}

/// Runs work items on threads the caller owns.
pub trait ParallelFor: Sync {
    /// About how many items run at once. The search splits its work into about four parts per
    /// unit of width.
    fn width(&self) -> usize;
    /// Calls `f(i)` for every `i` in `0..n`, possibly at the same time, and returns when every call
    /// has returned.
    fn for_each(&self, n: usize, f: &(dyn Fn(usize) + Sync));
}

/// Runs everything on the calling thread.
#[derive(Clone, Copy, Debug, Default)]
pub struct Serial;

impl ParallelFor for Serial {
    fn width(&self) -> usize {
        1
    }

    fn for_each(&self, n: usize, f: &(dyn Fn(usize) + Sync)) {
        for i in 0..n {
            f(i);
        }
    }
}

/// Runs work on rayon's global pool.
#[cfg(feature = "parallel")]
#[derive(Clone, Copy, Debug, Default)]
pub struct Rayon;

#[cfg(feature = "parallel")]
impl ParallelFor for Rayon {
    fn width(&self) -> usize {
        rayon::current_num_threads()
    }

    fn for_each(&self, n: usize, f: &(dyn Fn(usize) + Sync)) {
        use rayon::prelude::*;
        (0..n).into_par_iter().with_max_len(1).for_each(f);
    }
}

// ---- keys and top k ----

const HOW_BITS: u32 = 3;
const ID_BITS: u32 = 32;

/// Sort key: rank, then lower id first, then how.
#[inline(always)]
fn key(rank: i32, id: EntryId, how: How) -> u64 {
    ((rank.clamp(0, (1 << 28) - 1) as u64) << (ID_BITS + HOW_BITS))
        | (((u32::MAX - id) as u64) << HOW_BITS)
        | how as u64
}

#[inline(always)]
fn unkey(k: u64) -> FileHit {
    FileHit {
        id: u32::MAX - (k >> HOW_BITS) as u32,
        rank: (k >> (ID_BITS + HOW_BITS)) as i32,
        how: How::from_bits(k),
    }
}

/// Keeps the `k` largest keys, sorted descending.
fn top_k(v: &mut Vec<u64>, k: usize) {
    if k == 0 {
        v.clear();
        return;
    }
    if v.len() > k {
        v.select_nth_unstable_by(k - 1, |a, b| b.cmp(a));
        v.truncate(k);
    }
    v.sort_unstable_by(|a, b| b.cmp(a));
}

/// A key buffer that compacts to the best `k` and then drops everything below the running k-th.
struct TopK<'a> {
    keys: &'a mut Vec<u64>,
    k: usize,
    compact_at: usize,
    thresh_key: u64,
    thresh: i32,
}

impl<'a> TopK<'a> {
    fn new(keys: &'a mut Vec<u64>, k: usize) -> Self {
        keys.clear();
        TopK {
            keys,
            k,
            compact_at: k.saturating_mul(8).max(256),
            thresh_key: 0,
            thresh: i32::MIN,
        }
    }

    /// Adds a key. Returns the new local threshold when it rose.
    #[inline(always)]
    fn push(&mut self, kk: u64) -> Option<i32> {
        if kk <= self.thresh_key {
            return None;
        }
        self.keys.push(kk);
        if self.keys.len() < self.compact_at {
            return None;
        }
        self.keys.select_nth_unstable_by(self.k - 1, |x, y| y.cmp(x));
        self.keys.truncate(self.k);
        self.thresh_key = self.keys[self.k - 1];
        self.thresh = unkey(self.thresh_key).rank;
        Some(self.thresh)
    }
}

// ---- folding and scoring one name ----

/// A folded name, ready for the scorer.
pub(crate) struct Folded {
    block: [u8; 64],
    buf: Vec<u8>,
    chars: Vec<char>,
    len: usize,
    ws: u64,
    in_block: bool,
    multibyte: bool,
}

impl Default for Folded {
    fn default() -> Self {
        Folded {
            block: [0; 64],
            buf: Vec::new(),
            chars: Vec::new(),
            len: 0,
            ws: 0,
            in_block: false,
            multibyte: false,
        }
    }
}

impl Folded {
    /// Loads the folded name of `slot`: lowercased in place for ASCII names, copied from the
    /// stored folded form for others.
    #[inline(always)]
    pub(crate) fn load_slot(&mut self, v: &View<'_>, slot: usize) {
        let multibyte = v.flags[slot] & flags::MULTIBYTE != 0;
        let stored = if multibyte { v.folded(slot) } else { &[] };
        self.load(v.name(slot), v.block(slot), stored, v.ws[slot], multibyte);
    }

    /// Folds `name`. `raw_block` is the 64 arena bytes that start at the name, when available;
    /// `stored` is the stored folded form of a multibyte name, when available.
    #[inline(always)]
    pub(crate) fn load(&mut self, name: &[u8], raw_block: Option<&[u8; 64]>, stored: &[u8], ws: u64, multibyte: bool) {
        self.ws = ws;
        self.multibyte = multibyte;
        if !multibyte
            && name.len() <= 64
            && let Some(b) = raw_block
        {
            lower_block(b, name.len(), &mut self.block);
            self.len = name.len();
            self.in_block = true;
            return;
        }
        if multibyte && !stored.is_empty() && stored.len() <= 64 {
            self.block[..stored.len()].copy_from_slice(stored);
            self.len = stored.len();
            self.in_block = true;
            return;
        }
        let _ = fold_into(name, &mut self.buf, &mut self.chars);
        self.len = self.buf.len();
        self.in_block = self.len <= 64;
        if self.in_block {
            self.block[..self.len].copy_from_slice(&self.buf);
        }
    }

    #[inline(always)]
    pub(crate) fn bytes(&self) -> &[u8] {
        if self.in_block {
            &self.block[..self.len]
        } else {
            &self.buf
        }
    }

    /// Scores the first `n` folded bytes against `q`.
    #[inline(always)]
    pub(crate) fn score(&mut self, q: &Query, n: usize, floor: u8, bound: Bound) -> Sc {
        let n = n.min(self.len);
        if n == 0 || q.is_empty() {
            return Sc::No;
        }
        if q.ascii {
            if q.bn.ok && self.in_block {
                return bits::score_bits(&q.needle(), &q.bn, &self.block, n, self.ws, floor, bound);
            }
            let s = if self.in_block {
                &self.block[..n]
            } else {
                &self.buf[..n]
            };
            return match score::score::<u8, false>(&q.needle(), s, self.ws, false, None) {
                Some(t) if t.tier < floor => Sc::Below,
                Some(t) => Sc::Yes(t),
                None => Sc::No,
            };
        }
        if !self.multibyte {
            return Sc::No;
        }
        let cws = self.decode(n);
        match score::score::<char, false>(&q.needle_chars(), &self.chars, cws, false, None) {
            Some(t) if t.tier < floor => Sc::Below,
            Some(t) => Sc::Yes(t),
            None => Sc::No,
        }
    }

    /// The typo-tier score of the whole name.
    pub(crate) fn typo(&mut self, q: &Query) -> Option<TextScore> {
        if self.len == 0 || q.is_empty() {
            return None;
        }
        if q.ascii {
            let s = if self.in_block {
                &self.block[..self.len]
            } else {
                &self.buf[..self.len]
            };
            return score::score::<u8, false>(&q.needle(), s, self.ws, true, None);
        }
        if !self.multibyte {
            return None;
        }
        let cws = self.decode(self.len);
        score::score::<char, false>(&q.needle_chars(), &self.chars, cws, true, None)
    }

    /// Decodes the first `n` folded bytes into `chars`, remapping word starts to char indices.
    fn decode(&mut self, n: usize) -> u64 {
        let s = if self.in_block {
            &self.block[..n]
        } else {
            &self.buf[..n]
        };
        self.chars.clear();
        let text = std::str::from_utf8(s).unwrap_or("");
        let mut cws = 0u64;
        for (ci, (bi, c)) in text.char_indices().enumerate() {
            let start = if bi < 64 {
                (self.ws >> bi) & 1 == 1
            } else {
                self.chars.last().is_some_and(|p: &char| p.is_sep()) && !c.is_sep()
            };
            if start && ci < 64 {
                cws |= 1u64 << ci;
            }
            self.chars.push(c);
        }
        cws
    }
}

#[inline(always)]
fn at_least_word_prefix(sc: Sc) -> bool {
    matches!(sc, Sc::Yes(t) if t.tier >= WORD_PREFIX)
}

// ---- one search ----

/// Memo bits per folder, valid for one search: token bits, path fragment bits, and the subtree
/// bit. Each is set when the folder or any folder above it has it.
const CHAIN_SHIFT: u32 = 8;
/// The best quality `slick_match` gives a typo match, before its position and length penalties.
const TYPO_QUALITY_MAX: i32 = 600;
const WITHIN_BIT: u32 = 1 << 12;
const GEN_SHIFT: u32 = 16;

struct Shared<'a> {
    snap: &'a Snapshot,
    plan: &'a Plan,
    opts: &'a SearchOptions,
    lifter: Lifter,
    memo: &'a [AtomicU32],
    stamp: u32,
    within: EntryId,
    k: usize,
    thresh: AtomicI32,
    chains_all: u32,
    use_memo: bool,
    /// Bitmask of the plain tokens the folder tier considers.
    all_tokens: u32,
    /// Compressed masks of every plain token, in order, at most 32.
    token_masks: Vec<u32>,
    /// The masks of the folder-tier tokens, padded with `u32::MAX`.
    anc_masks: [u32; MAX_ANC_TOKENS],
    /// Bitmask of the tokens past the folder-tier limit, which must always fit the name.
    extra_tokens: u32,
    /// Compressed initials bit of the literal's first char, or 0 when it is not a letter or digit.
    first_initial: u32,
    /// Compressed `typo_bits` of the literal.
    typo_initials: u32,
    /// Folded byte length of the literal when the prefix-pass length bound applies, else 0.
    prefix_len: usize,
    /// Collect typo keys during a full strict pass.
    fuse_typo: bool,
    /// Some part found a hit at word-prefix or better, so the typo pass will not run.
    strong: AtomicBool,
    /// The best k-th typo rank any part has seen.
    typo_thresh: AtomicI32,
}

/// Per-part scratch.
#[derive(Default)]
struct Part {
    keys: Vec<u64>,
    typo_keys: Vec<u64>,
    matched: Vec<u32>,
    /// Entries with a typo match in this pass.
    typo_matched: Vec<u32>,
    cur: Folded,
    /// The entry whose name `cur` holds, or `NONE`.
    cur_id: EntryId,
    /// Candidate slots of the chunk being scanned.
    selected: Vec<u16>,
    /// The folder whose memo bits `last_bits` holds. A part starts with `NONE` and bits 0, which
    /// are the bits of an entry without a parent.
    last_parent: EntryId,
    last_bits: u32,
    dir: Folded,
    stack: Vec<EntryId>,
    best: i32,
    scanned: usize,
}

enum Eval {
    No,
    Gated,
    Hit(u64),
}

impl Shared<'_> {
    #[inline(always)]
    fn kind_ok(&self, fl: u8) -> bool {
        if fl & flags::DEAD != 0 || (fl & flags::HIDDEN != 0 && !self.opts.include_hidden) {
            return false;
        }
        match self.opts.kinds {
            Kinds::All => true,
            Kinds::Files => fl & flags::DIR == 0,
            Kinds::Folders => fl & flags::DIR != 0,
        }
    }

    /// The memo bits of `dir`: what it and every folder above it match.
    #[inline(always)]
    fn memo_bits(&self, part: &mut Part, dir: EntryId) -> u32 {
        let Some(slot) = self.memo.get(dir as usize) else {
            return 0;
        };
        let v = slot.load(Relaxed);
        if v >> GEN_SHIFT == self.stamp {
            return v & 0xFFFF;
        }
        self.fill_memo(part, dir)
    }

    /// Computes and stores the memo bits of `dir` and of every folder above it that lacks them.
    #[inline(never)]
    fn fill_memo(&self, part: &mut Part, dir: EntryId) -> u32 {
        part.stack.clear();
        let mut cur = dir;
        let mut base = 0u32;
        loop {
            part.stack.push(cur);
            let p = self.snap.parent_of(cur);
            if p == NONE || part.stack.len() > crate::store::MAX_DEPTH + 1 {
                break;
            }
            if let Some(ps) = self.memo.get(p as usize) {
                let pv = ps.load(Relaxed);
                if pv >> GEN_SHIFT == self.stamp {
                    base = pv & 0xFFFF;
                    break;
                }
            }
            cur = p;
        }
        while let Some(d) = part.stack.pop() {
            base |= self.own_bits(part, d);
            if let Some(s) = self.memo.get(d as usize) {
                s.store((self.stamp << GEN_SHIFT) | base, Relaxed);
            }
        }
        base
    }

    /// What one folder's own name matches.
    fn own_bits(&self, part: &mut Part, d: EntryId) -> u32 {
        let mut bits = 0u32;
        if d == self.within {
            bits |= WITHIN_BIT;
        }
        let p = self.plan;
        if !p.ancestors && p.chains.is_empty() {
            return bits;
        }
        let Some((c, s)) = self.snap.locate(d) else {
            return bits;
        };
        let m = c.mask.as_slice()[s];
        let ini = c.initials.as_slice()[s];
        if p.ancestors {
            // A word-prefix match needs every char of the token and its first char at a word
            // start; check both on the folder's masks before folding its name.
            let mut loaded = false;
            for (j, t) in p.tokens.iter().take(MAX_ANC_TOKENS).enumerate() {
                if t.mask & !m != 0 || (t.first_initial != 0 && ini & t.first_initial == 0) {
                    continue;
                }
                if !loaded {
                    part.dir.load_slot(&c.view(), s);
                    loaded = true;
                }
                let len = part.dir.len;
                if at_least_word_prefix(part.dir.score(&t.q, len, WORD_PREFIX, Bound::NONE)) {
                    bits |= 1 << j;
                }
            }
        }
        for (ci, chain) in p.chains.iter().enumerate() {
            if self.chain_ends_at(part, d, chain) {
                bits |= 1 << (CHAIN_SHIFT + ci as u32);
            }
        }
        bits
    }

    /// True when the path fragment's last part matches `d` and the earlier parts match the
    /// folders right above it.
    fn chain_ends_at(&self, part: &mut Part, d: EntryId, chain: &query::Chain) -> bool {
        let mut cur = d;
        for q in chain.parts.iter().rev() {
            let Some((c, s)) = self.snap.locate(cur) else {
                return false;
            };
            if compress(q) & !c.mask.as_slice()[s] != 0 {
                return false;
            }
            let fi = first_initial(q);
            if fi != 0 && c.initials.as_slice()[s] & fi == 0 {
                return false;
            }
            let v = c.view();
            part.dir.load_slot(&v, s);
            let len = part.dir.len;
            if !at_least_word_prefix(part.dir.score(q, len, WORD_PREFIX, Bound::NONE)) {
                return false;
            }
            cur = v.parent[s];
        }
        true
    }

    /// The memo bits of the folder above slot `slot`. Siblings sit next to each other, so the
    /// last parent's bits are kept at hand.
    #[inline(always)]
    fn parent_bits(&self, part: &mut Part, v: &View<'_>, slot: usize) -> u32 {
        let parent = v.parent[slot];
        if parent == part.last_parent {
            return part.last_bits;
        }
        let bits = if parent == NONE {
            0
        } else {
            self.memo_bits(part, parent)
        };
        part.last_parent = parent;
        part.last_bits = bits;
        bits
    }

    /// Evaluates one entry against the plan.
    #[inline(always)]
    fn eval(&self, part: &mut Part, v: &View<'_>, slot: usize, id: EntryId, thresh: i32) -> Eval {
        let fl = v.flags[slot];
        if !self.kind_ok(fl) {
            return Eval::No;
        }
        let p = self.plan;
        let m = v.mask[slot];
        let lit_ok = p.literal.is_some() && p.lit_mask & !m == 0;
        let mut anc = 0u32;
        let mut anc_known = false;
        if p.simple {
            if !lit_ok {
                return Eval::No;
            }
        } else {
            if p.dot_ext.is_some() && p.dot_ext_mask & !m != 0 {
                return Eval::No;
            }
            if p.literal.is_some() && !lit_ok {
                // Only the folder tier can match: some token must start a word of a folder
                // above, and every other token must fit the name. Check the cached folder bits
                // before touching the name.
                // Tokens whose chars are all in the name.
                let nm = !m;
                let t = &self.anc_masks;
                let mut fits = u32::from(t[0] & nm == 0)
                    | u32::from(t[1] & nm == 0) << 1
                    | u32::from(t[2] & nm == 0) << 2
                    | u32::from(t[3] & nm == 0) << 3
                    | u32::from(t[4] & nm == 0) << 4
                    | u32::from(t[5] & nm == 0) << 5;
                if self.extra_tokens != 0 {
                    for (j, &tm) in self.token_masks.iter().enumerate().skip(MAX_ANC_TOKENS) {
                        fits |= u32::from(tm & nm == 0) << j;
                    }
                }
                if !p.ancestors || fits & self.all_tokens == 0 || fits & self.extra_tokens != self.extra_tokens {
                    return Eval::No;
                }
                anc = self.parent_bits(part, v, slot);
                anc_known = true;
                let in_folders = anc & self.all_tokens;
                // Every token that no folder above holds must fit the name.
                if in_folders == 0 || (self.all_tokens & !in_folders) & !fits != 0 {
                    return Eval::No;
                }
            }
        }
        if self.use_memo && (self.within != NONE || self.chains_all != 0) {
            if !anc_known {
                anc = self.parent_bits(part, v, slot);
                anc_known = true;
            }
            if self.within != NONE && anc & WITHIN_BIT == 0 {
                return Eval::No;
            }
            if anc & self.chains_all != self.chains_all {
                return Eval::No;
            }
        }
        let lift = self.lifter.lift(v.mtime[slot], v.depth[slot], fl & flags::DIR != 0);
        if thresh != i32::MIN {
            // Skip the name when no interpretation left for this entry can reach the threshold.
            // The gate is not checked, so the entry stays in the narrowing set.
            let best_possible = if p.literal.is_none() {
                rank::best_in_tier(tier::PREFIX, lift)
            } else if !lit_ok {
                rank::best_in_tier(tier::ANCESTOR, lift)
            } else {
                i32::MAX
            };
            if best_possible < thresh {
                return Eval::Gated;
            }
        }
        part.scanned += 1;
        let (floor, bound) = rank::floor_and_bound(thresh, lift);
        // Every tier above substring needs the query's first char at a word start, and prefix and
        // exact need it at the first one.
        let first_off_words = self.first_initial != 0 && v.initials[slot] & self.first_initial == 0;
        let first_off_start = p.first.is_some_and(|f| v.first[slot] != f);
        let name_capped = (first_off_words && floor > SUBSTRING) || (first_off_start && floor >= PREFIX);
        if p.simple && name_capped {
            return Eval::Gated;
        }
        part.cur.load_slot(v, slot);
        part.cur_id = id;
        let len = part.cur.len;
        let mut window = len;
        if let Some(ext) = &p.dot_ext {
            if !ext_matches(part.cur.bytes(), ext, false) {
                return Eval::No;
            }
            window = stem_len(part.cur.bytes()).unwrap_or(len);
        }
        let Some(lit) = &p.literal else {
            let exact = p
                .dot_ext
                .as_ref()
                .is_some_and(|e| ext_matches(part.cur.bytes(), e, true));
            let q = if exact || p.dot_ext.is_none() { 999 } else { 500 };
            let r = TIER_GAP * tier::PREFIX as i32 + q + lift;
            return Eval::Hit(key(r, id, How::Filter));
        };
        let mut best = i32::MIN;
        let mut how = How::Name;
        let mut gated = false;
        if lit_ok {
            if name_capped {
                gated = true;
            } else {
                match part.cur.score(lit, window, floor, bound) {
                    Sc::Yes(t) => best = rank::name_rank(t, lift),
                    Sc::Below => gated = true,
                    Sc::No => {}
                }
            }
        }
        if let Some((ext, rest, rest_mask)) = &p.bare_ext
            && p.dot_ext.is_none()
            && rest_mask & !m == 0
            && ext_matches(part.cur.bytes(), ext, true)
        {
            if name_capped {
                gated = true;
            } else {
                let stem = stem_len(part.cur.bytes()).unwrap_or(len);
                match part.cur.score(rest, stem, floor, bound) {
                    Sc::Yes(t) => {
                        let r = rank::name_rank(t, lift);
                        if r > best {
                            best = r;
                            how = How::Extension;
                        }
                    }
                    Sc::Below => gated = true,
                    Sc::No => {}
                }
            }
        }
        if p.ancestors && (best == i32::MIN || rank::tier_of(best) < tier::ANCESTOR) {
            let all = self.all_tokens;
            if !anc_known {
                anc = self.parent_bits(part, v, slot);
            }
            let in_folders = anc & all;
            if in_folders != 0 {
                let mut sub = 0u32;
                let bytes = &part.cur.bytes()[..window.min(len)];
                for (j, t) in p.tokens.iter().take(MAX_ANC_TOKENS).enumerate() {
                    if t.mask & !m == 0 && score::is_subsequence(&t.q.ns, bytes) {
                        sub |= 1 << j;
                    }
                }
                if sub != 0 && (all & !sub) & !in_folders == 0 {
                    let mut base = all & !in_folders;
                    if base == 0 {
                        base = 1 << (31 - sub.leading_zeros());
                    }
                    if base & !sub == 0 && base != all {
                        gated = true;
                        if (thresh == i32::MIN || rank::best_in_tier(tier::ANCESTOR, lift) >= thresh)
                            && let Some(q) = p.subset(base)
                            && let Sc::Yes(t) = part.cur.score(q, window, 0, Bound::NONE)
                        {
                            let r = rank::ancestor_rank(t, lift);
                            if r > best {
                                best = r;
                                how = How::Ancestor;
                            }
                        }
                    }
                }
            }
        }
        if best != i32::MIN {
            Eval::Hit(key(best, id, how))
        } else if gated {
            Eval::Gated
        } else {
            Eval::No
        }
    }

    /// The typo-tier key of one entry, for simple plans.
    #[inline]
    /// `Gated` means the entry passed the cheap typo checks but cannot reach `thresh`; it stays a
    /// typo candidate for longer queries.
    fn eval_typo(&self, part: &mut Part, v: &View<'_>, slot: usize, id: EntryId, thresh: i32) -> Eval {
        let fl = v.flags[slot];
        if !self.kind_ok(fl) {
            return Eval::No;
        }
        let Some(lit) = self.plan.literal.as_ref() else {
            return Eval::No;
        };
        let m = v.mask[slot];
        if (self.plan.lit_mask & !m).count_ones() > 1 || v.initials[slot] & self.typo_initials == 0 {
            return Eval::No;
        }
        if self.within != NONE {
            let parent = v.parent[slot];
            let anc = if parent == NONE {
                0
            } else {
                self.memo_bits(part, parent)
            };
            if anc & WITHIN_BIT == 0 {
                return Eval::No;
            }
        }
        let lift = self.lifter.lift(v.mtime[slot], v.depth[slot], fl & flags::DIR != 0);
        if thresh != i32::MIN {
            // `slick_match` scores a typo at most 600, less 3 per byte the name is longer than
            // the query; for an ASCII name that length is known without folding it.
            let extra = if fl & flags::MULTIBYTE == 0 && lit.ascii {
                (v.name_len[slot] as i32 - lit.ns.len() as i32).clamp(0, 60)
            } else {
                0
            };
            let best = TIER_GAP * tier::TYPO as i32 + TYPO_QUALITY_MAX - 3 * extra + lift.clamp(0, rank::MAX_LIFT);
            if best < thresh {
                return Eval::Gated;
            }
        }
        if part.cur_id != id {
            part.cur.load_slot(v, slot);
            part.cur_id = id;
        }
        // The scorer only tries words whose initial is the query's first or second char, which is
        // the exact form of the initials check above.
        match part.cur.typo(lit) {
            Some(t) => Eval::Hit(key(rank::name_rank(t, lift), id, How::Typo)),
            None => Eval::No,
        }
    }

    #[inline(always)]
    fn threshold(&self, local: i32) -> i32 {
        local.max(self.thresh.load(Relaxed))
    }
}

fn compress(q: &Query) -> u32 {
    names::compress_mask(q.mask)
}

/// The compressed initials bit of the query's first char, or 0 when that is not an ASCII letter or
/// digit. A 0 turns the initials check off.
pub(crate) fn first_initial(q: &Query) -> u32 {
    if !q.ascii {
        return 0;
    }
    q.ns.first()
        .filter(|c| c.is_ascii_alphanumeric())
        .map_or(0, |&c| names::compress_mask(slick_match::fold::mask_bit(c as char)))
}

/// Which entries one part looks at.
#[derive(Clone, Copy)]
enum Work<'c> {
    /// Chunks `start..end`.
    Chunks(usize, usize),
    /// A slice of candidate ids, ascending.
    Ids(&'c [u32]),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Pass {
    Prefix(u8),
    Strict,
    Typo,
}

fn run_part(sh: &Shared<'_>, part: &mut Part, work: Work<'_>, pass: Pass) {
    let mut keys = std::mem::take(&mut part.keys);
    let mut typo_keys = std::mem::take(&mut part.typo_keys);
    part.matched.clear();
    part.best = i32::MIN;
    part.scanned = 0;
    part.cur_id = NONE;
    part.last_parent = NONE;
    part.last_bits = 0;
    let strong = rank::file_tier(WORD_PREFIX);
    part.typo_matched.clear();
    {
        let (buf, typo_buf) = if pass == Pass::Typo {
            (&mut typo_keys, &mut keys)
        } else {
            (&mut keys, &mut typo_keys)
        };
        let mut top = TopK::new(buf, sh.k);
        // Typo keys collected during the strict pass, while no part has a word-prefix hit yet.
        let mut typo_top = TopK::new(typo_buf, sh.k);
        let fuse = pass == Pass::Strict && sh.fuse_typo;
        let visit =
            |part: &mut Part, v: &View<'_>, slot: usize, id: EntryId, top: &mut TopK<'_>, typo_top: &mut TopK<'_>| {
                match pass {
                    Pass::Prefix(f) => {
                        if v.first[slot] != f {
                            return;
                        }
                        let thresh = sh.threshold(top.thresh);
                        // A prefix match on a longer name loses 6 quality points per extra byte, as
                        // `slick_match::score::prefix_quality` says. Skip names that cannot reach the
                        // threshold.
                        // Only ASCII names: their folded length is their stored length.
                        if thresh != i32::MIN && sh.prefix_len > 0 && v.flags[slot] & flags::MULTIBYTE == 0 {
                            let n = v.name_len[slot] as usize;
                            let best_q = if n <= sh.prefix_len {
                                rank::MAX_QUALITY
                            } else {
                                990 - 6 * (n - sh.prefix_len).min(60) as i32
                            };
                            let best_tier = if n <= sh.prefix_len { tier::EXACT } else { tier::PREFIX };
                            let lift = sh
                                .lifter
                                .lift(v.mtime[slot], v.depth[slot], v.flags[slot] & flags::DIR != 0);
                            if TIER_GAP * best_tier as i32 + best_q + lift < thresh {
                                return;
                            }
                        }
                        if let Eval::Hit(k) = sh.eval(part, v, slot, id, thresh)
                            && let Some(t) = top.push(k)
                        {
                            sh.thresh.fetch_max(t, Relaxed);
                        }
                    }
                    Pass::Strict => {
                        let thresh = sh.threshold(top.thresh);
                        match sh.eval(part, v, slot, id, thresh) {
                            Eval::No => {}
                            Eval::Gated => part.matched.push(id),
                            Eval::Hit(k) => {
                                part.matched.push(id);
                                let r = unkey(k).rank;
                                part.best = part.best.max(r);
                                if fuse && rank::tier_of(r) >= strong {
                                    sh.strong.store(true, Relaxed);
                                }
                                if let Some(t) = top.push(k) {
                                    sh.thresh.fetch_max(t, Relaxed);
                                }
                            }
                        }
                        if fuse && !sh.strong.load(Relaxed) {
                            let tt = typo_top.thresh.max(sh.typo_thresh.load(Relaxed));
                            let e = sh.eval_typo(part, v, slot, id, tt);
                            typo_visit(sh, part, e, id, typo_top);
                        }
                    }
                    Pass::Typo => {
                        let tt = top.thresh.max(sh.typo_thresh.load(Relaxed));
                        let e = sh.eval_typo(part, v, slot, id, tt);
                        typo_visit(sh, part, e, id, top);
                    }
                }
            };
        match work {
            Work::Chunks(start, end) => {
                let mut sel = std::mem::take(&mut part.selected);
                for c in start..end {
                    let Some(chunk) = sh.snap.chunks.get(c) else { break };
                    let v = chunk.view();
                    let base = (c << CHUNK_BITS) as u32;
                    select(sh, part, pass, &v, &mut sel);
                    for &slot in &sel {
                        let slot = slot as usize;
                        visit(part, &v, slot, base + slot as u32, &mut top, &mut typo_top);
                    }
                }
                part.selected = sel;
            }
            Work::Ids(ids) => {
                let mut i = 0;
                while i < ids.len() {
                    let c = (ids[i] >> CHUNK_BITS) as usize;
                    let Some(chunk) = sh.snap.chunks.get(c) else { break };
                    let v = chunk.view();
                    while i < ids.len() && (ids[i] >> CHUNK_BITS) as usize == c {
                        let slot = ids[i] as usize & (CHUNK - 1);
                        if slot < v.len() {
                            visit(part, &v, slot, ids[i], &mut top, &mut typo_top);
                        }
                        i += 1;
                    }
                }
            }
        }
    }
    part.keys = keys;
    part.typo_keys = typo_keys;
}

struct Level {
    plan: Box<Plan>,
    matched: Vec<u32>,
    /// Entries with a typo match, when the typo pass ran over every entry or over the previous
    /// level's set. A typo match for a longer query is a typo match for this one too, so the
    /// next level's typo pass only needs these.
    typo: Option<Vec<u32>>,
}

/// The state that makes consecutive searches cheap: per-part buffers, the folder memo and the
/// narrowing stack. Keep one per search field; it is not shared between threads.
pub struct Searcher {
    parts: Vec<Mutex<Part>>,
    memo: Vec<AtomicU32>,
    stamp: u32,
    levels: Vec<Level>,
    session: Option<(u64, usize, Option<EntryId>, Kinds, bool)>,
    snap: Option<Arc<Snapshot>>,
    merge: Vec<u64>,
    stats: SearchStats,
}

impl Default for Searcher {
    fn default() -> Self {
        Searcher::new()
    }
}

/// Deepest narrowing stack a searcher keeps.
const MAX_LEVELS: usize = 64;

impl Searcher {
    pub fn new() -> Searcher {
        Searcher {
            parts: Vec::new(),
            memo: Vec::new(),
            stamp: 0,
            levels: Vec::new(),
            session: None,
            snap: None,
            merge: Vec::new(),
            stats: SearchStats::default(),
        }
    }

    /// Forgets earlier queries. Call it when the panel opens.
    pub fn reset(&mut self) {
        self.levels.clear();
        self.session = None;
    }

    /// The snapshot the last search ran on. Hit ids resolve against it.
    pub fn snapshot(&self) -> Option<&Arc<Snapshot>> {
        self.snap.as_ref()
    }

    /// What the last search did.
    pub fn stats(&self) -> SearchStats {
        self.stats
    }

    fn next_stamp(&mut self) -> u32 {
        self.stamp = (self.stamp + 1) & 0xFFFF;
        if self.stamp == 0 {
            for m in &self.memo {
                m.store(0, Relaxed);
            }
            self.stamp = 1;
        }
        self.stamp
    }

    /// Searches `snap` for `query` and writes the best hits into `out`, best first. Text that
    /// starts with `/` or `~` lists a folder instead. Parts run through `par`.
    pub fn search(
        &mut self,
        snap: &Arc<Snapshot>,
        query: &str,
        opts: &SearchOptions,
        par: &dyn ParallelFor,
        out: &mut Vec<FileHit>,
    ) {
        out.clear();
        self.stats = SearchStats::default();
        if self.snap.as_ref().is_none_or(|s| !Arc::ptr_eq(s, snap)) {
            self.snap = Some(snap.clone());
        }
        let plan = match query::parse(query, opts.home.as_deref()) {
            Parsed::Browse { dir, filter } => {
                self.stats.not_indexed = !crate::browse::list(snap, &dir, &filter, opts, out);
                return;
            }
            Parsed::Search(p) => p,
        };
        if opts.limit == 0 || (plan.literal.is_none() && plan.dot_ext.is_none() && plan.chains.is_empty()) {
            return;
        }
        let session = (
            snap.generation(),
            snap.slots(),
            opts.within,
            opts.kinds,
            opts.include_hidden,
        );
        if self.session != Some(session) {
            self.levels.clear();
            self.session = Some(session);
        }
        while self.levels.last().is_some_and(|l| !query::narrows(&l.plan, &plan)) {
            self.levels.pop();
        }
        let use_memo = plan.needs_memo() || opts.within.is_some();
        if use_memo && self.memo.len() < snap.slots() {
            self.memo.resize_with(snap.slots(), || AtomicU32::new(0));
        }
        let stamp = if use_memo { self.next_stamp() } else { 0 };
        let width = par.width().max(1);
        let want_parts = if width == 1 { 1 } else { width * 4 };
        while self.parts.len() < want_parts {
            self.parts.push(Mutex::new(Part::default()));
        }
        let k = opts.limit;
        let chains_all = (0..plan.chains.len()).fold(0u32, |a, i| a | 1 << (CHAIN_SHIFT + i as u32));
        let cands = self.levels.last().map(|l| l.matched.as_slice());
        // The typo pass may run: `slick_match` runs it for queries of four chars or more whose
        // best strict hit is weaker than word-prefix.
        let wants_typo = plan.simple && opts.typo && plan.literal.as_ref().is_some_and(|q| q.len_chars() >= 4);
        let sh = Shared {
            snap,
            plan: &plan,
            opts,
            lifter: Lifter::new(&opts.rank, opts.now, opts.prefer),
            memo: &self.memo,
            stamp,
            within: opts.within.unwrap_or(NONE),
            k,
            thresh: AtomicI32::new(i32::MIN),
            chains_all,
            use_memo,
            all_tokens: (1u32 << plan.tokens.len().min(MAX_ANC_TOKENS)) - 1,
            token_masks: plan.tokens.iter().take(32).map(|t| t.mask).collect(),
            anc_masks: {
                let mut a = [u32::MAX; MAX_ANC_TOKENS];
                for (slot, t) in a.iter_mut().zip(&plan.tokens) {
                    *slot = t.mask;
                }
                a
            },
            extra_tokens: (MAX_ANC_TOKENS..plan.tokens.len().min(32)).fold(0, |a, j| a | 1 << j),
            first_initial: plan.literal.as_ref().map_or(0, first_initial),
            typo_initials: plan.literal.as_ref().map_or(0, |q| names::compress_mask(q.typo_bits)),
            prefix_len: plan
                .literal
                .as_ref()
                .filter(|q| q.ascii && plan.simple)
                .map_or(0, |q| q.full.len()),
            fuse_typo: wants_typo && cands.is_none(),
            strong: AtomicBool::new(false),
            typo_thresh: AtomicI32::new(i32::MIN),
        };
        let n_chunks = snap.chunks.len();
        let parts = &self.parts;
        let merge = &mut self.merge;

        // 1. prefix pass, for single-token queries: several tokens rarely fill the top k with
        // prefix matches, so the pass would only cost time.
        if cands.is_none()
            && plan.tokens.len() <= 1
            && let Some(f) = plan.first
        {
            let n = want_parts.min(n_chunks).max(1);
            run_parts(par, parts, n, &|i| chunk_range(i, n, n_chunks), &sh, Pass::Prefix(f));
            collect(parts, n, merge, false);
            top_k(merge, k);
            if merge.len() == k && merge.last().is_some_and(|&kk| rank::is_prefix_tier(unkey(kk).rank)) {
                out.extend(merge.iter().map(|&kk| unkey(kk)));
                self.stats.prefix_only = true;
                return;
            }
        }

        // 2. strict pass
        let scanned = AtomicUsize::new(0);
        let n = match cands {
            Some(c) => want_parts.min(c.len().div_ceil(256)).max(1),
            None => want_parts.min(n_chunks).max(1),
        };
        {
            let work = |i: usize| match cands {
                Some(c) => {
                    let per = c.len().div_ceil(n);
                    Work::Ids(&c[(i * per).min(c.len())..((i + 1) * per).min(c.len())])
                }
                None => chunk_range(i, n, n_chunks),
            };
            par.for_each(n, &|i| {
                let mut p = parts[i].lock().unwrap_or_else(|e| e.into_inner());
                run_part(&sh, &mut p, work(i), Pass::Strict);
                scanned.fetch_add(p.scanned, Relaxed);
            });
        }
        self.stats.scanned = scanned.load(Relaxed);
        self.stats.narrowed = cands.is_some();
        collect(parts, n, merge, false);
        top_k(merge, k);
        let best = (0..n)
            .map(|i| parts[i].lock().map_or(i32::MIN, |p| p.best))
            .max()
            .unwrap_or(i32::MIN);
        let mut matched = Vec::new();
        for p in parts.iter().take(n) {
            let p = p.lock().unwrap_or_else(|e| e.into_inner());
            matched.extend_from_slice(&p.matched);
        }

        // 3. typo pass: its keys are already in the parts after a full strict pass; after a
        // narrowed one it scans every entry.
        let typo = wants_typo && (best == i32::MIN || rank::tier_of(best) < rank::file_tier(WORD_PREFIX));
        let mut typo_set = None;
        if typo {
            let prev_typo = self.levels.last().and_then(|l| l.typo.as_deref());
            let tn = if cands.is_none() {
                n
            } else if let Some(t) = prev_typo {
                let tn = want_parts.min(t.len().div_ceil(256)).max(1);
                let per = t.len().div_ceil(tn);
                run_parts_ids(
                    par,
                    parts,
                    tn,
                    &|i| &t[(i * per).min(t.len())..((i + 1) * per).min(t.len())],
                    &sh,
                );
                tn
            } else {
                let tn = want_parts.min(n_chunks).max(1);
                run_parts(par, parts, tn, &|i| chunk_range(i, tn, n_chunks), &sh, Pass::Typo);
                tn
            };
            collect(parts, tn, merge, true);
            let mut set = Vec::new();
            for p in parts.iter().take(tn) {
                set.extend_from_slice(&p.lock().unwrap_or_else(|e| e.into_inner()).typo_matched);
            }
            typo_set = Some(set);
            merge.sort_unstable_by(|a, b| b.cmp(a));
            let mut seen = std::collections::HashSet::with_capacity(k * 2);
            for &kk in merge.iter() {
                let h = unkey(kk);
                if seen.insert(h.id) {
                    out.push(h);
                    if out.len() == k {
                        break;
                    }
                }
            }
            self.stats.typo_ran = true;
        } else {
            out.extend(merge.iter().map(|&kk| unkey(kk)));
        }

        if self.levels.len() < MAX_LEVELS {
            self.levels.push(Level {
                plan,
                matched,
                typo: typo_set,
            });
        }
    }

    /// UTF-16 ranges of the name of `hit` that `query` matched, for the rows on screen. Allocates
    /// a little; call it for visible rows only.
    pub fn highlight(&self, hit: &FileHit, query: &str, opts: &SearchOptions, out: &mut Vec<(u32, u32)>) {
        out.clear();
        if let Some(snap) = &self.snap {
            crate::highlight::ranges(snap, hit, query, opts, out);
        }
    }
}

/// Records one typo evaluation: candidates stay in the part's typo set, hits go to the top k.
#[inline(always)]
fn typo_visit(sh: &Shared<'_>, part: &mut Part, e: Eval, id: EntryId, top: &mut TopK<'_>) {
    match e {
        Eval::No => {}
        Eval::Gated => part.typo_matched.push(id),
        Eval::Hit(k) => {
            part.typo_matched.push(id);
            if let Some(t) = top.push(k) {
                sh.typo_thresh.fetch_max(t, Relaxed);
            }
        }
    }
}

/// Writes the slots of one chunk that can pass `pass` into `out`: a tight loop over one or two
/// columns, so the full evaluation only runs for candidates. It drops only slots the evaluation
/// would reject.
fn select(sh: &Shared<'_>, part: &mut Part, pass: Pass, v: &View<'_>, out: &mut Vec<u16>) {
    let n = v.len();
    out.clear();
    out.resize(n, 0);
    let mut k = 0usize;
    let p = sh.plan;
    match pass {
        Pass::Prefix(f) => {
            let first = &v.first[..n];
            for (i, &b) in first.iter().enumerate() {
                out[k] = i as u16;
                k += usize::from(b == f);
            }
        }
        Pass::Typo => {
            let (masks, ini) = (&v.mask[..n], &v.initials[..n]);
            let (lm, ti) = (p.lit_mask, sh.typo_initials);
            for i in 0..n {
                out[k] = i as u16;
                k += usize::from((lm & !masks[i]).count_ones() <= 1 && ini[i] & ti != 0);
            }
        }
        Pass::Strict => {
            let masks = &v.mask[..n];
            if p.simple && sh.fuse_typo {
                let ini = &v.initials[..n];
                let (lm, ti) = (p.lit_mask, sh.typo_initials);
                for i in 0..n {
                    let missing = lm & !masks[i];
                    out[k] = i as u16;
                    k += usize::from(missing == 0 || (missing.count_ones() <= 1 && ini[i] & ti != 0));
                }
            } else if p.literal.is_some() && p.ancestors {
                // The whole query fits the name, or some token starts a word of a folder above
                // it and every other token fits the name. Siblings sit together, so the folder
                // bits are looked up once per parent. Unused token slots hold a mask no name has.
                let t = sh.anc_masks;
                let (lm, all) = (p.lit_mask, sh.all_tokens);
                let parents = &v.parent[..n];
                let (mut last_p, mut last_bits) = (NONE, 0u32);
                for (i, &m) in masks.iter().enumerate() {
                    let nm = !m;
                    let fits = u32::from(t[0] & nm == 0)
                        | u32::from(t[1] & nm == 0) << 1
                        | u32::from(t[2] & nm == 0) << 2
                        | u32::from(t[3] & nm == 0) << 3
                        | u32::from(t[4] & nm == 0) << 4
                        | u32::from(t[5] & nm == 0) << 5;
                    let cand = if fits == 0 {
                        false
                    } else if lm & nm == 0 {
                        true
                    } else {
                        let pid = parents[i];
                        if pid != last_p {
                            last_bits = if pid == NONE { 0 } else { sh.memo_bits(part, pid) & all };
                            last_p = pid;
                        }
                        last_bits != 0 && (all & !fits) & !last_bits == 0
                    };
                    out[k] = i as u16;
                    k += usize::from(cand);
                }
            } else if p.literal.is_some() {
                let lm = p.lit_mask;
                for (i, &m) in masks.iter().enumerate() {
                    out[k] = i as u16;
                    k += usize::from(lm & !m == 0);
                }
            } else if p.dot_ext.is_some() {
                let dm = p.dot_ext_mask;
                for (i, &m) in masks.iter().enumerate() {
                    out[k] = i as u16;
                    k += usize::from(dm & !m == 0);
                }
            } else {
                for (i, slot) in out.iter_mut().enumerate() {
                    *slot = i as u16;
                }
                k = n;
            }
        }
    }
    out.truncate(k);
}

fn chunk_range(i: usize, n: usize, n_chunks: usize) -> Work<'static> {
    let per = n_chunks.div_ceil(n.max(1));
    Work::Chunks((i * per).min(n_chunks), ((i + 1) * per).min(n_chunks))
}

fn run_parts(
    par: &dyn ParallelFor,
    parts: &[Mutex<Part>],
    n: usize,
    work: &(dyn Fn(usize) -> Work<'static> + Sync),
    sh: &Shared<'_>,
    pass: Pass,
) {
    par.for_each(n, &|i| {
        let mut p = parts[i].lock().unwrap_or_else(|e| e.into_inner());
        run_part(sh, &mut p, work(i), pass);
    });
}

/// Runs the typo pass over slices of candidate ids.
fn run_parts_ids<'c>(
    par: &dyn ParallelFor,
    parts: &[Mutex<Part>],
    n: usize,
    ids: &(dyn Fn(usize) -> &'c [u32] + Sync),
    sh: &Shared<'_>,
) {
    par.for_each(n, &|i| {
        let mut p = parts[i].lock().unwrap_or_else(|e| e.into_inner());
        run_part(sh, &mut p, Work::Ids(ids(i)), Pass::Typo);
    });
}

/// Gathers the keys of the first `n` parts into `merge`. With `add`, keeps what is already there.
fn collect(parts: &[Mutex<Part>], n: usize, merge: &mut Vec<u64>, typo: bool) {
    if !typo {
        merge.clear();
    }
    for p in parts.iter().take(n) {
        let p = p.lock().unwrap_or_else(|e| e.into_inner());
        merge.extend_from_slice(if typo { &p.typo_keys } else { &p.keys });
    }
}
