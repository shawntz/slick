//! Query sessions: the per-panel state that makes repeated queries cheap and allocation-free.

use crate::index::Index;
use crate::rank::TIER_LEARNED;
use slick_match::search::score_entry;
use slick_match::{Field, HighlightScratch, Opts, Query, highlight, rank};

/// Where a hit's rank came from.
pub mod hit_flags {
    /// A user alias matched.
    pub const ALIAS: u8 = 1;
    /// The learned band: the strongest affinity entry for exactly this query.
    pub const LEARNED: u8 = 2;
    /// Query affinity below the band lifted the hit.
    pub const AFFINITY: u8 = 4;
}

/// The field value of a hit that matched through a user alias.
pub const FIELD_USER_ALIAS: u8 = 3;
/// The field value of a hit that matched no text (a learned-band item).
pub const FIELD_NONE: u8 = 255;

/// One ranked result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hit {
    /// Item key.
    pub key: u64,
    /// Rank; higher is better (see `rank`).
    pub rank: i32,
    /// Text tier 0..=6, or `TIER_LEARNED`, `TIER_ALIAS_PREFIX`, `TIER_ALIAS_EXACT`.
    pub tier: u8,
    /// 0 title, 1 alias, 2 keyword, `FIELD_USER_ALIAS`, or `FIELD_NONE`.
    pub field: u8,
    /// Item kind.
    pub kind: u8,
    /// See [`hit_flags`].
    pub flags: u8,
    pub(crate) pos: u32,
}

/// An item ranked outside the matcher: by a user alias, the learned band or query affinity.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Special {
    /// A fixed rank (alias or learned band).
    Fixed {
        pos: u32,
        rank: i32,
        tier: u8,
        field: u8,
        flags: u8,
    },
    /// The item's text rank plus `lift`, when it matches the query at all.
    Affinity { pos: u32, lift: i32 },
}

impl Special {
    fn pos(&self) -> u32 {
        match *self {
            Special::Fixed { pos, .. } | Special::Affinity { pos, .. } => pos,
        }
    }
}

/// Per-caller query state. Keep one per panel and reuse it for every keystroke: after the first
/// queries, a query allocates nothing. Call [`Session::reset`] on summon.
#[derive(Default)]
pub struct Session {
    pub(crate) target: u64,
    pub(crate) query: Query,
    matcher: slick_match::Session,
    matches: Vec<slick_match::Hit>,
    pub(crate) specials: Vec<Special>,
    pub(crate) hits: Vec<Hit>,
    chars: Vec<char>,
    hl: HighlightScratch,
    pub(crate) ranges: Vec<(u32, u32)>,
    pub(crate) completion: String,
}

impl Session {
    /// A new session.
    pub fn new() -> Session {
        Session::default()
    }

    /// Forgets earlier queries, so the next one scans everything. Call it on summon.
    pub fn reset(&mut self) {
        self.matcher.reset();
        self.query.set("");
        self.hits.clear();
    }

    /// The hits of the last query, best first.
    pub fn hits(&self) -> &[Hit] {
        &self.hits
    }

    /// Prepares a query against `index`: binds the session to it and folds `text`. With
    /// `whole_words`, a query equal to a whole later word of a title ranks with literal prefixes
    /// ("code" finds Visual Studio Code); see `slick_match::Query::whole_words`.
    pub(crate) fn begin(&mut self, index: &Index, text: &str, whole_words: bool) {
        if self.target != index.generation {
            self.matcher.reset();
            self.target = index.generation;
        }
        self.query.whole_words = whole_words;
        self.query.set(text);
        self.hits.clear();
        self.specials.clear();
    }

    /// Adds a special, keeping the stronger one when the item already has one.
    pub(crate) fn add_special(specials: &mut Vec<Special>, s: Special) {
        let pos = s.pos();
        if let Some(i) = specials.iter().position(|x| x.pos() == pos) {
            let keep_new = match (specials[i], s) {
                (Special::Affinity { .. }, Special::Fixed { .. }) => true,
                (Special::Fixed { rank: a, .. }, Special::Fixed { rank: b, .. }) => b > a,
                (Special::Affinity { lift: a, .. }, Special::Affinity { lift: b, .. }) => b > a,
                (Special::Fixed { .. }, Special::Affinity { .. }) => false,
            };
            if keep_new {
                specials[i] = s;
            }
        } else {
            specials.push(s);
        }
    }

    /// Runs the matcher, visiting `seeds` first, and merges the specials into the top `k` hits.
    pub(crate) fn run(&mut self, index: &Index, k: usize, lift: Option<&[i32]>, seeds: &[u32]) {
        if self.query.is_empty() || k == 0 || index.is_empty() {
            return;
        }
        let opts = Opts {
            k: k.saturating_add(self.specials.len()),
            ..Opts::default()
        };
        self.matcher
            .search_seeded(&index.arena, &self.query, &opts, lift, seeds, &mut self.matches);
        for m in &self.matches {
            if self.specials.iter().all(|s| s.pos() != m.idx) {
                self.hits.push(hit(index, m.idx, m.rank, m.tier(), m.field as u8, 0));
            }
        }
        let typo = self.matcher.typo_ran();
        for i in 0..self.specials.len() {
            match self.specials[i] {
                Special::Fixed {
                    pos,
                    rank,
                    tier,
                    field,
                    flags,
                } => self.hits.push(hit(index, pos, rank, tier, field, flags)),
                Special::Affinity { pos, lift: extra } => {
                    let base = lift.map_or(0, |l| l[pos as usize]);
                    let text = match self.matches.iter().find(|m| m.idx == pos) {
                        Some(m) => Some((m.rank, m.field)),
                        None => text_rank(index, &self.query, pos, base, typo, &mut self.chars),
                    };
                    if let Some((r, field)) = text {
                        let tier = rank::tier_of(r).min(6);
                        self.hits
                            .push(hit(index, pos, r + extra, tier, field as u8, hit_flags::AFFINITY));
                    }
                }
            }
        }
        self.hits
            .sort_unstable_by(|a, b| b.rank.cmp(&a.rank).then(a.pos.cmp(&b.pos)));
        self.hits.truncate(k);
    }

    /// Highlight ranges of the title of the item at `pos` for the last query, as UTF-16
    /// (start, length) pairs.
    pub(crate) fn title_ranges(&mut self, index: &Index, pos: u32) -> &[(u32, u32)] {
        let e = index.arena.entry_range(pos as usize).start;
        highlight::ranges(
            &index.arena,
            e,
            &self.query,
            index.entry_text(e),
            &mut self.hl,
            &mut self.ranges,
        );
        &self.ranges
    }

    /// When the folded `text` starts with the folded query, stores the rest of `text` as the
    /// completion and returns true.
    pub(crate) fn complete_with(&mut self, text: &str) -> bool {
        let q = self.query.chars();
        // Composed, as titles and queries are folded, so a decomposed title completes too.
        let mut glyphs = slick_match::fold::composed(text.chars());
        let mut at = 0usize;
        for &qc in q {
            match glyphs.next() {
                Some(g) if fold(g.c) == qc => at += g.bytes as usize,
                _ => return false,
            }
        }
        let rest = &text[at..];
        self.completion.clear();
        self.completion.push_str(rest);
        !rest.is_empty()
    }
}

fn fold(c: char) -> char {
    if c.is_whitespace() {
        ' '
    } else {
        slick_match::fold::fold_char(c)
    }
}

fn hit(index: &Index, pos: u32, rank: i32, tier: u8, field: u8, flags: u8) -> Hit {
    let p = pos as usize;
    Hit {
        key: index.keys[p],
        rank,
        tier,
        field,
        kind: index.kinds[p],
        flags,
        pos,
    }
}

/// The best text rank of the item at `pos`, scored directly the way the matcher scores it.
fn text_rank(index: &Index, q: &Query, pos: u32, lift: i32, typo: bool, chars: &mut Vec<char>) -> Option<(i32, Field)> {
    let opts = Opts::default();
    let a = &index.arena;
    let mut best: Option<(i32, Field)> = None;
    for e in a.entry_range(pos as usize) {
        let field = a.field(e);
        let strict = score_entry(a, e, q, &opts, false, chars).and_then(|t| rank::rank(t, field, lift));
        let typo = if typo && field != Field::Keyword {
            score_entry(a, e, q, &opts, true, chars).and_then(|t| rank::rank(t, field, lift))
        } else {
            None
        };
        for r in [strict, typo].into_iter().flatten() {
            if best.is_none_or(|(b, _)| r > b) {
                best = Some((r, field));
            }
        }
    }
    best
}

/// True for hits ranked above the text tiers.
pub(crate) fn is_band(h: &Hit) -> bool {
    h.tier >= TIER_LEARNED
}
