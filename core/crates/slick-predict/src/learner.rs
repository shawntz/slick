//! The learning state of one user, and the only way it changes: by applying log records.
//!
//! A live execution and a replayed one go through the same code. `execute`, `undo`, `forget` and
//! `seed` build log records, apply them, and hand them back for the caller to append to the log.
//! `apply` replays records read from the log. So a state rebuilt from the log equals the state the
//! records were written from.

use crate::affinity::{Affinity, AffinityParams, AffinityUndo, row_key, truncate};
use crate::context::{Ctx, NONE, front_value};
use crate::decay::DecayCounter;
use crate::frecency::Frecency;
use crate::hash::{FxMap, fnv1a};
use crate::log::{Event, MAX_QUERY_BYTES, RECORD_LEN, Record, Source, define_query};
use crate::time::{log_seconds, minutes};
use crate::zero_query::{ZqModel, ZqParams, ZqUndo};

/// How long after an execution an undo still removes its learning, in seconds.
pub const UNDO_WINDOW_S: u32 = 5;

/// Constants of every learning component.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LearnerParams {
    /// Zero-query model.
    pub zero_query: ZqParams,
    /// Query affinity.
    pub affinity: AffinityParams,
}

/// The context of an execution as the caller knows it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Situation {
    /// Local hour, 0..=23.
    pub hour: u8,
    /// Local weekday, 0 = Monday.
    pub weekday: u8,
    /// Key of the frontmost app, 0 when unknown.
    pub frontmost: u64,
    /// `Ctx::flag_bits`.
    pub flags: u16,
}

/// One execution to learn from.
#[derive(Clone, Copy, Debug)]
pub struct Execution<'a> {
    /// Item key.
    pub key: u64,
    /// The normalized query typed before it (empty for none).
    pub query: &'a str,
    /// How the item was reached.
    pub source: Source,
    /// Displayed rank, 255 when not shown in a list.
    pub rank: u8,
    /// Unix time of the execution.
    pub unix: f64,
    /// Context at the time.
    pub situation: Situation,
}

/// Counters for the settings inspector.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    /// Executions learned (undone ones excluded).
    pub events: u64,
    /// Executions undone.
    pub undone: u64,
    /// Items forgotten.
    pub forgotten: u64,
    /// Seeds applied.
    pub seeds: u64,
    /// Executions by source, indexed by `Source as usize`.
    pub by_source: [u64; 5],
}

/// A log record that does not fit the state it is applied to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InconsistentRecord;

/// What the last execution changed, kept for the undo window.
#[derive(Clone, Debug)]
struct Last {
    event: Event,
    zq: ZqUndo,
    affinity: AffinityUndo,
    frecency: DecayCounter,
    max_l: f64,
    prev: Option<(u32, u32)>,
}

/// One user's learning state, with items numbered by learn id in order of first appearance.
#[derive(Clone, Debug)]
pub struct Learner {
    /// Zero-query model.
    pub zq: ZqModel,
    /// Query affinity.
    pub affinity: Affinity,
    /// Typed-ranking frecency.
    pub frecency: Frecency,
    pub(crate) keys: Vec<u64>,
    pub(crate) ids: FxMap<u64, u32>,
    pub(crate) queries: Vec<String>,
    pub(crate) query_ids: FxMap<u64, u32>,
    pending_query: Option<(u32, u8, Vec<u8>)>,
    last: Option<Last>,
    pub(crate) prev: Option<(u32, u32)>,
    /// Counters for the inspector.
    pub counts: Counts,
}

impl Learner {
    /// An empty state.
    pub fn new(p: &LearnerParams) -> Self {
        Learner {
            zq: ZqModel::new(p.zero_query.clone()),
            affinity: Affinity::new(p.affinity.clone()),
            frecency: Frecency::default(),
            keys: Vec::new(),
            ids: FxMap::default(),
            queries: Vec::new(),
            query_ids: FxMap::default(),
            pending_query: None,
            last: None,
            prev: None,
            counts: Counts::default(),
        }
    }

    /// The learn id of an item key, if the item was ever learned or seeded.
    pub fn id_of(&self, key: u64) -> Option<u32> {
        self.ids.get(&key).copied()
    }

    /// The item key of a learn id.
    pub fn key_of(&self, id: u32) -> u64 {
        self.keys.get(id as usize).copied().unwrap_or(0)
    }

    /// Number of learn ids.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// True before anything was learned or seeded.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The normalized queries executions were learned from, by query id.
    pub fn queries(&self) -> &[String] {
        &self.queries
    }

    /// The previous execution: (learn id, minutes since the epoch).
    pub fn previous(&self) -> Option<(u32, f64)> {
        self.prev.map(|(id, t_sec)| (id, minutes(t_sec)))
    }

    /// The context for a prediction at Unix time `unix`.
    pub fn context(&self, unix: f64, s: &Situation) -> Ctx {
        let t = minutes(log_seconds(unix));
        let mut ctx = Ctx {
            t,
            hour: s.hour.min(23),
            weekday: s.weekday.min(6),
            front: front_value(s.frontmost),
            ..Ctx::default()
        };
        ctx.set_flag_bits(s.flags);
        if let Some((prev, at)) = self.prev {
            ctx.prev = prev;
            ctx.since_prev = (t - minutes(at)).max(0.0);
        }
        ctx
    }

    fn intern_item(&mut self, key: u64, out: &mut Vec<[u8; RECORD_LEN]>) -> u32 {
        if let Some(&id) = self.ids.get(&key) {
            return id;
        }
        let id = self.keys.len() as u32;
        let r = Record::DefineItem { id, key };
        out.push(r.encode());
        self.define_item(id, key);
        id
    }

    fn define_item(&mut self, id: u32, key: u64) {
        self.keys.push(key);
        self.ids.insert(key, id);
        self.zq.ensure_items(self.keys.len());
    }

    fn intern_query(&mut self, q: &str, out: &mut Vec<[u8; RECORD_LEN]>) -> u32 {
        let mut end = q.len().min(MAX_QUERY_BYTES);
        while !q.is_char_boundary(end) {
            end -= 1;
        }
        let q = &q[..end];
        let h = fnv1a(q.as_bytes());
        if let Some(&id) = self.query_ids.get(&h)
            && self.queries[id as usize] == q
        {
            return id;
        }
        let id = self.queries.len() as u32;
        for r in define_query(id, q.as_bytes()) {
            out.push(r.encode());
        }
        self.define_query(q.to_string());
        id
    }

    fn define_query(&mut self, q: String) {
        let id = self.queries.len() as u32;
        self.query_ids.insert(fnv1a(q.as_bytes()), id);
        self.queries.push(q);
    }

    /// Learns from an execution and returns the log records to append.
    pub fn execute(&mut self, x: &Execution<'_>) -> Vec<[u8; RECORD_LEN]> {
        let mut out = Vec::with_capacity(4);
        let item = self.intern_item(x.key, &mut out);
        let typed = x.source == Source::Typed && !x.query.is_empty();
        let query = if typed {
            self.intern_query(x.query, &mut out)
        } else {
            NONE
        };
        let t_sec = log_seconds(x.unix);
        let (prev, since_prev_s) = match self.prev {
            Some((p, at)) => (p, t_sec.saturating_sub(at)),
            None => (NONE, u32::MAX),
        };
        let event = Event {
            t_sec,
            item,
            front: front_value(x.situation.frontmost),
            prev,
            query,
            since_prev_s,
            hour: x.situation.hour.min(23),
            weekday: x.situation.weekday.min(6),
            flags: x.situation.flags as u8,
            source: x.source,
            rank: x.rank,
        };
        out.push(Record::Event(event).encode());
        self.apply_event(event);
        out
    }

    fn apply_event(&mut self, e: Event) {
        let mut ctx = Ctx {
            t: minutes(e.t_sec),
            hour: e.hour,
            weekday: e.weekday,
            front: e.front,
            prev: e.prev,
            since_prev: if e.since_prev_s == u32::MAX {
                f64::INFINITY
            } else {
                e.since_prev_s as f64 / 60.0
            },
            ..Ctx::default()
        };
        ctx.set_flag_bits(e.flags as u16);
        let zq = self.zq.update(&ctx, e.item);
        let frecency = self.frecency.get(e.item);
        let max_l = self.frecency.max_l;
        self.frecency.add(e.item, ctx.t, 1.0);
        let affinity = match self.queries.get(e.query as usize) {
            Some(q) if e.source == Source::Typed => {
                let q = q.clone();
                self.affinity.learn(&q, e.item, ctx.t)
            }
            _ => AffinityUndo::default(),
        };
        self.last = Some(Last {
            event: e,
            zq,
            affinity,
            frecency,
            max_l,
            prev: self.prev,
        });
        self.prev = Some((e.item, e.t_sec));
        self.counts.events += 1;
        self.counts.by_source[e.source as usize] += 1;
    }

    /// Removes the learning of the last execution when it was `key` at most `UNDO_WINDOW_S`
    /// seconds before `unix`. Returns the log records to append, or `None` when there is nothing
    /// to undo.
    pub fn undo(&mut self, key: u64, unix: f64) -> Option<Vec<[u8; RECORD_LEN]>> {
        let id = self.id_of(key)?;
        let e = self.last.as_ref()?.event;
        if e.item != id || log_seconds(unix).saturating_sub(e.t_sec) > UNDO_WINDOW_S {
            return None;
        }
        self.undo_last(e.t_sec, id).then(|| {
            vec![
                Record::Undo {
                    t_sec: e.t_sec,
                    item: id,
                }
                .encode(),
            ]
        })
    }

    fn undo_last(&mut self, t_sec: u32, item: u32) -> bool {
        let Some(last) = self.last.take() else { return false };
        if last.event.t_sec != t_sec || last.event.item != item || !self.zq.undo(last.zq) {
            return false;
        }
        self.affinity.restore(last.affinity);
        self.frecency.set(item, last.frecency, last.max_l);
        self.prev = last.prev;
        self.counts.events -= 1;
        self.counts.by_source[last.event.source as usize] -= 1;
        self.counts.undone += 1;
        true
    }

    /// True while the last execution can still be undone (no other change since).
    pub fn has_undo(&self) -> bool {
        self.last.is_some()
    }

    /// Forgets everything learned about `key`. Returns the log records to append (none when the
    /// item was never learned).
    pub fn forget(&mut self, key: u64) -> Vec<[u8; RECORD_LEN]> {
        let Some(id) = self.id_of(key) else { return Vec::new() };
        self.forget_id(id);
        vec![Record::Forget { item: id }.encode()]
    }

    fn forget_id(&mut self, id: u32) {
        self.zq.forget(id);
        self.affinity.forget(id);
        self.frecency.forget(id);
        if self.prev.is_some_and(|(p, _)| p == id) {
            self.prev = None;
        }
        self.last = None;
        self.counts.forgotten += 1;
    }

    /// Forgets the affinity row of the normalized query `q`, so typing it ranks by text again.
    /// The rows of its prefixes keep the credit it gave them. The query's text is dropped from the
    /// state too, so later snapshots do not hold it. Returns the log records to append (none when
    /// the query has no row).
    pub fn forget_query(&mut self, q: &str) -> Vec<[u8; RECORD_LEN]> {
        let key = row_key(q, self.affinity.p.max_query_bytes);
        if !self.affinity.rows.contains_key(&key) {
            return Vec::new();
        }
        self.forget_query_key(key);
        vec![Record::ForgetQuery { key }.encode()]
    }

    fn forget_query_key(&mut self, key: u64) {
        self.affinity.forget_row_key(key);
        let max = self.affinity.p.max_query_bytes;
        for q in self.queries.iter_mut() {
            if !q.is_empty() && row_key(truncate(q, max), max) == key {
                self.query_ids.remove(&fnv1a(q.as_bytes()));
                q.clear();
            }
        }
        // The undo of the last execution may hold this row as it was; it must not come back.
        self.last = None;
    }

    /// A first-run seed: a virtual use of `weight` at Unix time `unix`, counted in the zero-query
    /// prior and the typed frecency only. Returns the log records to append.
    pub fn seed(&mut self, key: u64, weight: f32, unix: f64) -> Vec<[u8; RECORD_LEN]> {
        let mut out = Vec::with_capacity(2);
        if !(weight > 0.0 && weight.is_finite()) {
            return out;
        }
        let item = self.intern_item(key, &mut out);
        let r = Record::Seed {
            t_sec: log_seconds(unix),
            item,
            weight,
        };
        out.push(r.encode());
        self.seed_id(item, log_seconds(unix), weight);
        out
    }

    fn seed_id(&mut self, id: u32, t_sec: u32, weight: f32) {
        let t = minutes(t_sec);
        self.zq.seed(id, t, weight as f64);
        self.frecency.add(id, t, weight as f64);
        self.last = None;
        self.counts.seeds += 1;
    }

    /// Replays one log record.
    pub fn apply(&mut self, r: &Record) -> Result<(), InconsistentRecord> {
        let known = |s: &Self, id: u32| (id as usize) < s.keys.len();
        match *r {
            Record::DefineItem { id, key } => {
                if id as usize != self.keys.len() || self.ids.contains_key(&key) {
                    return Err(InconsistentRecord);
                }
                self.define_item(id, key);
            }
            Record::DefineQuery { id, part, len, text } => {
                let len = len as usize;
                match (part, self.pending_query.take()) {
                    (0, None) if id as usize == self.queries.len() && len <= MAX_QUERY_BYTES => {
                        let take = len.min(text.len());
                        if take == len {
                            self.define_query(utf8(&text[..take])?);
                        } else {
                            self.pending_query = Some((id, len as u8, text.to_vec()));
                        }
                    }
                    (1, Some((pid, plen, mut bytes))) if pid == id => {
                        let rest = plen as usize - bytes.len();
                        bytes.extend_from_slice(&text[..rest.min(text.len())]);
                        self.define_query(utf8(&bytes)?);
                    }
                    _ => return Err(InconsistentRecord),
                }
            }
            Record::Event(e) => {
                if !known(self, e.item) || (e.query != NONE && e.query as usize >= self.queries.len()) {
                    return Err(InconsistentRecord);
                }
                self.apply_event(e);
            }
            // An undo whose execution is already part of a snapshot cannot be applied. It is
            // skipped: the snapshot keeps that one execution, which is harmless.
            Record::Undo { t_sec, item } => {
                self.undo_last(t_sec, item);
            }
            Record::Forget { item } if known(self, item) => self.forget_id(item),
            Record::Seed { t_sec, item, weight } if known(self, item) => self.seed_id(item, t_sec, weight),
            Record::ForgetQuery { key } => self.forget_query_key(key),
            // A log file's first record, never learning.
            Record::Forget { .. } | Record::Seed { .. } | Record::Base { .. } => return Err(InconsistentRecord),
        }
        Ok(())
    }
}

fn utf8(bytes: &[u8]) -> Result<String, InconsistentRecord> {
    String::from_utf8(bytes.to_vec()).map_err(|_| InconsistentRecord)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exec(key: u64, query: &str, unix: f64) -> Execution<'_> {
        Execution {
            key,
            query,
            source: Source::Typed,
            rank: 0,
            unix,
            situation: Situation {
                hour: 9,
                weekday: 2,
                frontmost: 77,
                flags: 0b10,
            },
        }
    }

    fn replay(records: &[[u8; RECORD_LEN]]) -> Learner {
        let mut l = Learner::new(&LearnerParams::default());
        for b in records {
            let r = Record::decode(b).expect("valid record");
            l.apply(&r).expect("consistent record");
        }
        l
    }

    fn same_state(a: &Learner, b: &Learner) {
        assert_eq!(a.keys, b.keys);
        assert_eq!(a.queries, b.queries);
        assert_eq!(a.zq.w, b.zq.w);
        assert_eq!(a.zq.cc, b.zq.cc);
        assert_eq!(a.zq.cands, b.zq.cands);
        assert_eq!(a.affinity.rows, b.affinity.rows);
        assert_eq!(a.frecency, b.frecency);
        assert_eq!(a.counts, b.counts);
        assert_eq!(a.prev, b.prev);
    }

    #[test]
    fn replaying_the_log_rebuilds_the_same_state() {
        let mut live = Learner::new(&LearnerParams::default());
        let mut log = Vec::new();
        let base = crate::time::EPOCH_UNIX + 86_400.0;
        log.extend(live.seed(5, 0.3, base - 3_600.0));
        for k in 0..300u64 {
            let q = ["term", "saf", "a much longer query string that needs two log parts", ""][k as usize % 4];
            log.extend(live.execute(&exec(k % 7, q, base + k as f64 * 97.0)));
            if k % 50 == 3 {
                log.extend(
                    live.undo(k % 7, base + k as f64 * 97.0 + 2.0)
                        .expect("undo inside the window"),
                );
            }
        }
        log.extend(live.forget(3));
        log.extend(live.forget_query("term"));
        assert!(live.forget_query("term").is_empty(), "a forgotten row is gone");
        assert!(live.affinity.row("term").is_none() && live.affinity.row("ter").is_some());
        assert!(!live.queries().iter().any(|q| q == "term"), "the text is gone too");
        // Typing it again learns it again, under a new id.
        log.extend(live.execute(&exec(2, "term", base + 40_000.0)));
        assert!(live.affinity.row("term").is_some());
        same_state(&live, &replay(&log));
        // A snapshot taken after the forget round-trips too.
        let snap = crate::snapshot::encode(&live, log.len() as u64);
        let (back, _) = crate::snapshot::decode(&snap, &LearnerParams::default()).expect("snapshot");
        same_state(&live, &back);
    }

    #[test]
    fn forgetting_a_query_closes_the_undo_window() {
        let mut l = Learner::new(&LearnerParams::default());
        let t = crate::time::EPOCH_UNIX + 1_000.0;
        l.execute(&exec(1, "term", t));
        assert_eq!(l.forget_query("term").len(), 1);
        assert!(l.undo(1, t + 1.0).is_none(), "the undo would bring the row back");
        assert!(l.affinity.row("term").is_none());
    }

    #[test]
    fn undo_works_only_inside_the_window_and_only_for_the_last_item() {
        let mut l = Learner::new(&LearnerParams::default());
        let t = crate::time::EPOCH_UNIX + 1_000.0;
        l.execute(&exec(1, "term", t));
        let before = l.clone();
        l.execute(&exec(2, "term", t + 60.0));
        assert!(l.undo(1, t + 61.0).is_none(), "not the last item");
        assert!(l.undo(2, t + 66.0).is_none(), "outside the window");
        assert!(l.undo(2, t + 64.0).is_some());
        assert_eq!(l.zq.w, before.zq.w);
        assert_eq!(l.zq.cc, before.zq.cc);
        assert_eq!(l.zq.cands, before.zq.cands);
        assert_eq!(l.affinity.rows, before.affinity.rows);
        assert_eq!(l.frecency.max_l, before.frecency.max_l);
        assert_eq!(l.frecency.score(1), before.frecency.score(1));
        assert_eq!(l.frecency.score(2), 0.0);
        assert_eq!(l.prev, before.prev);
        assert_eq!(l.counts.undone, 1);
        assert!(l.undo(2, t + 64.0).is_none(), "only once");
    }

    #[test]
    fn suggestion_picks_do_not_teach_typed_affinity() {
        let mut l = Learner::new(&LearnerParams::default());
        let mut x = exec(1, "term", crate::time::EPOCH_UNIX);
        x.source = Source::Suggestion;
        l.execute(&x);
        assert!(l.affinity.rows.is_empty());
        assert!(l.queries().is_empty());
    }

    #[test]
    fn inconsistent_records_are_rejected() {
        let mut l = Learner::new(&LearnerParams::default());
        assert!(l.apply(&Record::Forget { item: 0 }).is_err());
        assert!(l.apply(&Record::DefineItem { id: 3, key: 1 }).is_err());
        assert!(
            l.apply(&Record::Undo { t_sec: 0, item: 0 }).is_ok(),
            "a stale undo is skipped"
        );
    }
}
