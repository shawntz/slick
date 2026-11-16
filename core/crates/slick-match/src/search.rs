//! Searching an arena: the bounded top-k scan, the typo pass, incremental narrowing and the
//! parallel scan for large corpora.

use crate::arena::{Arena, FLAG_MULTIBYTE};
use crate::bits::{self, Bound, Sc};
use crate::query::Query;
use crate::rank::{self, Field, MAX_LIFT};
use crate::score::{self, EXACT, PREFIX, SUBSEQUENCE, SUBSTRING, TYPO, TextScore, Unit, WORD_PREFIX};

/// Options for one search.
#[derive(Clone, Copy, Debug)]
pub struct Opts {
    /// How many hits to return.
    pub k: usize,
    /// Run the typo pass when the best strict hit is weaker than word-prefix (queries of 4 chars
    /// and up).
    pub typo: bool,
    /// Use the 64-bit presence-mask prefilter. Turn it off only to measure its gain.
    pub prefilter: bool,
    /// Paths only: when the basename does not match, accept a scattered match over the full path.
    pub path_fallback: bool,
    /// Skip full classification of matches that cannot enter the current top k. They still pass
    /// the gate, so the narrowing set stays exact.
    pub bound: bool,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            k: 50,
            typo: true,
            prefilter: true,
            path_fallback: false,
            bound: true,
        }
    }
}

/// One ranked item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hit {
    /// Item index in the arena.
    pub idx: u32,
    /// Rank in the layout of `rank`. Higher is better.
    pub rank: i32,
    /// The match string that produced the rank.
    pub field: Field,
}

impl Hit {
    /// The effective tier of the hit.
    #[inline(always)]
    pub fn tier(&self) -> u8 {
        rank::tier_of(self.rank)
    }
}

/// Outcome of evaluating one entry against the running top-k threshold.
pub enum Eval {
    /// Fails the strict gate.
    NoMatch,
    /// Passes the gate but cannot reach the threshold.
    Skipped,
    /// A full classification.
    Hit(TextScore),
}

/// Reusable buffers for single-threaded search. Keep one per caller; after the first few queries
/// a search allocates nothing.
#[derive(Default)]
pub struct Scratch {
    keys: Vec<u64>,
    /// Items that passed the strict gate in the last search (the narrowing set).
    pub matched: Vec<u32>,
    seen: Vec<u64>,
    chars: Vec<char>,
    /// One bit per item: the seeds visited before the main pass.
    visited: Vec<u64>,
    /// True when the last search ran the typo pass.
    pub typo_ran: bool,
}

/// Sort key: rank, then lower index first, with the field in the two low bits.
#[inline(always)]
fn key(rank: i32, idx: u32, field: Field) -> u64 {
    ((rank.clamp(0, (1 << 30) - 1) as u64) << 34) | (((u32::MAX - idx) as u64) << 2) | field as u64
}

#[inline(always)]
fn unkey(k: u64) -> Hit {
    Hit {
        idx: u32::MAX - (k >> 2) as u32,
        rank: (k >> 34) as i32,
        field: Field::from_bits((k & 3) as u8),
    }
}

/// Keeps the `k` largest keys, sorted descending (select_nth plus a sort of k).
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

/// A buffer of keys that drops everything below the running k-th best once it has been
/// compacted, so a 1-char query with thousands of matches never sorts more than a few hundred.
struct TopK<'a> {
    keys: &'a mut Vec<u64>,
    k: usize,
    compact_at: usize,
    thresh_key: u64,
    thresh: i32,
}

impl<'a> TopK<'a> {
    fn new(keys: &'a mut Vec<u64>, k: usize) -> Self {
        TopK {
            keys,
            k,
            compact_at: k.saturating_mul(2).max(64),
            thresh_key: 0,
            thresh: i32::MIN,
        }
    }

    #[inline(always)]
    fn push(&mut self, kk: u64) {
        if kk <= self.thresh_key {
            return;
        }
        self.keys.push(kk);
        if self.keys.len() >= self.compact_at {
            self.tighten();
        }
    }

    /// Drops every key below the k-th best and raises the threshold to it, once there are k.
    fn tighten(&mut self) {
        if self.keys.len() < self.k {
            return;
        }
        self.keys.select_nth_unstable_by(self.k - 1, |x, y| y.cmp(x));
        self.keys.truncate(self.k);
        self.thresh_key = self.keys[self.k - 1];
        self.thresh = unkey(self.thresh_key).rank;
    }
}

/// Bounded evaluation of entry `e`. `thresh` is the rank of the current k-th best hit
/// (`i32::MIN` while the buffer fills) and `lift` the item's within-tier lift. `reachable` says
/// the caller already found, at this threshold, that the entry may reach it.
#[inline(always)]
#[expect(
    clippy::too_many_arguments,
    reason = "hot inner loop; a parameter struct costs a copy per item"
)]
fn eval_entry(
    a: &Arena,
    e: usize,
    q: &Query,
    opts: &Opts,
    thresh: i32,
    lift: i32,
    bounds: &mut Bounds,
    chars: &mut Vec<char>,
    reachable: bool,
) -> Eval {
    if opts.prefilter && q.mask & !a.mask[e] != 0 {
        if a.paths && opts.path_fallback && q.mask & !a.pmask[e] == 0 {
            return path_fallback(a, e, q).map_or(Eval::NoMatch, Eval::Hit);
        }
        return Eval::NoMatch;
    }
    // An entry that cannot reach the running threshold is skipped before the bit path. Whether it
    // passes the gate is not known then, so it joins the narrowing set anyway: a superset of the
    // gated items narrows just as exactly, it only rescans a few more.
    if !reachable
        && opts.bound
        && thresh != i32::MIN
        && q.bounded
        && !a.paths
        && cannot_reach_out_of_line(a, e, q, lift, thresh)
    {
        return Eval::Skipped;
    }
    let st = a.start[e] as usize;
    let wb = st + a.win[e] as usize;
    let n = a.len[e] as usize - a.win[e] as usize;
    // The arena keeps PAD zero bytes after its last entry, so the 64-byte block at a window start
    // exists unless someone shrank the public `text` buffer; then the scalar path runs instead.
    if q.bn.ok
        && n > 0
        && n <= 64
        && let Some(block) = a.text.get(wb..wb + 64).and_then(|b| <&[u8; 64]>::try_from(b).ok())
    {
        let (floor, bound) = if opts.bound && thresh != i32::MIN {
            bounds.get(thresh, a.field(e), lift)
        } else {
            (0, Bound::NONE)
        };
        let r = bits::score_bits(&q.needle(), &q.bn, block, n, a.ws[e], floor, bound);
        return match r {
            Sc::Yes(t) => Eval::Hit(t),
            Sc::Below => Eval::Skipped,
            Sc::No if a.paths && opts.path_fallback => path_fallback(a, e, q).map_or(Eval::NoMatch, Eval::Hit),
            Sc::No => Eval::NoMatch,
        };
    }
    score_entry(a, e, q, opts, false, chars).map_or(Eval::NoMatch, Eval::Hit)
}

/// True when entry `e` cannot reach rank `thresh` for a bounded query (ASCII, one token), judged
/// from what the arena keeps per entry, without the bit path. It walks the tiers from the top and
/// stops at the first one the entry could reach. Each tier needs:
///
/// - exact or a literal prefix: the window starts with the query;
/// - prefix by a complete word cover: the first word starts with the query's first char and the
///   window has at most as many words as the query has chars;
/// - prefix by a whole word, when the query asks for it: the query's first char starts a word,
///   every adjacent pair of the query is in the window's pair mask and, for a query of letters
///   and digits, its span bit is in the window's span mask;
/// - word-prefix: the first char starts a word, and each later char either starts a word or
///   follows the char before it; a char equal to the first one that starts a word needs a second
///   word with that initial;
/// - substring: every adjacent pair of the query is in the window's pair mask.
///
/// Anything else is at most a subsequence. Qualities are the tier's best for this window length
/// (see `score`), so the bound never skips an entry that could reach `thresh`.
#[inline(always)]
fn cannot_reach(a: &Arena, e: usize, q: &Query, lift: i32, thresh: i32) -> bool {
    let field = a.field(e);
    // The text score (tier * TIER_GAP + quality, on the effective tier) the entry would need.
    let need = thresh - rank::FIELD_BONUS[field as usize] - lift.clamp(0, MAX_LIFT);
    let score = |tier: u8, quality: i32| match rank::effective_tier(tier, field) {
        Some(t) => rank::TIER_GAP * t as i32 + quality,
        None => i32::MIN,
    };
    if score(EXACT, 999) < need {
        return true;
    }
    // The checks below go from the top tier down and load as little as each one needs.
    let full = q.full.as_slice();
    let m = full.len();
    let q0 = full[0];
    let window = || {
        let n = a.len[e] as usize - a.win[e] as usize;
        (n, (n as i32 - m as i32).clamp(0, 60))
    };
    // A substring needs every adjacent pair of the query in the window; anything else is at most
    // a scattered match.
    let substring_or_less = |extra: i32| {
        if score(SUBSTRING, 800) < need {
            return true;
        }
        if m == 1 || a.pairs[e] & q.pairs == q.pairs {
            return score(SUBSTRING, 800 - 3 * extra) < need;
        }
        if field == Field::Keyword {
            return true;
        }
        let m = m.min(64) as i32;
        score(SUBSEQUENCE, 500 + 25 * m + 15 * (m - 1) - 2 * extra) < need
    };
    // Every tier above substring needs the query's first char to start a word. For a letter or a
    // digit, `initials` says whether it does. One char queries leave sooner below.
    if m >= 2 && q0.is_ascii_alphanumeric() && a.initials[e] & q.bit0 == 0 {
        return substring_or_less(window().1);
    }
    let (head, lead) = (a.head[e] == q0, a.lead[e] == q0);
    if head || lead {
        let (n, extra) = window();
        let st = a.start[e] as usize + a.win[e] as usize;
        let literal = head && n >= m && (1..m).all(|i| a.text[st + i] == full[i]);
        if literal && n == m {
            return score(EXACT, 999) < need;
        }
        let ws = if n >= 64 { a.ws[e] } else { a.ws[e] & ((1u64 << n) - 1) };
        if literal || (lead && ws.count_ones() as usize <= m) {
            return score(PREFIX, 990 - 6 * extra) < need;
        }
    }
    // A query equal to a whole word ranks in the prefix tier, less 40 for each word before that
    // one (see `score::whole_word_quality`). It needs the first char to start a word, every
    // adjacent pair of the query in the window and, for a query of letters and digits, its span
    // bit in the window's span mask.
    if q.whole_words
        && m >= 2
        && a.initials[e] & q.bit0 != 0
        && a.pairs[e] & q.pairs == q.pairs
        && (q.span == 0 || a.spans[e] & q.span != 0)
    {
        if score(PREFIX, 960) < need {
            return true;
        }
        let (_, extra) = window();
        let word = first_byte_at(a.heads[e], q0).min(5) as i32;
        return score(PREFIX, 960 - 6 * extra - 40 * word) < need;
    }
    if score(WORD_PREFIX, 940) < need {
        return true;
    }
    // Each word before the first one the query's first char starts costs 40 (see
    // `score::word_prefix_quality`). A zero byte in `heads` past the last word never equals an
    // ASCII query char, so a first char that starts none of the first eight words costs 200.
    let first_word = 940 - 40 * first_byte_at(a.heads[e], q0).min(5) as i32;
    if score(WORD_PREFIX, first_word) < need {
        return true;
    }
    let (_, extra) = window();
    if a.initials[e] & q.bit0 != 0 && links_hold(a, e, q) {
        return score(WORD_PREFIX, first_word - 3 * extra) < need;
    }
    substring_or_less(extra)
}

/// From this threshold up, a title whose words do not start with a bounded query's first char
/// cannot enter the top k. Every tier from word-prefix up needs that char at a word start, a
/// one-token query never matches unordered, and the best substring rank of a title, with its
/// field bonus, full quality and full lift, stays below this unordered-tier rank.
const WORD_START_THRESH: i32 = rank::TIER_GAP * score::UNORDERED as i32;

/// The index of the first byte of `x` that equals `b`, or 8 when none does.
#[inline(always)]
fn first_byte_at(x: u64, b: u8) -> u32 {
    const LO: u64 = 0x0101_0101_0101_0101;
    const HI: u64 = 0x8080_8080_8080_8080;
    let y = x ^ (LO * b as u64);
    // Bytes of `y` that are zero, exactly up to the first one; that is all this needs.
    let zero = y.wrapping_sub(LO) & !y & HI;
    zero.trailing_zeros() / 8
}

/// Whether the bound is paying for itself at the current threshold. A low threshold, such as one
/// in the subsequence tier, lets almost every entry through, and then the check only adds work.
/// After `TRIES` checks in one tier of the threshold that skipped fewer than a quarter of the
/// entries, the scan stops checking until the threshold reaches a higher tier.
#[derive(Default)]
struct BoundGate {
    tier: u8,
    tries: u32,
    skips: u32,
}

impl BoundGate {
    const TRIES: u32 = 32;

    #[inline(always)]
    fn worth_it(&mut self, thresh: i32) -> bool {
        let tier = rank::tier_of(thresh);
        if tier != self.tier {
            *self = BoundGate {
                tier,
                tries: 0,
                skips: 0,
            };
        }
        self.tries < Self::TRIES || self.skips * 4 >= self.tries
    }

    #[inline(always)]
    fn count(&mut self, skipped: bool) {
        self.tries += 1;
        self.skips += skipped as u32;
    }
}

/// [`cannot_reach`] as a call, for `eval_entry`: inlined there it would bloat the path that
/// rejects an entry by its mask, which is most of the work for a selective query.
#[inline(never)]
fn cannot_reach_out_of_line(a: &Arena, e: usize, q: &Query, lift: i32, thresh: i32) -> bool {
    cannot_reach(a, e, q, lift, thresh)
}

/// True when every checked char of a bounded query can continue a word-prefix match of entry `e`:
/// it starts a word, or it follows the char before it. See `Query::link_bits`.
#[inline(always)]
fn links_hold(a: &Arena, e: usize, q: &Query) -> bool {
    let (initials, initials2, pairs) = (a.initials[e], a.initials2[e], a.pairs[e]);
    (0..q.links as usize).all(|j| {
        let starts = if (q.link_same >> j) & 1 == 1 {
            initials2
        } else {
            initials
        };
        starts & q.link_bits[j] != 0 || pairs & q.link_pairs[j] != 0
    })
}

/// An upper bound on the typo rank of entry `e`: one edit against a word prefix scores at most
/// 600 minus the length penalty (see `score::typo`).
#[inline(always)]
fn typo_bound(a: &Arena, e: usize, q: &Query, lift: i32) -> Option<i32> {
    let n = a.len[e] as i32 - a.win[e] as i32;
    let extra = (n - q.len_chars() as i32).clamp(0, 60);
    rank::rank(TextScore::new(TYPO, 600 - 3 * extra), a.field(e), lift)
}

/// The tier floor and rank bound of the last entry, reused while the threshold, field and lift
/// stay the same (they usually do from one item to the next).
struct Bounds {
    key: (i32, Field, i32),
    value: (u8, Bound),
}

impl Bounds {
    fn new() -> Bounds {
        Bounds {
            key: (i32::MIN, Field::Title, 0),
            value: (0, Bound::NONE),
        }
    }

    #[inline(always)]
    fn get(&mut self, thresh: i32, field: Field, lift: i32) -> (u8, Bound) {
        if self.key != (thresh, field, lift) {
            let bound = Bound {
                thresh,
                word_prefix_base: rank::word_prefix_base(field, lift),
            };
            self.key = (thresh, field, lift);
            self.value = (rank::floor_tier(thresh, field, lift), bound);
        }
        self.value
    }
}

/// Scores entry `e` with the scalar reference: the strict tiers, or only the typo tier when
/// `typo_mode`. `chars` is scratch space for non-ASCII queries.
#[inline]
pub fn score_entry(
    a: &Arena,
    e: usize,
    q: &Query,
    opts: &Opts,
    typo_mode: bool,
    chars: &mut Vec<char>,
) -> Option<TextScore> {
    let qm = q.mask;
    if opts.prefilter {
        let m = a.mask[e];
        if typo_mode {
            // One edit: at most one query char may be missing, and the typo must start on a word
            // whose initial is q[0] or q[1].
            if (qm & !m).count_ones() > 1 || a.initials[e] & q.typo_bits == 0 {
                return None;
            }
        } else if qm & !m != 0 {
            if !(a.paths && opts.path_fallback && qm & !a.pmask[e] == 0) {
                return None;
            }
            return path_fallback(a, e, q);
        }
    }
    let r = score_window(a, e, q, typo_mode, chars);
    if r.is_none() && a.paths && opts.path_fallback && !typo_mode {
        return path_fallback(a, e, q);
    }
    r
}

#[inline]
fn score_window(a: &Arena, e: usize, q: &Query, typo_mode: bool, chars: &mut Vec<char>) -> Option<TextScore> {
    let w = a.window(e);
    let ws = a.ws[e];
    if q.ascii {
        return score::score::<u8, false>(&q.needle(), w, ws, typo_mode, None);
    }
    if a.flags[e] & FLAG_MULTIBYTE == 0 {
        return None; // a non-ASCII needle cannot match an all-ASCII entry
    }
    let cws = decode_window(w, ws, chars);
    score::score::<char, false>(&q.needle_chars(), chars, cws, typo_mode, None)
}

/// A scattered match anywhere in the full path, below every basename match.
#[cold]
fn path_fallback(a: &Arena, e: usize, q: &Query) -> Option<TextScore> {
    let s = a.item(e);
    if q.ascii && score::is_subsequence(&q.ns, s) {
        let n = s.len() as i32;
        return Some(TextScore::new(SUBSEQUENCE, 300 - n.min(300)));
    }
    None
}

/// Decodes a folded UTF-8 window into `chars`, remapping the byte-indexed word-start bits to char
/// indices.
pub(crate) fn decode_window(w: &[u8], ws: u64, chars: &mut Vec<char>) -> u64 {
    chars.clear();
    let s = std::str::from_utf8(w).unwrap_or("");
    let mut cws = 0u64;
    for (ci, (bi, c)) in s.char_indices().enumerate() {
        let start = if bi < 64 {
            (ws >> bi) & 1 == 1
        } else {
            chars.last().is_some_and(|p: &char| p.is_sep()) && !c.is_sep()
        };
        if start && ci < 64 {
            cws |= 1u64 << ci;
        }
        chars.push(c);
    }
    cws
}

/// The outcome for one item: its best entry, or whether any entry passed the gate.
enum ItemEval {
    NoMatch,
    Gated,
    Hit(i32, Field),
}

/// Evaluates every entry of item `i`. `reachable` says the caller already found, at this
/// threshold, that the item's only entry may reach it.
#[inline(always)]
#[expect(
    clippy::too_many_arguments,
    reason = "hot inner loop; a parameter struct costs a copy per item"
)]
fn eval_item(
    a: &Arena,
    q: &Query,
    opts: &Opts,
    i: usize,
    lift: i32,
    thresh: i32,
    bounds: &mut Bounds,
    chars: &mut Vec<char>,
    reachable: bool,
) -> ItemEval {
    let range = a.entry_range(i);
    if range.len() == 1 {
        let e = range.start;
        return match eval_entry(a, e, q, opts, thresh, lift, bounds, chars, reachable) {
            Eval::NoMatch => ItemEval::NoMatch,
            Eval::Skipped => ItemEval::Gated,
            Eval::Hit(t) => {
                let field = a.field(e);
                match rank::rank(t, field, lift) {
                    Some(r) => ItemEval::Hit(r, field),
                    None => ItemEval::Gated,
                }
            }
        };
    }
    let mut best = i32::MIN;
    let mut best_field = Field::Title;
    let mut gated = false;
    for e in a.entry_range(i) {
        match eval_entry(a, e, q, opts, thresh, lift, bounds, chars, false) {
            Eval::NoMatch => {}
            Eval::Skipped => gated = true,
            Eval::Hit(t) => {
                let field = a.field(e);
                match rank::rank(t, field, lift) {
                    Some(r) if r > best => {
                        best = r;
                        best_field = field;
                    }
                    Some(_) => {}
                    // A keyword subsequence passes the gate but never ranks.
                    None => gated = true,
                }
            }
        }
    }
    if best != i32::MIN {
        ItemEval::Hit(best, best_field)
    } else if gated {
        ItemEval::Gated
    } else {
        ItemEval::NoMatch
    }
}

/// The typo rank of entry `e` of item `i` when it is a title or alias whose typo rank can reach
/// `thresh`. The caller has applied the typo prefilter. Out of line: few entries get here.
#[inline(never)]
fn typo_entry(
    a: &Arena,
    q: &Query,
    opts: &Opts,
    e: usize,
    lift: i32,
    thresh: i32,
    chars: &mut Vec<char>,
) -> Option<(i32, Field)> {
    let field = a.field(e);
    if field == Field::Keyword
        || (thresh != i32::MIN && !a.paths && typo_bound(a, e, q, lift).is_none_or(|r| r < thresh))
    {
        return None;
    }
    score_entry(a, e, q, opts, true, chars)
        .and_then(|t| rank::rank(t, field, lift))
        .map(|r| (r, field))
}

/// The best typo hit among an item's titles and aliases. Entries whose typo rank cannot reach
/// `thresh` are not scored.
#[inline]
fn typo_item(
    a: &Arena,
    q: &Query,
    opts: &Opts,
    i: usize,
    lift: Option<&[i32]>,
    thresh: i32,
    chars: &mut Vec<char>,
) -> Option<(i32, Field)> {
    let mut best: Option<(i32, Field)> = None;
    for e in a.entry_range(i) {
        // The typo prefilter: at most one query char missing, and a word that starts with the
        // first or second char. Almost every entry stops here.
        if opts.prefilter && ((q.mask & !a.mask[e]).count_ones() > 1 || a.initials[e] & q.typo_bits == 0) {
            continue;
        }
        if let Some((r, field)) = typo_entry(a, q, opts, e, lift_of(lift, i), thresh, chars)
            && best.is_none_or(|(b, _)| r > b)
        {
            best = Some((r, field));
        }
    }
    best
}

/// The rank of the `k`-th best key in `keys`, or `i32::MIN` when there are fewer. Reorders `keys`.
fn kth_rank(keys: &mut [u64], k: usize) -> i32 {
    if k == 0 || keys.len() < k {
        return i32::MIN;
    }
    keys.select_nth_unstable_by(k - 1, |x, y| y.cmp(x));
    unkey(keys[k - 1]).rank
}

#[inline(always)]
fn lift_of(lift: Option<&[i32]>, i: usize) -> i32 {
    lift.map_or(0, |l| l.get(i).copied().unwrap_or(0).clamp(0, MAX_LIFT))
}

/// True when a search whose best strict hit has rank `best` should run the typo pass.
#[inline(always)]
fn wants_typo(opts: &Opts, q: &Query, best: i32) -> bool {
    opts.typo && q.len_chars() >= 4 && (best == i32::MIN || rank::tier_of(best) < WORD_PREFIX)
}

/// Searches every item (`cands` None) or a candidate list, writing the top `opts.k` hits into
/// `out`, best first.
///
/// `lift[i]` is item i's within-tier lift (see `rank`). Items that pass the strict gate are left
/// in `scratch.matched`, which is the candidate list for a query that extends this one. It may
/// also hold items the bound skipped before their gate was known; a superset narrows exactly too.
pub fn search(
    a: &Arena,
    q: &Query,
    opts: &Opts,
    cands: Option<&[u32]>,
    lift: Option<&[i32]>,
    scratch: &mut Scratch,
    out: &mut Vec<Hit>,
) {
    search_seeded(a, q, opts, cands, lift, &[], scratch, out);
}

/// [`search`], visiting the items in `seeds` first. Seeds are items likely to rank high, such as
/// those with the largest lifts: they set the running threshold at once, so the bound skips most
/// of the other items before the bit path. The result does not depend on the seeds; each item is
/// visited once, and seeds outside `cands` or the arena are harmless.
#[expect(
    clippy::too_many_arguments,
    reason = "the seeded form of `search`, which keeps the short signature"
)]
pub fn search_seeded(
    a: &Arena,
    q: &Query,
    opts: &Opts,
    cands: Option<&[u32]>,
    lift: Option<&[i32]>,
    seeds: &[u32],
    scratch: &mut Scratch,
    out: &mut Vec<Hit>,
) {
    out.clear();
    let Scratch {
        keys,
        matched,
        seen,
        chars,
        visited,
        typo_ran,
    } = scratch;
    keys.clear();
    matched.clear();
    *typo_ran = false;
    if q.is_empty() || a.is_empty() {
        return;
    }
    let k = opts.k.max(1);
    let mut top = TopK::new(keys, k);
    let mut best = i32::MIN;
    let mut bounds = Bounds::new();
    let bounded = opts.bound && q.bounded && !a.paths;
    // The plain mask prefilter applies: no path fallback to a wider mask.
    let plain_mask = opts.prefilter && !(a.paths && opts.path_fallback);
    let mut gate = BoundGate::default();
    // The query starts with a letter or digit, whose word starts `Arena::initials` records.
    let first_alnum = bounded && q.full.first().is_some_and(u8::is_ascii_alphanumeric);
    // The caller passes the item's entries, having rejected a single entry that fails the mask.
    let mut visit = |i: usize, range: std::ops::Range<usize>, top: &mut TopK<'_>| {
        // Most of the remaining single-entry items cannot reach a high threshold: settle those
        // here, before the general evaluation. A single entry is a title.
        let l = lift_of(lift, i);
        let thresh = if opts.bound { top.thresh } else { i32::MIN };
        let mut reachable = false;
        if bounded && thresh != i32::MIN && range.len() == 1 {
            // One load settles a title none of whose words starts with the query's first char.
            if first_alnum && thresh >= WORD_START_THRESH && a.initials[range.start] & q.bit0 == 0 {
                matched.push(i as u32);
                return;
            }
            if gate.worth_it(thresh) {
                let skip = cannot_reach(a, range.start, q, l, thresh);
                gate.count(skip);
                if skip {
                    matched.push(i as u32);
                    return;
                }
                reachable = true;
            }
        }
        match eval_item(a, q, opts, i, l, thresh, &mut bounds, chars, reachable) {
            ItemEval::NoMatch => {}
            ItemEval::Gated => matched.push(i as u32),
            ItemEval::Hit(r, field) => {
                matched.push(i as u32);
                best = best.max(r);
                top.push(key(r, i as u32, field));
            }
        }
    };
    // Most items of a short or selective query fail the mask prefilter. Checking it here keeps that
    // path to a few loads; `visit` checks it again for the items that pass.
    // Most items have one entry, and most entries of a short or selective query fail the mask: the
    // loops reject those before calling `visit`.
    let pass = |i: usize| {
        let range = a.entry_range(i);
        let out = plain_mask && range.len() == 1 && q.mask & !a.mask[range.start] != 0;
        (!out).then_some(range)
    };
    if seeds.is_empty() {
        match cands {
            None => {
                for i in 0..a.len() {
                    if let Some(range) = pass(i) {
                        visit(i, range, &mut top);
                    }
                }
            }
            Some(c) => {
                for &i in c {
                    if let Some(range) = pass(i as usize) {
                        visit(i as usize, range, &mut top);
                    }
                }
            }
        }
    } else {
        let words = a.len().div_ceil(64);
        if visited.len() < words {
            visited.resize(words, 0);
        }
        for &i in seeds {
            let (w, b) = ((i / 64) as usize, i % 64);
            if (i as usize) < a.len() && (visited[w] >> b) & 1 == 0 {
                visited[w] |= 1u64 << b;
                if let Some(range) = pass(i as usize) {
                    visit(i as usize, range, &mut top);
                }
            }
        }
        top.tighten();
        let fresh = |i: usize| (visited[i / 64] >> (i % 64)) & 1 == 0;
        let all = cands.map_or(a.len(), <[u32]>::len);
        for n in 0..all {
            let i = cands.map_or(n, |c| c[n] as usize);
            if fresh(i)
                && let Some(range) = pass(i)
            {
                visit(i, range, &mut top);
            }
        }
        for &i in seeds {
            if (i as usize) < a.len() {
                visited[(i / 64) as usize] &= !(1u64 << (i % 64));
            }
        }
    }
    let typo = wants_typo(opts, q, best);
    *typo_ran = typo;
    if typo {
        // Each item holds at most one strict key, so a typo hit below the k-th best strict rank
        // can never reach the top k.
        let thresh = if opts.bound { kth_rank(keys, k) } else { i32::MIN };
        for i in 0..a.len() {
            if let Some((r, field)) = typo_item(a, q, opts, i, lift, thresh, chars) {
                keys.push(key(r, i as u32, field));
            }
        }
    }
    finish(keys, k, typo, a.len(), seen, out);
}

/// Turns the collected keys into hits. After a typo pass an item can hold two keys (its strict
/// match and its typo match), so the best 2k keys are deduplicated down to k items.
fn finish(keys: &mut Vec<u64>, k: usize, dedup: bool, n_items: usize, seen: &mut Vec<u64>, out: &mut Vec<Hit>) {
    if !dedup {
        top_k(keys, k);
        out.extend(keys.iter().map(|&kk| unkey(kk)));
        return;
    }
    top_k(keys, k.saturating_mul(2));
    let words = n_items.div_ceil(64);
    if seen.len() < words {
        seen.resize(words, 0);
    }
    for &kk in keys.iter() {
        let h = unkey(kk);
        let (w, b) = ((h.idx / 64) as usize, h.idx % 64);
        if (seen[w] >> b) & 1 == 0 {
            seen[w] |= 1u64 << b;
            out.push(h);
            if out.len() == k {
                break;
            }
        }
    }
    for h in out.iter() {
        seen[(h.idx / 64) as usize] &= !(1u64 << (h.idx % 64));
    }
}

/// Deepest narrowing stack a session keeps. Longer queries narrow from the deepest level.
const MAX_DEPTH: usize = 64;

struct Level {
    query: Query,
    start: usize,
    end: usize,
}

/// Incremental narrowing: when a query extends the previous one, only the previous strict match
/// set is scored again. Backspace is served from a stack of earlier match sets.
///
/// Call [`Session::reset`] whenever the arena changes and when the launcher is summoned.
#[derive(Default)]
pub struct Session {
    levels: Vec<Level>,
    depth: usize,
    pool: Vec<u32>,
    scratch: Scratch,
    last_scanned: usize,
}

impl Session {
    /// Forgets every earlier query.
    pub fn reset(&mut self) {
        self.depth = 0;
        self.pool.clear();
    }

    /// How many items the last search scored in its strict pass.
    pub fn last_scanned(&self) -> usize {
        self.last_scanned
    }

    /// True when the last search ran the typo pass. A caller scoring extra items directly must
    /// then include their typo matches to rank them the same way.
    pub fn typo_ran(&self) -> bool {
        self.scratch.typo_ran
    }

    /// Searches like [`search`], narrowing from the deepest earlier query that `q` extends.
    pub fn search(&mut self, a: &Arena, q: &Query, opts: &Opts, lift: Option<&[i32]>, out: &mut Vec<Hit>) {
        self.search_seeded(a, q, opts, lift, &[], out);
    }

    /// Searches like [`search_seeded`], narrowing from the deepest earlier query that `q` extends.
    pub fn search_seeded(
        &mut self,
        a: &Arena,
        q: &Query,
        opts: &Opts,
        lift: Option<&[i32]>,
        seeds: &[u32],
        out: &mut Vec<Hit>,
    ) {
        while self.depth > 0 && !q.narrows(&self.levels[self.depth - 1].query) {
            self.depth -= 1;
            self.pool.truncate(self.levels[self.depth].start);
        }
        let cands = match self.depth {
            0 => None,
            d => Some(&self.pool[self.levels[d - 1].start..self.levels[d - 1].end]),
        };
        self.last_scanned = cands.map_or(a.len(), |c| c.len());
        search_seeded(a, q, opts, cands, lift, seeds, &mut self.scratch, out);
        let same = self.depth > 0 && self.levels[self.depth - 1].query.full == q.full;
        if q.is_empty() || same || self.depth == MAX_DEPTH {
            return;
        }
        if self.depth == self.levels.len() {
            self.levels.push(Level {
                query: Query::default(),
                start: 0,
                end: 0,
            });
        }
        let start = self.pool.len();
        self.pool.extend_from_slice(&self.scratch.matched);
        let level = &mut self.levels[self.depth];
        level.query.copy_from(q);
        level.start = start;
        level.end = self.pool.len();
        self.depth += 1;
    }
}

/// Parallel search over contiguous chunks of `chunk` items. Each worker keeps its own top k; the
/// results are merged. Allocates; meant for large corpora such as file indexes.
#[cfg(feature = "parallel")]
pub fn search_par(a: &Arena, q: &Query, opts: &Opts, chunk: usize, lift: Option<&[i32]>) -> Vec<Hit> {
    use rayon::prelude::*;
    let mut out = Vec::new();
    if q.is_empty() || a.is_empty() {
        return out;
    }
    let n = a.len();
    let chunk = chunk.max(1);
    let k = opts.k.max(1);
    let (mut keys, best) = (0..n.div_ceil(chunk))
        .into_par_iter()
        .map(|c| {
            let mut keys = Vec::with_capacity(8 * k);
            let mut chars = Vec::new();
            let mut bounds = Bounds::new();
            let mut top = TopK::new(&mut keys, k);
            let mut best = i32::MIN;
            for i in c * chunk..((c + 1) * chunk).min(n) {
                let thresh = if opts.bound { top.thresh } else { i32::MIN };
                if let ItemEval::Hit(r, field) =
                    eval_item(a, q, opts, i, lift_of(lift, i), thresh, &mut bounds, &mut chars, false)
                {
                    best = best.max(r);
                    top.push(key(r, i as u32, field));
                }
            }
            (keys, best)
        })
        .reduce(
            || (Vec::new(), i32::MIN),
            |(mut x, bx), (y, by)| {
                x.extend_from_slice(&y);
                top_k(&mut x, k);
                (x, bx.max(by))
            },
        );
    let typo = wants_typo(opts, q, best);
    if typo {
        let typos: Vec<u64> = (0..n)
            .into_par_iter()
            .map_init(Vec::new, |chars, i| {
                typo_item(a, q, opts, i, lift, i32::MIN, chars).map(|(r, f)| key(r, i as u32, f))
            })
            .flatten()
            .collect();
        keys.extend(typos);
    }
    let mut seen = Vec::new();
    finish(&mut keys, k, typo, n, &mut seen, &mut out);
    out
}
