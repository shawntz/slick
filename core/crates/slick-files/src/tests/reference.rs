//! A brute-force reference for search: every entry scored with the scalar `slick_match` scorer
//! on `fold_str` output, folders checked by walking up, no prefilter, no bound, no prefix pass,
//! no narrowing, no parallel parts. The real search must return exactly the same hits.

use super::{EXTS, WORDS, corpus};
use crate::names::{compress_mask, ext_matches, stem_len};
use crate::query::{MAX_ANC_TOKENS, Plan};
use crate::rank::{self, Lifter, Prefer, TIER_GAP, tier};
use crate::search::{FileHit, How, Kinds, SearchOptions, Searcher, Serial};
use crate::store::{EntryId, NONE, Snapshot, flags};
use slick_match::fold::fold_str;
use slick_match::score::{self, TextScore, WORD_PREFIX};
use slick_match::{Query, Unit};
use std::sync::Arc;

struct RefName {
    bytes: Vec<u8>,
    ws: u64,
    mask: u64,
    initials: u64,
    ascii_fold: bool,
}

fn fold(name: &[u8]) -> RefName {
    let s = String::from_utf8_lossy(name);
    let (f, _) = fold_str(&s, 0);
    RefName {
        ascii_fold: f.bytes.is_ascii(),
        bytes: f.bytes,
        ws: f.ws,
        mask: f.mask,
        initials: f.initials,
    }
}

/// `slick_match`'s scorer on the first `n` folded bytes, strict or typo.
fn score_ref(q: &Query, f: &RefName, n: usize, typo: bool) -> Option<TextScore> {
    let s = &f.bytes[..n.min(f.bytes.len())];
    if s.is_empty() || q.is_empty() {
        return None;
    }
    if q.ascii {
        return score::score::<u8, false>(&q.needle(), s, f.ws, typo, None);
    }
    if f.ascii_fold {
        return None;
    }
    let text = std::str::from_utf8(s).ok()?;
    let mut chars: Vec<char> = Vec::new();
    let mut cws = 0u64;
    for (ci, (bi, c)) in text.char_indices().enumerate() {
        let start = if bi < 64 {
            (f.ws >> bi) & 1 == 1
        } else {
            chars.last().is_some_and(|p| p.is_sep()) && !c.is_sep()
        };
        if start && ci < 64 {
            cws |= 1 << ci;
        }
        chars.push(c);
    }
    score::score::<char, false>(&q.needle_chars(), &chars, cws, typo, None)
}

fn word_prefix_or_better(q: &Query, name: &[u8]) -> bool {
    let f = fold(name);
    score_ref(q, &f, f.bytes.len(), false).is_some_and(|t| t.tier >= WORD_PREFIX)
}

fn ancestors(snap: &Snapshot, id: EntryId) -> Vec<EntryId> {
    let mut out = Vec::new();
    let mut cur = snap.entry(id).map_or(NONE, |e| e.parent);
    while cur != NONE {
        out.push(cur);
        cur = snap.entry(cur).map_or(NONE, |e| e.parent);
    }
    out
}

fn chain_ok(snap: &Snapshot, id: EntryId, parts: &[Query]) -> bool {
    ancestors(snap, id).into_iter().any(|end| {
        let mut cur = end;
        for q in parts.iter().rev() {
            let Some(e) = snap.entry(cur) else { return false };
            if !word_prefix_or_better(q, e.name) {
                return false;
            }
            cur = e.parent;
        }
        true
    })
}

fn eval_ref(snap: &Snapshot, p: &Plan, o: &SearchOptions, lifter: &Lifter, id: EntryId) -> Option<(i32, How)> {
    let e = snap.entry(id)?;
    let kind_ok = match o.kinds {
        Kinds::All => true,
        Kinds::Files => !e.is_dir(),
        Kinds::Folders => e.is_dir(),
    };
    if !kind_ok || (e.flags & flags::HIDDEN != 0 && !o.include_hidden) {
        return None;
    }
    if let Some(w) = o.within
        && !ancestors(snap, id).contains(&w)
    {
        return None;
    }
    if !p.chains().iter().all(|c| chain_ok(snap, id, c.parts())) {
        return None;
    }
    let lift = lifter.lift(e.mtime, e.depth, e.is_dir());
    let f = fold(e.name);
    let mut window = f.bytes.len();
    if let Some(ext) = p.dot_ext() {
        if !ext_matches(&f.bytes, ext, false) {
            return None;
        }
        window = stem_len(&f.bytes).unwrap_or(window);
    }
    let Some(lit) = p.literal() else {
        let exact = p.dot_ext().is_some_and(|x| ext_matches(&f.bytes, x, true));
        let q = if exact || p.dot_ext().is_none() { 999 } else { 500 };
        return Some((TIER_GAP * tier::PREFIX as i32 + q + lift, How::Filter));
    };
    let mut best: Option<(i32, How)> = score_ref(lit, &f, window, false).map(|t| (rank::name_rank(t, lift), How::Name));
    if let Some((ext, rest, _)) = p.bare_ext()
        && p.dot_ext().is_none()
        && ext_matches(&f.bytes, ext, true)
    {
        let stem = stem_len(&f.bytes).unwrap_or(f.bytes.len());
        if let Some(t) = score_ref(rest, &f, stem, false) {
            let r = rank::name_rank(t, lift);
            if best.is_none_or(|b| r > b.0) {
                best = Some((r, How::Extension));
            }
        }
    }
    if p.ancestors && best.is_none_or(|b| rank::tier_of(b.0) < tier::ANCESTOR) {
        let n = p.tokens().len().min(MAX_ANC_TOKENS);
        let all = (1u32 << n) - 1;
        let m = compress_mask(f.mask);
        let mut sub = 0u32;
        for (j, t) in p.tokens().iter().take(n).enumerate() {
            if t.mask & !m == 0 && score::is_subsequence(&t.q.ns, &f.bytes[..window]) {
                sub |= 1 << j;
            }
        }
        let mut in_folders = 0u32;
        for a in ancestors(snap, id) {
            let Some(ae) = snap.entry(a) else { continue };
            for (j, t) in p.tokens().iter().take(n).enumerate() {
                if word_prefix_or_better(&t.q, ae.name) {
                    in_folders |= 1 << j;
                }
            }
        }
        if sub != 0 && (all & !sub) & !in_folders == 0 {
            let mut base = all & !in_folders;
            if base == 0 {
                base = 1 << (31 - sub.leading_zeros());
            }
            if base & !sub == 0
                && base != all
                && let Some(q) = p.subset(base)
                && let Some(t) = score_ref(q, &f, window, false)
            {
                let r = rank::ancestor_rank(t, lift);
                if best.is_none_or(|b| r > b.0) {
                    best = Some((r, How::Ancestor));
                }
            }
        }
    }
    best
}

/// The reference result for `query`.
pub(crate) fn reference(snap: &Snapshot, query: &str, o: &SearchOptions) -> Vec<FileHit> {
    let p = Plan::new(query, o.home.as_deref());
    if p.browse().is_some() {
        return Vec::new();
    }
    if o.limit == 0 || (p.literal().is_none() && p.dot_ext().is_none() && p.chains().is_empty()) {
        return Vec::new();
    }
    let lifter = Lifter::new(&o.rank, o.now, o.prefer);
    let mut hits: Vec<FileHit> = Vec::new();
    let mut best_strict = i32::MIN;
    for id in 0..snap.slots() as EntryId {
        if let Some((r, how)) = eval_ref(snap, &p, o, &lifter, id) {
            best_strict = best_strict.max(r);
            hits.push(FileHit { id, rank: r, how });
        }
    }
    let typo = p.simple
        && o.typo
        && p.literal().is_some_and(|q| q.len_chars() >= 4)
        && (best_strict == i32::MIN || rank::tier_of(best_strict) < rank::file_tier(WORD_PREFIX));
    if typo && let Some(lit) = p.literal() {
        for id in 0..snap.slots() as EntryId {
            let Some(e) = snap.entry(id) else { continue };
            let kind_ok = match o.kinds {
                Kinds::All => true,
                Kinds::Files => !e.is_dir(),
                Kinds::Folders => e.is_dir(),
            };
            if !kind_ok || (e.flags & flags::HIDDEN != 0 && !o.include_hidden) {
                continue;
            }
            if let Some(w) = o.within
                && !ancestors(snap, id).contains(&w)
            {
                continue;
            }
            let f = fold(e.name);
            if f.initials & lit.typo_bits == 0 {
                continue;
            }
            if let Some(t) = score_ref(lit, &f, f.bytes.len(), true) {
                let r = rank::name_rank(t, lifter.lift(e.mtime, e.depth, e.is_dir()));
                match hits.iter_mut().find(|h| h.id == id) {
                    Some(h) if h.rank >= r => {}
                    Some(h) => {
                        h.rank = r;
                        h.how = How::Typo;
                    }
                    None => hits.push(FileHit {
                        id,
                        rank: r,
                        how: How::Typo,
                    }),
                }
            }
        }
    }
    hits.sort_by(|a, b| b.rank.cmp(&a.rank).then(a.id.cmp(&b.id)));
    hits.truncate(o.limit);
    hits
}

fn queries(snap: &Snapshot, rng: &mut fastrand::Rng, n: usize) -> Vec<String> {
    let mut out: Vec<String> = vec![
        "docs readme".into(),
        "proj/src main".into(),
        "src/main".into(),
        "report pdf".into(),
        ".pdf".into(),
        "report .pdf".into(),
        "docs/".into(),
        "calender".into(),
        "musc".into(),
        "café".into(),
        "日本".into(),
        "🎉".into(),
        "ålesund notes".into(),
        "htmlp".into(),
        "mode dark".into(),
        "r".into(),
        "zzzq".into(),
        "longlonglong".into(),
        "img 2".into(),
        "x.".into(),
    ];
    while out.len() < n {
        let id = rng.u32(..snap.slots() as u32);
        let Some(e) = snap.entry(id) else { continue };
        let name = String::from_utf8_lossy(e.name).into_owned();
        let chars: Vec<char> = name.chars().collect();
        if chars.is_empty() {
            continue;
        }
        let q = match rng.u8(..7) {
            0 => chars[..rng.usize(1..=chars.len().min(8))].iter().collect(),
            1 => {
                let a = rng.usize(..chars.len());
                chars[a..(a + rng.usize(1..5)).min(chars.len())].iter().collect()
            }
            2 => {
                let parent = snap
                    .entry(e.parent)
                    .map(|p| String::from_utf8_lossy(p.name).into_owned());
                let first: String = chars.iter().take(rng.usize(1..6)).collect();
                match parent {
                    Some(p) => format!("{} {first}", p.chars().take(rng.usize(1..5)).collect::<String>()),
                    None => first,
                }
            }
            3 => format!("{} {}", WORDS[rng.usize(..WORDS.len())], EXTS[rng.usize(..EXTS.len())]),
            4 => {
                let mut c = chars.clone();
                if c.len() > 4 {
                    let i = rng.usize(1..c.len());
                    c[i] = 'q';
                }
                c.into_iter().take(9).collect()
            }
            5 => format!(".{}", &EXTS[rng.usize(..EXTS.len())][..rng.usize(1..3)]),
            _ => {
                let parent = snap
                    .entry(e.parent)
                    .map(|p| String::from_utf8_lossy(p.name).into_owned());
                match parent {
                    Some(p) => format!(
                        "{}/{}",
                        p.chars().take(rng.usize(1..4)).collect::<String>(),
                        chars.iter().take(rng.usize(1..4)).collect::<String>()
                    ),
                    None => continue,
                }
            }
        };
        out.push(q);
    }
    out
}

fn options(rng: &mut fastrand::Rng, dirs: &[EntryId]) -> SearchOptions {
    SearchOptions {
        limit: [1, 5, 20, 50][rng.usize(..4)],
        within: (rng.u8(..6) == 0).then(|| dirs[rng.usize(..dirs.len())]),
        kinds: [Kinds::All, Kinds::All, Kinds::Files, Kinds::Folders][rng.usize(..4)],
        prefer: [Prefer::Neither, Prefer::Files, Prefer::Folders][rng.usize(..3)],
        include_hidden: rng.bool(),
        now: 1_700_000_000,
        ..SearchOptions::default()
    }
}

/// Which code paths a test run went through.
#[derive(Default, Debug)]
struct Seen {
    searches: usize,
    hits: usize,
    prefix_only: usize,
    narrowed: usize,
    typo: usize,
    how: [usize; 6],
}

/// Types `q` one char at a time through `s`, checking every prefix against the reference.
fn check_typed(
    s: &mut Searcher,
    snap: &Arc<Snapshot>,
    q: &str,
    o: &SearchOptions,
    par: &dyn crate::ParallelFor,
    seen: &mut Seen,
) {
    let mut typed = String::new();
    let mut out = Vec::new();
    for c in q.chars() {
        typed.push(c);
        s.search(snap, &typed, o, par, &mut out);
        let want = reference(snap, &typed, o);
        assert_eq!(
            out,
            want,
            "query {typed:?} (of {q:?}) options {o:?} stats {:?}",
            s.stats()
        );
        let st = s.stats();
        seen.searches += 1;
        seen.hits += out.len();
        seen.prefix_only += usize::from(st.prefix_only);
        seen.narrowed += usize::from(st.narrowed);
        seen.typo += usize::from(st.typo_ran);
        for h in &out {
            seen.how[h.how as usize] += 1;
        }
    }
}

fn assert_coverage(seen: &Seen) {
    eprintln!("{seen:?}");
    assert!(seen.hits > seen.searches, "{seen:?}");
    assert!(seen.prefix_only > 0 && seen.narrowed > 0 && seen.typo > 0, "{seen:?}");
    for how in [How::Name, How::Ancestor, How::Extension, How::Typo, How::Filter] {
        assert!(seen.how[how as usize] > 0, "no {how:?} hits: {seen:?}");
    }
}

#[test]
fn search_equals_brute_force_reference() {
    for seed in [1u64, 2, 3] {
        let (snap, dirs) = corpus(seed, 9_000);
        let snap = Arc::new(snap);
        let mut rng = fastrand::Rng::with_seed(seed * 77);
        let qs = queries(&snap, &mut rng, 120);
        let mut s = Searcher::new();
        let mut seen = Seen::default();
        for q in &qs {
            let o = options(&mut rng, &dirs);
            check_typed(&mut s, &snap, q, &o, &Serial, &mut seen);
        }
        assert_coverage(&seen);
    }
}

#[cfg(feature = "parallel")]
#[test]
fn parallel_search_equals_brute_force_reference() {
    let (snap, dirs) = corpus(9, 20_000);
    let snap = Arc::new(snap);
    let mut rng = fastrand::Rng::with_seed(99);
    let qs = queries(&snap, &mut rng, 80);
    let mut s = Searcher::new();
    let mut seen = Seen::default();
    for q in &qs {
        let o = options(&mut rng, &dirs);
        check_typed(&mut s, &snap, q, &o, &crate::search::Rayon, &mut seen);
    }
    assert_coverage(&seen);
}

#[test]
fn backspace_and_retyping_stay_exact() {
    let (snap, _) = corpus(5, 6_000);
    let snap = Arc::new(snap);
    let o = SearchOptions {
        now: 1_700_000_000,
        ..SearchOptions::default()
    };
    let mut s = Searcher::new();
    let mut out = Vec::new();
    for q in [
        "r",
        "re",
        "rea",
        "read",
        "rea",
        "re",
        "rep",
        "repo",
        "report",
        "report ",
        "report p",
        "report pd",
    ] {
        s.search(&snap, q, &o, &Serial, &mut out);
        assert_eq!(out, reference(&snap, q, &o), "{q:?}");
    }
}

#[test]
fn compressed_entry_masks_match_slick_masks() {
    let (snap, _) = corpus(4, 2_000);
    for id in 0..snap.slots() as EntryId {
        let Some((c, s)) = snap.locate(id) else { continue };
        let f = fold(snap.name_of(id));
        assert_eq!(c.mask.as_slice()[s], compress_mask(f.mask));
        assert_eq!(c.ws.as_slice()[s], f.ws);
    }
}
