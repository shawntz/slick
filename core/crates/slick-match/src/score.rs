//! Tiered text scorer: the scalar reference that every fast path is tested against.
//!
//! Tiers, strongest first:
//!
//! | tier | name        | meaning                                                            |
//! |------|-------------|--------------------------------------------------------------------|
//! | 6    | exact       | folded text equals the folded query                                |
//! | 5    | prefix      | text starts with the query, or the query covers every word in order ("vsc", "vs code", "ss") |
//! | 4    | word-prefix | in-order prefixes of words, words may be skipped ("dark", "tdm"); the humps of a camelCase word count as one whole word ("gh" for GitHub) |
//! | 3    | unordered   | every query token starts a distinct word, in any order ("mode dark") |
//! | 2    | substring   | contiguous, mid-word ("fari" for Safari)                           |
//! | 1    | typo        | one Damerau edit against a word prefix ("calender" for Calendar)   |
//! | 0    | subsequence | scattered, fzf-v1 window scoring                                   |
//!
//! The strict pass computes every tier except typo. Typo runs as a separate pass (see
//! `search::search`), because it needs every item, not only the strict matches. Within a tier,
//! `quality` (0..=999) orders by compactness, word-start hits, position and length.

/// Unit of text being matched: a folded byte (ASCII fast path) or a char (Unicode needle path).
pub trait Unit: Copy + Eq {
    /// True for separators: anything that is not a letter, digit or ideograph.
    fn is_sep(self) -> bool;
}

impl Unit for u8 {
    #[inline(always)]
    fn is_sep(self) -> bool {
        self < 0x80 && !self.is_ascii_alphanumeric()
    }
}

impl Unit for char {
    #[inline(always)]
    fn is_sep(self) -> bool {
        matches!(crate::fold::class_of(self), crate::fold::Class::Sep)
    }
}

/// Most words considered per window. Titles and basenames rarely have more.
const MAXW: usize = 32;

/// Scattered subsequence.
pub const SUBSEQUENCE: u8 = 0;
/// One edit away from a word prefix.
pub const TYPO: u8 = 1;
/// Contiguous, mid-word.
pub const SUBSTRING: u8 = 2;
/// Every token starts a distinct word, any order.
pub const UNORDERED: u8 = 3;
/// In-order word prefixes, words may be skipped.
pub const WORD_PREFIX: u8 = 4;
/// Literal prefix or complete in-order cover.
pub const PREFIX: u8 = 5;
/// Folded text equals the folded query.
pub const EXACT: u8 = 6;
/// Tier names indexed by tier, for reports and test messages.
pub const TIER_NAMES: [&str; 7] = [
    "subsequence",
    "typo",
    "substring",
    "unordered",
    "word-prefix",
    "prefix",
    "exact",
];

/// A text match: its tier and its quality inside the tier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TextScore {
    /// One of the tier constants above.
    pub tier: u8,
    /// 0..=999, higher is better.
    pub quality: u16,
}

impl TextScore {
    /// Builds a score, clamping `quality` to 0..=999.
    #[inline(always)]
    pub fn new(tier: u8, quality: i32) -> Self {
        TextScore {
            tier,
            quality: quality.clamp(0, 999) as u16,
        }
    }
}

/// PREFIX-tier quality shared by literal prefixes and complete word-prefix covers. Shorter texts
/// win; a prefix that stops mid-word loses 40; an acronym cover loses 30; touching every word of
/// the text gains 30 ("vs code" beats "VS Code: Open Workspace", "sa" puts Safari over "Screen Art").
#[inline(always)]
pub fn prefix_quality(n: usize, fm: usize, ends_mid: bool, all_words: bool, acronym: bool) -> i32 {
    960 - 6 * (n.saturating_sub(fm) as i32).min(60) - if ends_mid { 40 } else { 0 } - if acronym { 30 } else { 0 }
        + if all_words { 30 } else { 0 }
}

/// WORD_PREFIX-tier quality, shared by the scalar and bit paths. For a given first word index
/// `fw` it is at most `940 - 40*fw - 3*extra`, which the bit path uses as a bound.
#[inline(always)]
pub fn word_prefix_quality(fw: u8, sk: u8, sg: u8, extra: i32, adj: i16) -> i32 {
    900 - 40 * (fw as i32).min(5) - 40 * (sk as i32).min(5) - 15 * (sg as i32 - 1).min(10) - 3 * extra.min(60)
        + adj as i32
}

/// Substring-tier quality for a match at position `p` with `extra` unmatched units.
#[inline(always)]
pub fn substring_quality(p: i32, extra: i32) -> i32 {
    800 - 8 * p.min(50) - 3 * extra.min(60)
}

/// Unordered-tier quality when the last word used is `worst`.
#[inline(always)]
pub fn unordered_quality(worst: i32, extra: i32) -> i32 {
    800 - 40 * worst.min(8) - 3 * extra.min(60)
}

/// Does any word start at a position >= `from`? (a literal prefix that touches every word)
#[inline(always)]
fn word_start_at_or_after<T: Unit>(s: &[T], ws: u64, from: usize) -> bool {
    let n = s.len();
    if from < 64 && (ws >> from) != 0 && (ws >> from).trailing_zeros() as usize + from < n {
        return true;
    }
    let mut i = from.max(64);
    while i < n {
        if s[i - 1].is_sep() && !s[i].is_sep() {
            return true;
        }
        i += 1;
    }
    false
}

/// A folded query as the scorer sees it. `full` has single spaces between tokens, `ns` has none.
pub struct Needle<'a, T: Unit> {
    /// Folded query with single spaces between tokens.
    pub full: &'a [T],
    /// Folded query without spaces.
    pub ns: &'a [T],
    /// Token ranges into `full`.
    pub tokens: &'a [(u16, u16)],
}

/// Word-start oracle over the haystack: the 64-bit window, then the separator rule beyond it.
#[inline(always)]
fn is_ws<T: Unit>(s: &[T], ws: u64, i: usize) -> bool {
    if i < 64 {
        (ws >> i) & 1 == 1
    } else {
        s[i - 1].is_sep() && !s[i].is_sep()
    }
}

/// A word start that continues a token without a separator: a camelCase hump or an ideograph.
#[inline(always)]
fn is_hump<T: Unit>(s: &[T], w: usize) -> bool {
    w > 0 && !s[w - 1].is_sep()
}

#[inline]
fn collect_words<T: Unit>(s: &[T], ws: u64, out: &mut [u16; MAXW]) -> usize {
    let mut n = 0;
    let mut bits = ws;
    while bits != 0 && n < MAXW {
        let i = bits.trailing_zeros() as usize;
        if i >= s.len() {
            break;
        }
        out[n] = i as u16;
        n += 1;
        bits &= bits - 1;
    }
    let mut i = 64;
    while i < s.len() && n < MAXW {
        if s[i - 1].is_sep() && !s[i].is_sep() {
            out[n] = i as u16;
            n += 1;
        }
        i += 1;
    }
    n
}

/// True when `q` occurs in `s` as a (scattered) subsequence.
#[inline(always)]
pub fn is_subsequence<T: Unit>(q: &[T], s: &[T]) -> bool {
    let m = q.len();
    if m == 0 {
        return true;
    }
    if m > s.len() {
        return false;
    }
    let mut qi = 0;
    let mut want = q[0];
    for &b in s {
        if b == want {
            qi += 1;
            if qi == m {
                return true;
            }
            want = q[qi];
        }
    }
    false
}

#[inline]
fn find<T: Unit>(s: &[T], q: &[T]) -> Option<usize> {
    let m = q.len();
    if m == 0 || m > s.len() {
        return None;
    }
    let first = q[0];
    let last = s.len() - m;
    let mut i = 0;
    while i <= last {
        if s[i] == first {
            let mut k = 1;
            while k < m && s[i + k] == q[k] {
                k += 1;
            }
            if k == m {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// Result of an in-order word-prefix segmentation.
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub struct Seg {
    /// One past the last matched unit.
    pub end: usize,
    /// Index of the first word used.
    pub first_word: u8,
    /// Words skipped between used words.
    pub skipped: u8,
    /// Segments, with the humps of a fully abbreviated camelCase word counted as one.
    pub segments: u8,
    /// Every word used from the first, none skipped.
    pub covers_all: bool,
    /// +40 when every segment ends on a word end; -50 per non-final multi-char segment that stops
    /// mid-word (so "cod|e" does not beat whole-word matches, while "v|s|c" acronyms stay cheap).
    pub adj: i16,
    /// The last segment stops inside a word.
    pub ends_mid: bool,
}

struct SegCtx<'a, T: Unit> {
    q: &'a [T],
    s: &'a [T],
    words: &'a [u16],
    budget: u32,
    /// (word index, units taken) per segment depth of the most recent successful path.
    path: [(u8, u8); 16],
}

impl<T: Unit> SegCtx<'_, T> {
    /// Consumes q[qi..] starting at word index >= wi. Returns (segments, skipped, last word touched).
    /// With `adjacent`, the segment must start at word `wi` itself: a run of two or more units that
    /// stops mid-word ("act|ivity") may continue only on the next word ("act|mon"), never after a
    /// skip ("mus|ic Manage C|hannels" for "musc").
    fn dfs(&mut self, qi: usize, wi: usize, depth: usize, started: bool, adjacent: bool) -> Option<(u8, u8, u8)> {
        if depth >= 16 {
            return None;
        }
        let m = self.q.len();
        let nw = self.words.len();
        let last_word = if adjacent { (wi + 1).min(nw) } else { nw };
        let mut j = wi;
        while j < last_word {
            if self.budget == 0 {
                return None;
            }
            self.budget -= 1;
            let w = self.words[j] as usize;
            if self.s[w] == self.q[qi] {
                let mut l = 1;
                while qi + l < m && w + l < self.s.len() && self.s[w + l] == self.q[qi + l] {
                    l += 1;
                }
                let skipped_here = if started { (j - wi) as u8 } else { 0 };
                let mut take = l;
                while take >= 1 {
                    let qi2 = qi + take;
                    self.path[depth] = (j as u8, take as u8);
                    let end = w + take;
                    // first word strictly after the consumed run
                    let mut j2 = j + 1;
                    while j2 < nw && (self.words[j2] as usize) < end {
                        j2 += 1;
                    }
                    if qi2 == m {
                        return Some((1, skipped_here, (j2 - 1) as u8));
                    }
                    let mid_word = take >= 2
                        && end < self.s.len()
                        && !self.s[end].is_sep()
                        && self.words.get(j2) != Some(&(end as u16));
                    if j2 < nw
                        && let Some((sg, sk, last)) = self.dfs(qi2, j2, depth + 1, true, mid_word)
                    {
                        return Some((sg + 1, sk.saturating_add(skipped_here), last));
                    }
                    take -= 1;
                }
            }
            j += 1;
        }
        None
    }
}

/// In-order word-prefix segmentation of `q` over the words of `s`.
fn segment<T: Unit>(q: &[T], s: &[T], ws: u64, words: &[u16], rec: Option<&mut Vec<u32>>) -> Option<Seg> {
    if q.is_empty() || words.is_empty() || q.len() > 64 {
        return None;
    }
    let mut ctx = SegCtx {
        q,
        s,
        words,
        budget: 256,
        path: [(0, 0); 16],
    };
    let (segments, skipped, last) = ctx.dfs(0, 0, 0, false, false)?;
    let nseg = (segments as usize).min(16);
    let path = &ctx.path[..nseg];
    if let Some(out) = rec {
        for &(j, t) in path {
            let w = words[j as usize] as u32;
            out.extend(w..w + t as u32);
        }
    }
    // A camelCase word whose every hump starts a consecutive segment was typed as its initials
    // ("gh" for GitHub). It counts as one whole-word segment.
    let mut token_cover = [false; 16];
    let mut merged = 0u8;
    let mut d = 0;
    while d < nseg {
        let j = path[d].0 as usize;
        let mut k = 1;
        while j + k < words.len() && is_hump(s, words[j + k] as usize) {
            k += 1;
        }
        if k >= 2 && !is_hump(s, words[j] as usize) && d + k <= nseg && (1..k).all(|x| path[d + x].0 as usize == j + x)
        {
            token_cover[d..d + k].iter_mut().for_each(|c| *c = true);
            merged += (k - 1) as u8;
            d += k;
        } else {
            d += 1;
        }
    }
    let mut all_complete = true;
    let mut adj: i16 = 0;
    for (d, &(j, t)) in path.iter().enumerate() {
        let e = words[j as usize] as usize + t as usize;
        let complete = token_cover[d] || e >= s.len() || s[e].is_sep() || words.binary_search(&(e as u16)).is_ok();
        if !complete {
            all_complete = false;
            if d + 1 < nseg && t >= 2 {
                adj -= 50;
            }
        }
    }
    if all_complete {
        adj += 40;
    }
    let (lj, lt) = path[nseg - 1];
    let end = words[lj as usize] as usize + lt as usize;
    let first_word = path[0].0;
    Some(Seg {
        end,
        first_word,
        skipped,
        segments: segments - merged,
        covers_all: first_word == 0 && skipped == 0 && last as usize == words.len() - 1,
        adj,
        ends_mid: !token_cover[nseg - 1] && end < s.len() && !(s[end].is_sep() || is_ws(s, ws, end)),
    })
}

/// Unordered tokens: every token must be a prefix of a distinct word. Returns the last word used.
fn unordered<T: Unit>(nd: &Needle<'_, T>, s: &[T], words: &[u16], rec: Option<&mut Vec<u32>>) -> Option<i32> {
    let mut used = 0u64;
    let mut worst_word = 0usize;
    let mut buf: [(u16, u16); 16] = [(0, 0); 16];
    for (ti, &(a, b)) in nd.tokens.iter().enumerate() {
        let t = &nd.full[a as usize..b as usize];
        let mut found = false;
        for (j, &w) in words.iter().enumerate() {
            if j < 64 && (used >> j) & 1 == 1 {
                continue;
            }
            let w = w as usize;
            if s.len() - w >= t.len() && &s[w..w + t.len()] == t {
                used |= 1u64 << j.min(63);
                worst_word = worst_word.max(j);
                if ti < 16 {
                    buf[ti] = (w as u16, t.len() as u16);
                }
                found = true;
                break;
            }
        }
        if !found {
            return None;
        }
    }
    if let Some(out) = rec {
        for &(w, l) in buf.iter().take(nd.tokens.len().min(16)) {
            out.extend(w as u32..w as u32 + l as u32);
        }
    }
    Some(worst_word as i32)
}

/// fzf-v1 style: forward to the first complete match end, backward to the tightest start, score.
fn subsequence_quality<T: Unit>(q: &[T], s: &[T], ws: u64, rec: Option<&mut Vec<u32>>) -> Option<i32> {
    let m = q.len();
    let n = s.len();
    if m == 0 || m > n {
        return None;
    }
    let mut qi = 0;
    let mut end = usize::MAX;
    for (i, &c) in s.iter().enumerate() {
        if c == q[qi] {
            qi += 1;
            if qi == m {
                end = i;
                break;
            }
        }
    }
    if end == usize::MAX {
        return None;
    }
    let mut qi = m;
    let mut start = 0;
    let mut i = end + 1;
    while i > 0 {
        i -= 1;
        if s[i] == q[qi - 1] {
            qi -= 1;
            if qi == 0 {
                start = i;
                break;
            }
        }
    }
    let mut ws_hits = 0;
    let mut consec = 0;
    let mut prev = usize::MAX;
    let mut qi = 0;
    let mut out = rec;
    for i in start..=end {
        if qi < m && s[i] == q[qi] {
            if is_ws(s, ws, i) {
                ws_hits += 1;
            }
            if prev != usize::MAX && prev + 1 == i {
                consec += 1;
            }
            if let Some(o) = out.as_deref_mut() {
                o.push(i as u32);
            }
            prev = i;
            qi += 1;
        }
    }
    let gaps = (end + 1 - start - m) as i32;
    Some(
        500 + 25 * ws_hits + 15 * consec - 4 * gaps.min(50) - 3 * (start as i32).min(30) - 2 * ((n - m) as i32).min(60),
    )
}

#[inline(always)]
fn prefix_eq<T: Unit>(q: &[T], s: &[T]) -> bool {
    q.len() <= s.len() && q.iter().zip(s).all(|(a, b)| a == b)
}

/// Linear-time "at most one edit (substitution, insertion, deletion or adjacent transposition)
/// between `q` and some prefix of `s`". Equivalent to an optimal-string-alignment DP with a free
/// end (tested exhaustively), with no table.
#[inline]
pub fn one_edit_prefix<T: Unit>(q: &[T], s: &[T]) -> bool {
    let m = q.len();
    let mut i = 0;
    while i < m && i < s.len() && q[i] == s[i] {
        i += 1;
    }
    if i == m {
        return true;
    }
    // substitution
    if i < s.len() && prefix_eq(&q[i + 1..], &s[i + 1..]) {
        return true;
    }
    // the text has an extra unit (the user left one out)
    if i < s.len() && prefix_eq(&q[i..], &s[i + 1..]) {
        return true;
    }
    // the query has an extra unit
    if prefix_eq(&q[i + 1..], &s[i.min(s.len())..]) {
        return true;
    }
    // adjacent transposition
    i + 1 < m && i + 1 < s.len() && q[i] == s[i + 1] && q[i + 1] == s[i] && prefix_eq(&q[i + 2..], &s[i + 2..])
}

/// Typo tier: one edit against the prefix of some word whose initial is q[0] or q[1].
fn typo<T: Unit>(q: &[T], s: &[T], words: &[u16], rec: Option<&mut Vec<u32>>) -> Option<i32> {
    let m = q.len();
    if m < 4 {
        return None;
    }
    for (j, &w) in words.iter().enumerate() {
        let w = w as usize;
        let c = s[w];
        if c != q[0] && c != q[1] {
            continue;
        }
        if one_edit_prefix(q, &s[w..]) {
            if let Some(out) = rec {
                out.extend(w as u32..(w + m).min(s.len()) as u32);
            }
            let extra = (s.len() as i32 - m as i32).max(0);
            return Some(600 - 60 * (j as i32).min(5) - 3 * extra.min(60));
        }
    }
    None
}

/// Scores one window `s` whose word-start bits for s[0..64] are `ws`.
///
/// With `typo_mode` false this is the strict pass (every tier but typo). With `typo_mode` true it
/// reports only the typo tier, for any window, strict match or not; callers keep the better of the
/// two. With `REC`, matched positions (units into `s`) are appended to `rec`.
#[inline]
pub fn score<T: Unit, const REC: bool>(
    nd: &Needle<'_, T>,
    s: &[T],
    ws: u64,
    typo_mode: bool,
    mut rec: Option<&mut Vec<u32>>,
) -> Option<TextScore> {
    let q = nd.ns;
    let m = q.len();
    let n = s.len();
    if m == 0 || n == 0 {
        return None;
    }
    if typo_mode {
        let mut words = [0u16; MAXW];
        let nw = collect_words(s, ws, &mut words);
        return typo(q, s, &words[..nw], rec).map(|qq| TextScore::new(TYPO, qq));
    }
    // ---- single-char fast path (same results as the general path below; tested)
    if m == 1 && !REC && n <= 64 && nd.tokens.len() <= 1 {
        let c = q[0];
        let p = s.iter().position(|&x| x == c)?;
        if p == 0 {
            if n == 1 {
                return Some(TextScore::new(EXACT, 999));
            }
            let ends_mid = !(s[1].is_sep() || is_ws(s, ws, 1));
            let all = !word_start_at_or_after(s, ws, 1);
            return Some(TextScore::new(PREFIX, prefix_quality(n, 1, ends_mid, all, false)));
        }
        let extra = ((n - 1) as i32).min(60);
        let mut bits = ws;
        let mut j = 0i32;
        while bits != 0 {
            let i = bits.trailing_zeros() as usize;
            if i >= n {
                break;
            }
            if s[i] == c {
                let complete = i + 1 >= n || s[i + 1].is_sep() || is_ws(s, ws, i + 1);
                let adj = if complete { 40 } else { 0 };
                return Some(TextScore::new(
                    WORD_PREFIX,
                    word_prefix_quality(j as u8, 0, 1, extra, adj),
                ));
            }
            j += 1;
            bits &= bits - 1;
        }
        return Some(TextScore::new(SUBSTRING, substring_quality(p as i32, extra)));
    }
    // ---- gate: subsequence (one token) or every token a subsequence (several tokens)
    if !is_strict_match(nd, s) {
        return None;
    }
    let full = nd.full;
    let fm = full.len();
    // ---- exact
    if n == fm && s == full {
        if let Some(o) = rec.as_deref_mut() {
            o.extend(0..n as u32);
        }
        return Some(TextScore::new(EXACT, 999));
    }
    // ---- literal prefix
    if n > fm && &s[..fm] == full {
        let ends_mid = !(s[fm].is_sep() || is_ws(s, ws, fm));
        let all = !word_start_at_or_after(s, ws, fm);
        if let Some(o) = rec.as_deref_mut() {
            o.extend(0..fm as u32);
        }
        return Some(TextScore::new(PREFIX, prefix_quality(n, fm, ends_mid, all, false)));
    }
    let mut words = [0u16; MAXW];
    let nw = collect_words(s, ws, &mut words);
    let words = &words[..nw];
    let extra = (n as i32 - m as i32).max(0);
    // ---- in-order word-prefix segmentation ("vsc", "vs code", "dark", "gh")
    if let Some(sg) = segment(q, s, ws, words, if REC { rec.as_deref_mut() } else { None }) {
        if sg.covers_all && m >= 2 {
            return Some(TextScore::new(PREFIX, prefix_quality(n, fm, sg.ends_mid, true, true)));
        }
        let qq = word_prefix_quality(sg.first_word, sg.skipped, sg.segments, extra, sg.adj);
        return Some(TextScore::new(WORD_PREFIX, qq));
    }
    // ---- unordered tokens ("mode dark")
    if nd.tokens.len() >= 2
        && let Some(worst) = unordered(nd, s, words, rec.as_deref_mut())
    {
        if let Some(o) = rec.as_deref_mut() {
            o.sort_unstable();
        }
        return Some(TextScore::new(UNORDERED, unordered_quality(worst, extra)));
    }
    // ---- substring (literal with spaces, then without)
    let sub = find(s, full)
        .map(|p| (p, fm))
        .or_else(|| if fm != m { find(s, q).map(|p| (p, m)) } else { None });
    if let Some((p, l)) = sub {
        if let Some(o) = rec.as_deref_mut() {
            o.extend(p as u32..(p + l) as u32);
        }
        return Some(TextScore::new(SUBSTRING, substring_quality(p as i32, extra)));
    }
    // ---- scattered subsequence
    if nd.tokens.len() <= 1 {
        return subsequence_quality(q, s, ws, rec).map(|qq| TextScore::new(SUBSEQUENCE, qq));
    }
    // several tokens, not all on word starts: each token as a subsequence, keep the worst
    let mut worst = 999;
    for &(a, b) in nd.tokens {
        let t = &full[a as usize..b as usize];
        worst = worst.min(subsequence_quality(t, s, ws, rec.as_deref_mut())?);
    }
    if let Some(o) = rec {
        o.sort_unstable();
        o.dedup();
    }
    Some(TextScore::new(SUBSEQUENCE, worst - 100))
}

/// The in-order word-prefix segmentation of `q` over `words`, for the bit path.
#[inline]
pub fn segment_info(q: &[u8], s: &[u8], ws: u64, words: &[u16]) -> Option<Seg> {
    segment(q, s, ws, words, None)
}

/// The unordered-tokens tier, for the bit path. Returns the last word used.
#[inline]
pub fn unordered_pub(nd: &Needle<'_, u8>, s: &[u8], words: &[u16]) -> Option<i32> {
    unordered(nd, s, words, None)
}

/// The strict gate: the query (one token) or every token (several) is a subsequence of `s`.
/// Appending to the query can only shrink the set of windows that pass it, which is what makes
/// incremental narrowing exact.
#[inline(always)]
pub fn is_strict_match<T: Unit>(nd: &Needle<'_, T>, s: &[T]) -> bool {
    if nd.tokens.len() <= 1 {
        is_subsequence(nd.ns, s)
    } else {
        nd.tokens
            .iter()
            .all(|&(a, b)| is_subsequence(&nd.full[a as usize..b as usize], s))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reference for `one_edit_prefix`: optimal-string-alignment distance <= 1 of `q` against a
    /// prefix of `s` (free end), computed with a small DP table.
    fn osa_le1_prefix<T: Unit>(q: &[T], s: &[T]) -> bool {
        let m = q.len();
        let n = s.len().min(m + 1);
        const W: usize = 34;
        if m + 1 > W {
            return false;
        }
        let mut prev2 = [2u8; W];
        let mut prev = [2u8; W];
        let mut cur = [2u8; W];
        for (j, p) in prev.iter_mut().enumerate().take(n.min(1) + 1) {
            *p = j as u8;
        }
        for i in 1..=m {
            cur.iter_mut().for_each(|c| *c = 2);
            let lo = i.saturating_sub(1);
            let hi = (i + 1).min(n);
            if lo == 0 {
                cur[0] = (i as u8).min(2);
            }
            for j in lo.max(1)..=hi {
                let cost = if q[i - 1] == s[j - 1] { 0 } else { 1 };
                let mut v = prev[j - 1] + cost;
                v = v.min(prev[j] + 1).min(cur[j - 1] + 1);
                if i > 1 && j > 1 && q[i - 1] == s[j - 2] && q[i - 2] == s[j - 1] {
                    v = v.min(prev2[j - 2] + 1);
                }
                cur[j] = v.min(2);
            }
            prev2 = prev;
            prev = cur;
        }
        let lo = m.saturating_sub(1);
        (lo..=(m + 1).min(n)).any(|j| prev[j] <= 1)
    }

    #[test]
    fn osa_reference_accepts_typos() {
        assert!(osa_le1_prefix(b"safaru", b"safari"));
        assert!(osa_le1_prefix(b"saafri", b"safari"));
        assert!(osa_le1_prefix(b"termnial", b"terminal"));
        assert!(osa_le1_prefix(b"clipbaord", b"clipboard history"));
        assert!(!osa_le1_prefix(b"xyzabc", b"safari"));
        assert!(osa_le1_prefix(b"safri", b"safari"));
        assert!(osa_le1_prefix(b"safarii", b"safari"));
    }

    #[test]
    fn one_edit_equals_dp() {
        // exhaustive over a small alphabet: every q (len 1..=5) against every s (len 0..=6)
        fn all(len: usize) -> Vec<Vec<u8>> {
            let mut v = vec![vec![]];
            for _ in 0..len {
                v = v
                    .into_iter()
                    .flat_map(|p| {
                        (*b"abc").map(|c| {
                            let mut x = p.clone();
                            x.push(c);
                            x
                        })
                    })
                    .collect();
            }
            v
        }
        let mut n = 0;
        for ql in 1..=5 {
            for q in all(ql) {
                for sl in 0..=6 {
                    for s in all(sl) {
                        assert_eq!(one_edit_prefix(&q, &s), osa_le1_prefix(&q, &s), "q={q:?} s={s:?}");
                        n += 1;
                    }
                }
            }
        }
        assert!(n > 100_000);
    }

    fn ws_of(s: &str) -> (Vec<u8>, u64) {
        let (f, _) = crate::fold::fold_str(s, 0);
        (f.bytes, f.ws)
    }

    fn score_str(q: &str, s: &str) -> Option<TextScore> {
        let query = crate::Query::new(q);
        let (bytes, ws) = ws_of(s);
        score::<u8, false>(&query.needle(), &bytes, ws, false, None)
    }

    #[test]
    fn camel_initials_count_as_one_whole_word() {
        let camel = score_str("gh", "Search GitHub").map(|t| t.quality);
        let split = score_str("gh", "Search Git Hub").map(|t| t.quality);
        assert!(camel > split, "{camel:?} {split:?}");
        assert_eq!(score_str("gh", "GitHub").map(|t| t.tier), Some(PREFIX));
        assert_eq!(score_str("yt", "YouTube").map(|t| t.tier), Some(PREFIX));
    }

    #[test]
    fn typo_mode_scores_strict_matches_too() {
        let query = crate::Query::new("musc");
        let (bytes, ws) = ws_of("Music");
        let strict = score::<u8, false>(&query.needle(), &bytes, ws, false, None);
        let typo = score::<u8, false>(&query.needle(), &bytes, ws, true, None);
        assert_eq!(strict.map(|t| t.tier), Some(SUBSEQUENCE));
        assert_eq!(typo.map(|t| t.tier), Some(TYPO));
    }
}
