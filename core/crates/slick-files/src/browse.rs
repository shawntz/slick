//! Folder listings for queries that start with `/` or `~`.
//!
//! `~/Proj` lists the children of the home folder that match `Proj`; `~/Projects/` lists every
//! child of `~/Projects`. With a filter, children are ranked by the name tiers; without one, they
//! are sorted by name or by modification time. Hidden children show when the options allow them
//! or when the filter starts with a dot.

use crate::rank::{self, TIER_GAP, tier};
use crate::search::{BrowseSort, FileHit, Folded, How, Kinds, SearchOptions};
use crate::store::{EntryId, Snapshot, flags};
use slick_match::Query;
use slick_match::bits::{Bound, Sc};

/// Lists the children of the folder at `dir` that match `filter` into `out`. Returns false when
/// the index does not hold that folder; the caller can then list it from disk.
pub(crate) fn list(snap: &Snapshot, dir: &[u8], filter: &str, opts: &SearchOptions, out: &mut Vec<FileHit>) -> bool {
    out.clear();
    let Some((id, true)) = snap.lookup(dir) else {
        return false;
    };
    if snap.entry(id).is_none_or(|e| !e.is_dir()) {
        return false;
    }
    let show_hidden = opts.include_hidden || filter.starts_with('.');
    let q = Query::new(filter);
    let mut f = Folded::default();
    let mut ranked: Vec<(i32, EntryId)> = Vec::new();
    for child in snap.children(id) {
        let Some((c, s)) = snap.locate(child) else { continue };
        let v = c.view();
        let fl = v.flags[s];
        if fl & flags::HIDDEN != 0 && !show_hidden {
            continue;
        }
        let ok = match opts.kinds {
            Kinds::All => true,
            Kinds::Files => fl & flags::DIR == 0,
            Kinds::Folders => fl & flags::DIR != 0,
        };
        if !ok {
            continue;
        }
        if q.is_empty() {
            ranked.push((0, child));
            continue;
        }
        f.load_slot(&v, s);
        let len = f.bytes().len();
        if let Sc::Yes(t) = f.score(&q, len, 0, Bound::NONE) {
            ranked.push((rank::name_rank(t, 0), child));
        }
    }
    if q.is_empty() {
        match opts.browse_sort {
            BrowseSort::Name => ranked.sort_by(|a, b| name_order(snap.name_of(a.1), snap.name_of(b.1))),
            BrowseSort::Modified => {
                ranked.sort_by_key(|&(_, id)| (std::cmp::Reverse(snap.entry(id).map_or(0, |e| e.mtime)), id))
            }
        }
        let n = ranked.len().min(opts.limit) as i32;
        for (i, (_, id)) in ranked.into_iter().take(opts.limit).enumerate() {
            out.push(FileHit {
                id,
                rank: TIER_GAP * tier::EXACT as i32 + (n - i as i32).min(999),
                how: How::Browse,
            });
        }
    } else {
        ranked.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| name_order(snap.name_of(a.1), snap.name_of(b.1)))
        });
        out.extend(ranked.into_iter().take(opts.limit).map(|(r, id)| FileHit {
            id,
            rank: r,
            how: How::Browse,
        }));
    }
    true
}

/// Case-insensitive byte order, then exact bytes.
fn name_order(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    a.iter()
        .map(u8::to_ascii_lowercase)
        .cmp(b.iter().map(u8::to_ascii_lowercase))
        .then_with(|| a.cmp(b))
}
