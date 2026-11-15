//! Highlight ranges for the rows on screen, as UTF-16 ranges into the entry's name.

use crate::names::stem_len;
use crate::query::{self, MAX_ANC_TOKENS, Parsed};
use crate::search::{FileHit, Folded, How, SearchOptions};
use crate::store::{NONE, Snapshot};
use slick_match::bits::{Bound, Sc};
use slick_match::score::{self, WORD_PREFIX};
use slick_match::{Arena, HighlightScratch, Query};

pub(crate) fn ranges(snap: &Snapshot, hit: &FileHit, raw: &str, opts: &SearchOptions, out: &mut Vec<(u32, u32)>) {
    let name = String::from_utf8_lossy(snap.name_of(hit.id)).into_owned();
    let stem = |s: &str| stem_len(s.as_bytes()).unwrap_or(s.len());
    match query::parse(raw, opts.home.as_deref()) {
        Parsed::Browse { filter, .. } => mark(&name, &Query::new(&filter), out),
        Parsed::Search(plan) => match hit.how {
            How::Name | How::Typo => {
                if let Some(q) = &plan.literal {
                    let w = if plan.dot_ext.is_some() {
                        stem(&name)
                    } else {
                        name.len()
                    };
                    mark(&name[..w], q, out);
                }
            }
            How::Extension => {
                if let Some((_, rest, _)) = &plan.bare_ext {
                    mark(&name[..stem(&name)], rest, out);
                }
            }
            How::Ancestor => {
                let w = if plan.dot_ext.is_some() {
                    stem(&name)
                } else {
                    name.len()
                };
                let window = &name[..w];
                let n_tok = plan.tokens.len().min(MAX_ANC_TOKENS);
                let all = (1u32 << n_tok) - 1;
                let mut folded = Vec::new();
                let mut chars = Vec::new();
                crate::names::fold_into(window.as_bytes(), &mut folded, &mut chars);
                let mut sub = 0u32;
                for (j, t) in plan.tokens.iter().take(n_tok).enumerate() {
                    if score::is_subsequence(&t.q.ns, &folded) {
                        sub |= 1 << j;
                    }
                }
                let in_folders = folder_tokens(snap, hit.id, &plan.tokens[..n_tok]) & all;
                let mut base = all & !in_folders;
                if base == 0 && sub != 0 {
                    base = 1 << (31 - sub.leading_zeros());
                }
                if let Some(q) = plan.subset(base) {
                    mark(window, q, out);
                }
            }
            How::Filter | How::Browse => {}
        },
    }
}

/// Which tokens start a word of a folder above `id`.
fn folder_tokens(snap: &Snapshot, id: crate::store::EntryId, tokens: &[query::Token]) -> u32 {
    let mut f = Folded::default();
    let mut bits = 0u32;
    let mut cur = snap.parent_of(id);
    let mut guard = 0;
    while cur != NONE && guard <= crate::store::MAX_DEPTH {
        guard += 1;
        let Some((c, s)) = snap.locate(cur) else { break };
        let v = c.view();
        f.load_slot(&v, s);
        let len = f.bytes().len();
        for (j, t) in tokens.iter().enumerate() {
            if bits >> j & 1 == 0
                && matches!(f.score(&t.q, len, WORD_PREFIX, Bound::NONE), Sc::Yes(t) if t.tier >= WORD_PREFIX)
            {
                bits |= 1 << j;
            }
        }
        cur = v.parent[s];
    }
    bits
}

fn mark(text: &str, q: &Query, out: &mut Vec<(u32, u32)>) {
    if text.is_empty() || q.is_empty() {
        return;
    }
    let arena = Arena::from_titles([text]);
    let mut scratch = HighlightScratch::default();
    slick_match::highlight::ranges(&arena, 0, q, text, &mut scratch, out);
}
