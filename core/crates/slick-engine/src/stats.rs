//! Learning statistics as JSON for the settings inspector: counts, the most frecent items, the
//! affinity rows with their query text and band holder, and the zero-query model's weights. Also
//! the summary numbers, and the text of affinity rows after a query was forgotten.

use crate::engine::State;
use crate::json::Json;
use slick_predict::Learner;
use slick_predict::affinity::row_key;
use slick_predict::context::FEATURE_NAMES;
use slick_predict::hash::{FxMap, fnv1a};
use slick_predict::log::{RECORD_LEN, define_query};
use slick_predict::time::{EPOCH_UNIX, log_seconds, minutes};
use slick_predict::zero_query::{ITEM_EXPERTS, KF};
use std::collections::HashSet;

/// The headline numbers of the learning inspector.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Summary {
    /// Executions learned, undone ones excluded.
    pub events: u64,
    /// Items with at least one learned execution that were not forgotten since.
    pub items: u64,
    /// Affinity rows the statistics can name.
    pub queries: u64,
    /// Unix time of the oldest learned execution of those items, `None` when there is none.
    pub first_event: Option<f64>,
}

/// The learning summary. Items and the first event come from the zero-query model's first-use
/// times, which every learned execution sets and which forget and undo keep exact.
pub(crate) fn summary(l: &Learner) -> Summary {
    let used = l.zq.first_used.iter().filter(|t| t.is_finite());
    let items = used.clone().count() as u64;
    let first = used.copied().fold(f64::INFINITY, f64::min);
    Summary {
        events: l.counts.events,
        items,
        queries: named_rows(l).len() as u64,
        first_event: first.is_finite().then_some(first * 60.0 + EPOCH_UNIX),
    }
}

/// Every prefix of every query text the learner kept, by row key.
fn prefix_text(l: &Learner) -> FxMap<u64, &str> {
    let mut text: FxMap<u64, &str> = FxMap::default();
    for q in l.queries() {
        for (at, ch) in q.char_indices() {
            let prefix = &q[..at + ch.len_utf8()];
            text.entry(fnv1a(prefix.as_bytes())).or_insert(prefix);
        }
    }
    text
}

/// The affinity rows that have a text, sorted by text.
fn named_rows(l: &Learner) -> Vec<(&str, u64)> {
    let text = prefix_text(l);
    let mut rows: Vec<(&str, u64)> = l
        .affinity
        .rows
        .keys()
        .filter_map(|h| text.get(h).map(|t| (*t, *h)))
        .collect();
    rows.sort_unstable();
    rows
}

/// After a forget-query, gives back a text to every affinity row that only a dropped query
/// named. `before` is the learner's query list before the forget. For each dropped text, the
/// longest proper prefix that still has a row and no other text names is defined as a query, which
/// names it and every shorter prefix. Returns the log records, which replay the same way.
pub(crate) fn rename_orphan_rows(l: &mut Learner, before: &[String]) -> Vec<[u8; RECORD_LEN]> {
    let max = l.affinity.p.max_query_bytes;
    let dropped: Vec<&String> = before
        .iter()
        .zip(l.queries())
        .filter(|(old, now)| !old.is_empty() && now.is_empty())
        .map(|(old, _)| old)
        .collect();
    if dropped.is_empty() {
        return Vec::new();
    }
    let mut named: HashSet<u64> = prefix_text(l).into_keys().collect();
    let mut define: Vec<String> = Vec::new();
    for q in dropped {
        let ends = q.char_indices().map(|(at, _)| at).filter(|&at| at > 0).rev();
        for end in ends {
            let prefix = &q[..end];
            let key = fnv1a(prefix.as_bytes());
            if named.contains(&key) {
                break;
            }
            if prefix.len() <= max && l.affinity.rows.contains_key(&row_key(prefix, max)) {
                for (at, ch) in prefix.char_indices() {
                    named.insert(fnv1a(&prefix.as_bytes()[..at + ch.len_utf8()]));
                }
                define.push(prefix.to_string());
                break;
            }
        }
    }
    let mut out = Vec::new();
    for text in define {
        let id = l.queries().len() as u32;
        for r in define_query(id, text.as_bytes()) {
            // A definition with the next id always applies; replay applies the same records.
            if l.apply(&r).is_ok() {
                out.push(r.encode());
            }
        }
    }
    out
}

/// How many items the inspector lists.
const TOP_ITEMS: usize = 20;

pub(crate) fn render(st: &State, catalog_sources: usize, io_errors: u64) -> String {
    let mut j = Json(String::with_capacity(8 * 1024));
    let l = &st.learner;
    let title = |key: u64| st.index.position(key).map(|p| st.index.title(p));
    j.raw("{");
    j.key("paused");
    j.bool(st.paused);
    j.raw(",");
    j.key("catalog");
    j.raw("{");
    j.key("items");
    j.int(st.index.len() as u64);
    j.raw(",");
    j.key("sources");
    j.int(catalog_sources as u64);
    j.raw("},");
    j.key("io_errors");
    j.int(io_errors);
    j.raw(",");
    let sum = summary(l);
    j.key("first_event");
    match sum.first_event {
        Some(t) => j.number(t),
        None => j.raw("null"),
    }
    j.raw(",");
    j.key("counts");
    j.raw("{");
    j.key("items");
    j.int(sum.items);
    j.raw(",");
    let c = &l.counts;
    let names = ["typed", "suggestion", "hotkey", "alias", "fallback"];
    let fields = [
        ("events", c.events),
        ("undone", c.undone),
        ("forgotten", c.forgotten),
        ("seeds", c.seeds),
    ];
    for (i, (name, v)) in fields.into_iter().chain(names.into_iter().zip(c.by_source)).enumerate() {
        if i > 0 {
            j.raw(",");
        }
        j.key(name);
        j.int(v);
    }
    j.raw("},");

    j.key("top_items");
    j.raw("[");
    let mut items: Vec<(u32, f64)> = (0..l.len() as u32)
        .map(|id| (id, l.frecency.score(id)))
        .filter(|&(_, f)| f > 0.0)
        .collect();
    items.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    for (n, &(id, f)) in items.iter().take(TOP_ITEMS).enumerate() {
        if n > 0 {
            j.raw(",");
        }
        let key = l.key_of(id);
        j.raw("{");
        j.key("key");
        j.string(&key.to_string());
        j.raw(",");
        j.key("title");
        match title(key) {
            Some(t) => j.string(t),
            None => j.raw("null"),
        }
        j.raw(",");
        j.key("frecency");
        j.number(f);
        j.raw(",");
        j.key("last_used");
        j.number(
            l.zq.last_used
                .get(id as usize)
                .map_or(f64::NAN, |&t| t * 60.0 + EPOCH_UNIX),
        );
        j.raw("}");
    }
    j.raw("],");

    j.key("affinity");
    j.raw("[");
    let rows = named_rows(l);
    let now = minutes(log_seconds(st.context.now));
    for (n, (query, _)) in rows.iter().enumerate() {
        if n > 0 {
            j.raw(",");
        }
        j.raw("{");
        let summary = l.affinity.summary(query.as_bytes(), now);
        j.key("query");
        j.string(query);
        j.raw(",");
        // The item that holds the learned band for this query, null for none (rule 4 keeps it
        // there even when another item is momentarily stronger).
        j.key("band");
        match summary.band {
            Some((id, _)) => j.string(&l.key_of(id).to_string()),
            None => j.raw("null"),
        }
        j.raw(",");
        j.key("items");
        j.raw("[");
        for (m, &(id, w)) in summary.entries().iter().enumerate() {
            if m > 0 {
                j.raw(",");
            }
            let key = l.key_of(id);
            j.raw("{");
            j.key("key");
            j.string(&key.to_string());
            j.raw(",");
            j.key("title");
            match title(key) {
                Some(t) => j.string(t),
                None => j.raw("null"),
            }
            j.raw(",");
            j.key("weight");
            j.number(w);
            j.raw("}");
        }
        j.raw("]}");
    }
    j.raw("],");

    j.key("model");
    j.raw("{");
    j.key("updates");
    j.number(l.zq.n_updates);
    j.raw(",");
    j.key("weights");
    j.raw("[");
    let names = ITEM_EXPERTS.iter().chain(FEATURE_NAMES.iter());
    for (k, name) in names.enumerate() {
        if k > 0 {
            j.raw(",");
        }
        j.raw("{");
        j.key("name");
        j.string(name);
        j.raw(",");
        j.key("kind");
        j.string(if k < KF { "item" } else { "context" });
        j.raw(",");
        j.key("weight");
        j.number(l.zq.w[k]);
        j.raw(",");
        j.key("prior");
        j.number(l.zq.p.w_init[k]);
        j.raw("}");
    }
    j.raw("]}}");
    j.0
}
